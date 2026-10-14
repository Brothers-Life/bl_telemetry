--[[
    bl_telemetry/live — suit en continu les tables du jeu que backfill.lua ne reprend qu'une fois :
      - bank_flows          -> events subtype 'bank_flow'   (virements, depots, retraits)
      - bank_audit_log      -> admin_action 'bank_*'        (actions staff banque)
      - bl_shops_admin_logs -> events subtype 'shop_admin'  (actions staff shops)
    Un curseur (dernier id lu) par table est garde dans bl_telemetry_state : pas de doublon apres
    un redemarrage, et au tout premier lancement on part de la fin (le backfill couvre l'historique).
    Suit aussi, sans connaitre leurs colonnes, d'autres tables de journal du jeu (FOLLOW ci-dessous) :
    chaque nouvelle ligne devient un event 'game_log' (sous-type = nom de la table), sans les colonnes
    sensibles (license, ip, discord, steam, token...). bl_ac_detections declenche en plus une alerte anticheat.
    Convar : telemetry_live_ms (defaut 30000, 0 = desactive).
]]

local INTERVAL = GetConvarInt('telemetry_live_ms', 30000)
local BATCH = 500

local pushEvent = TelemetryPush

local SOURCES = {
    {
        key = 'live_bank_flows', tbl = 'bank_flows',
        sql = [[SELECT id, UNIX_TIMESTAMP(created_at) * 1000 AS ts_ms, kind, from_cid, to_cid, amount, note
                FROM bank_flows WHERE id > ? ORDER BY id LIMIT ?]],
        map = function(r)
            return {
                type = 'event', subtype = 'bank_flow', ts = tonumber(r.ts_ms), citizenid = r.from_cid,
                data = { kind = r.kind, from_cid = r.from_cid, to_cid = r.to_cid, amount = tonumber(r.amount) or 0, note = r.note },
            }
        end,
    },
    {
        key = 'live_bank_audit', tbl = 'bank_audit_log',
        sql = [[SELECT id, UNIX_TIMESTAMP(created_at) * 1000 AS ts_ms, admin_name, action, target, amount_before, amount_after, details
                FROM bank_audit_log WHERE id > ? ORDER BY id LIMIT ?]],
        map = function(r)
            return {
                type = 'admin_action', ts = tonumber(r.ts_ms),
                data = { action = 'bank_' .. (r.action or '?'), admin_name = r.admin_name, target_name = r.target, reason = r.details,
                         extra = { amount_before = r.amount_before, amount_after = r.amount_after } },
            }
        end,
    },
    {
        key = 'live_shop_admin', tbl = 'bl_shops_admin_logs',
        sql = [[SELECT id, UNIX_TIMESTAMP(created_at) * 1000 AS ts_ms, action, shop_id, admin_name, details
                FROM bl_shops_admin_logs WHERE id > ? ORDER BY id LIMIT ?]],
        map = function(r)
            return {
                type = 'event', subtype = 'shop_admin', ts = tonumber(r.ts_ms), player_name = r.admin_name,
                data = { action = r.action, shop_id = r.shop_id, details = r.details },
            }
        end,
    },
}

-- Tables de journal suivies telles quelles (il faut une colonne id auto-incrementee). Une table absente est ignoree.
local FOLLOW = {
    { tbl = 'bl_ac_detections', anticheat = true },
    { tbl = 'admindash_sanctions' }, { tbl = 'admindash_audit_log' }, { tbl = 'admindash_reports' },
    { tbl = 'admindash_staff_sessions' }, { tbl = 'mdt_audit' }, { tbl = 'mdt_plate_scans' }, { tbl = 'xt_prison' },
    { tbl = 'premium_purchases' }, { tbl = 'premium_shop_item_purchases' }, { tbl = 'premium_crate_openings' },
    { tbl = 'garage_admin_logs' }, { tbl = 'shop_admin_logs' }, { tbl = 'job_admin_logs' }, { tbl = 'job_safe_log' },
    { tbl = 'gang_safe_log' }, { tbl = 'player_transactions' }, { tbl = 'sky_phone_bank_transactions' },
    { tbl = 'sky_phone_billing_invoices' }, { tbl = 'bl_safezones_audit' }, { tbl = 'teleport_admin_logs' },
    { tbl = 'harvest_zone_logs' }, { tbl = 'door_logs' }, { tbl = 'bl_weapon_skin_log' },
    -- actions staff supplementaires
    { tbl = 'admindash_role_actions' }, { tbl = 'admindash_blip_logs' }, { tbl = 'admindash_staff_loans' },
    { tbl = 'mapeditor_audit' }, { tbl = 'dj_audit' }, { tbl = 'tv_admin_logs' }, { tbl = 'qbx_vehicle_admin_probe' },
}
local FOLLOW_BACKLOG = 200 -- au premier lancement, on reprend les 200 dernieres lignes de chaque table

local SENSITIVE = { 'license', 'ip', 'discord', 'steam', 'token', 'hwid', 'fivem', 'xbl', 'live', 'password', 'secret', 'identifier' }
local function isSensitive(col)
    local c = col:lower()
    for _, w in ipairs(SENSITIVE) do
        if c == w or c:find('^' .. w .. '_') or c:find('_' .. w .. '$') or c:find('_' .. w .. '_') or (#w > 4 and c:find(w, 1, true)) then return true end
    end
    return false
end

local function firstOf(row, keys)
    for _, k in ipairs(keys) do
        local v = row[k]
        if v ~= nil and v ~= '' then return v end
    end
end

-- oxmysql renvoie les dates en ms ou en texte selon le type de colonne.
local function toMs(v)
    local n = tonumber(v)
    if n then
        if n > 1e12 then return math.floor(n) elseif n > 1e9 then return math.floor(n * 1000) end
        return nil
    end
    if type(v) == 'string' then
        local y, mo, d, h, mi, se = v:match('(%d+)-(%d+)-(%d+)[ T](%d+):(%d+):?(%d*)')
        if y then return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = tonumber(se) or 0 }) * 1000 end
    end
end

local function mapRow(f, r)
    local data = {}
    for k, v in pairs(r) do
        if not isSensitive(k) then
            local t = type(v)
            if t == 'string' then data[k] = v:sub(1, 1000)
            elseif t == 'number' or t == 'boolean' then data[k] = v
            elseif v ~= nil then data[k] = tostring(v):sub(1, 1000) end
        end
    end
    local cid = firstOf(r, { 'citizenid', 'cid', 'citizen_id', 'target_cid', 'target_citizenid', 'player_cid', 'owner' })
    local name = firstOf(r, { 'player_name', 'name', 'charname', 'target_name', 'target', 'player' })
    local ts = toMs(firstOf(r, { 'created_at', 'createdAt', 'date', 'timestamp', 'time', 'ts', 'start_time', 'started_at' }))
    local events = { {
        type = 'game_log', subtype = f.tbl, ts = ts, citizenid = cid and tostring(cid) or nil,
        player_name = name and tostring(name) or nil, data = data,
    } }
    if f.anticheat then
        events[2] = {
            type = 'anticheat', ts = ts, citizenid = cid and tostring(cid) or nil, player_name = name and tostring(name) or nil,
            data = { reason = tostring(firstOf(r, { 'reason', 'detection', 'type', 'category', 'check', 'module' }) or 'detection'), details = data },
        }
    end
    return events
end

local function saveCursor(key, id)
    MySQL.insert.await('INSERT INTO bl_telemetry_state (k, v) VALUES (?, ?) ON DUPLICATE KEY UPDATE v = VALUES(v)', { key, tostring(id) })
end

-- Renvoie le curseur de depart, ou nil si la table n'existe pas sur ce serveur.
local function initCursor(src)
    local saved = MySQL.single.await('SELECT v FROM bl_telemetry_state WHERE k = ?', { src.key })
    if saved and tonumber(saved.v) then return tonumber(saved.v) end
    local ok, maxId = pcall(MySQL.scalar.await, ('SELECT COALESCE(MAX(id), 0) FROM `%s`'):format(src.tbl))
    if not ok then return nil end
    maxId = math.max(0, (tonumber(maxId) or 0) - (src.backlog or 0))
    saveCursor(src.key, maxId)
    return maxId
end

CreateThread(function()
    if INTERVAL <= 0 or not pushEvent then return end
    Wait(30000) -- apres backfill.lua, qui cree bl_telemetry_state

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS bl_telemetry_state (
            k VARCHAR(50) PRIMARY KEY,
            v VARCHAR(190) NOT NULL,
            updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])

    -- Tables suivies telles quelles : uniquement celles qui existent et ont une colonne id.
    for _, f in ipairs(FOLLOW) do
        local ok, hasId = pcall(MySQL.scalar.await, [[
            SELECT COUNT(*) FROM information_schema.columns
            WHERE table_schema = DATABASE() AND table_name = ? AND column_name = 'id'
        ]], { f.tbl })
        if ok and tonumber(hasId) == 1 then
            local backlog = f.anticheat and 0 or FOLLOW_BACKLOG -- pas de vieilles alertes anticheat au premier lancement
            SOURCES[#SOURCES + 1] = {
                key = ('follow_%s'):format(f.tbl):sub(1, 50), tbl = f.tbl, backlog = backlog,
                sql = ('SELECT * FROM `%s` WHERE id > ? ORDER BY id LIMIT ?'):format(f.tbl),
                mapMany = function(r) return mapRow(f, r) end,
            }
        end
    end

    local active = {}
    for _, src in ipairs(SOURCES) do
        local cursor = initCursor(src)
        if cursor then
            src.cursor = cursor
            active[#active + 1] = src
        end
    end
    if #active == 0 then return end

    while true do
        Wait(INTERVAL)
        for _, src in ipairs(active) do
            local ok, rows = pcall(MySQL.query.await, src.sql, { src.cursor, BATCH })
            if ok and rows and #rows > 0 then
                for _, r in ipairs(rows) do
                    while TelemetryQueueSize and TelemetryQueueSize() > 3000 do Wait(2000) end -- laisse l'envoi respirer
                    if src.mapMany then
                        for _, ev in ipairs(src.mapMany(r)) do pushEvent(ev) end
                    else
                        pushEvent(src.map(r))
                    end
                    src.cursor = math.max(src.cursor, tonumber(r.id) or src.cursor)
                end
                saveCursor(src.key, src.cursor)
            end
        end
    end
end)
