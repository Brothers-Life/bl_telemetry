--[[
    bl_telemetry/live — suit en continu les tables du jeu que backfill.lua ne reprend qu'une fois :
      - bank_flows          -> events subtype 'bank_flow'   (virements, depots, retraits)
      - bank_audit_log      -> admin_action 'bank_*'        (actions staff banque)
      - bl_shops_admin_logs -> events subtype 'shop_admin'  (actions staff shops)
    Un curseur (dernier id lu) par table est garde dans bl_telemetry_state : pas de doublon apres
    un redemarrage, et au tout premier lancement on part de la fin (le backfill couvre l'historique).
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

local function saveCursor(key, id)
    MySQL.insert.await('INSERT INTO bl_telemetry_state (k, v) VALUES (?, ?) ON DUPLICATE KEY UPDATE v = VALUES(v)', { key, tostring(id) })
end

-- Renvoie le curseur de depart, ou nil si la table n'existe pas sur ce serveur.
local function initCursor(src)
    local saved = MySQL.single.await('SELECT v FROM bl_telemetry_state WHERE k = ?', { src.key })
    if saved and tonumber(saved.v) then return tonumber(saved.v) end
    local ok, maxId = pcall(MySQL.scalar.await, ('SELECT COALESCE(MAX(id), 0) FROM %s'):format(src.tbl))
    if not ok then return nil end
    maxId = tonumber(maxId) or 0
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
                    pushEvent(src.map(r))
                    src.cursor = math.max(src.cursor, tonumber(r.id) or src.cursor)
                end
                saveCursor(src.key, src.cursor)
            end
        end
    end
end)
