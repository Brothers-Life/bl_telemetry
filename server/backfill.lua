--[[
    bl_telemetry/backfill — reprise de l'historique deja present dans la base MySQL
    du jeu, pour que Grafana ait des stats des le premier jour :
      - tous les personnages (players)            -> player_snapshot (fortunes, jobs)
      - bank_flows (virements/depots/retraits)    -> events subtype 'bank_flow' (ts reels)
      - bank_audit_log (actions staff banque)     -> admin_action (ts reels)
      - bl_shops_admin_logs (actions staff shops) -> events subtype 'shop_admin' (ts reels)
    Ne tourne qu'UNE fois : marqueur dans la table MySQL bl_telemetry_state.
    (Les vehicules sont deja couverts par le snapshot de main.lua.)
]]

local CAPS = { flows = 50000, audit = 10000, shops = 10000 }

-- Fournis par main.lua via _ENV (meme ressource, fxv2 oal)
local pushEvent = TelemetryPush
local queueSize = TelemetryQueueSize

-- Enfile sans jamais deborder la file : on laisse l'envoi par lots respirer.
local function pushPaced(ev)
    while queueSize() > 3000 do Wait(2000) end
    pushEvent(ev)
end

local function decode(s)
    if type(s) ~= 'string' or s == '' then return {} end
    local ok, t = pcall(json.decode, s)
    return ok and t or {}
end

local function backfillPlayers()
    local rows = MySQL.query.await([[
        SELECT citizenid, charinfo, money, job, gang, inventory,
               UNIX_TIMESTAMP(last_logged_out) AS last_seen
        FROM players
    ]]) or {}
    for _, r in ipairs(rows) do
        local ci, money = decode(r.charinfo), decode(r.money)
        local job, gang = decode(r.job), decode(r.gang)
        -- Inventaire compact {n, c} depuis la colonne JSON d'ox_inventory.
        local inv = {}
        for _, it in pairs(decode(r.inventory)) do
            if type(it) == 'table' and it.name then inv[#inv + 1] = { n = it.name, c = it.count or 1 } end
        end
        pushPaced({
            type = 'player_snapshot',
            citizenid = r.citizenid,
            player_name = ('%s %s'):format(ci.firstname or '?', ci.lastname or '?'),
            data = {
                job = job.name, job_grade = job.grade and (job.grade.level or job.grade),
                gang = gang.name,
                cash = money.cash or 0, bank = money.bank or 0, crypto = money.crypto or 0,
                online = false,
                extra = { backfill = true, last_seen = r.last_seen, inventory = inv },
            },
        })
    end
    return #rows
end

local function backfillBankFlows()
    local rows = MySQL.query.await(([[
        SELECT UNIX_TIMESTAMP(created_at) * 1000 AS ts_ms, kind, from_cid, to_cid, amount, note
        FROM bank_flows ORDER BY id DESC LIMIT %d
    ]]):format(CAPS.flows)) or {}
    for _, r in ipairs(rows) do
        pushPaced({
            type = 'event', subtype = 'bank_flow', ts = tonumber(r.ts_ms),
            citizenid = r.from_cid,
            data = { kind = r.kind, from_cid = r.from_cid, to_cid = r.to_cid,
                     amount = tonumber(r.amount) or 0, note = r.note, backfill = true },
        })
    end
    return #rows
end

local function backfillBankAudit()
    local rows = MySQL.query.await(([[
        SELECT UNIX_TIMESTAMP(created_at) * 1000 AS ts_ms, admin_name, action, target,
               amount_before, amount_after, details
        FROM bank_audit_log ORDER BY id DESC LIMIT %d
    ]]):format(CAPS.audit)) or {}
    for _, r in ipairs(rows) do
        pushPaced({
            type = 'admin_action', ts = tonumber(r.ts_ms),
            data = { action = 'bank_' .. (r.action or '?'), admin_name = r.admin_name,
                     target_name = r.target,
                     reason = r.details,
                     extra = { amount_before = r.amount_before, amount_after = r.amount_after, backfill = true } },
        })
    end
    return #rows
end

local function backfillShopLogs()
    local ok, rows = pcall(function()
        return MySQL.query.await(([[
            SELECT UNIX_TIMESTAMP(created_at) * 1000 AS ts_ms, action, shop_id, admin_name, details
            FROM bl_shops_admin_logs ORDER BY id DESC LIMIT %d
        ]]):format(CAPS.shops))
    end)
    if not ok or not rows then return 0 end
    for _, r in ipairs(rows) do
        pushPaced({
            type = 'event', subtype = 'shop_admin', ts = tonumber(r.ts_ms),
            player_name = r.admin_name,
            data = { action = r.action, shop_id = r.shop_id, details = r.details, backfill = true },
        })
    end
    return #rows
end

CreateThread(function()
    Wait(20000) -- apres le demarrage de main.lua et d'oxmysql
    if not pushEvent then
        print('^1[bl_telemetry] backfill: TelemetryPush indisponible^0')
        return
    end

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS bl_telemetry_state (
            k VARCHAR(50) PRIMARY KEY,
            v VARCHAR(190) NOT NULL,
            updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    local done = MySQL.single.await('SELECT v FROM bl_telemetry_state WHERE k = ?', { 'backfill_done' })
    if done and done.v == '1' then return end

    print('^3[bl_telemetry] backfill historique en cours…^0')
    local nPlayers = backfillPlayers()
    local nFlows = backfillBankFlows()
    local nAudit = backfillBankAudit()
    local nShops = backfillShopLogs()

    MySQL.insert.await('INSERT INTO bl_telemetry_state (k, v) VALUES (?, ?) ON DUPLICATE KEY UPDATE v = VALUES(v)',
        { 'backfill_done', '1' })
    print(('^2[bl_telemetry] backfill termine : %d persos, %d flux banque, %d audits, %d logs shops^0')
        :format(nPlayers, nFlows, nAudit, nShops))
end)
