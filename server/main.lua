--[[
    bl_telemetry — pousse la telemetrie du serveur vers l'ingest-api (Postgres/Grafana).
    Tout est sortant (HTTP POST), aucun port entrant. File d'attente + envoi par lots :
    jamais bloquant pour le tick serveur ; en cas de panne de l'API les lots sont
    gardes (borne TELEMETRY_MAX_QUEUE) puis abandonnes en silence.

    Convars (server.cfg) :
        set telemetry_url   "https://ingest-api.webgune.dev"
        set telemetry_token "<token>"
]]

local URL   = GetConvar('telemetry_url', '')
local TOKEN = GetConvar('telemetry_token', '')

local FLUSH_INTERVAL_MS   = GetConvarInt('telemetry_flush_ms', 5000)
local SNAPSHOT_INTERVAL_S = GetConvarInt('telemetry_snapshot_s', 300)   -- economie + joueurs online
local VEHICLE_INTERVAL_S  = GetConvarInt('telemetry_vehicles_s', 21600) -- parc vehicules complet
local MAX_QUEUE           = 5000
local MAX_BATCH           = 200

if URL == '' or TOKEN == '' then
    print('^1[bl_telemetry] telemetry_url / telemetry_token manquants — telemetrie desactivee^0')
    return
end
URL = URL:gsub('/$', '')

local queue = {}      -- events
local logQueue = {}   -- lignes console / logs

local function now() return os.time() * 1000 end

local function push(ev)
    if #queue >= MAX_QUEUE then table.remove(queue, 1) end
    ev.ts = ev.ts or now()
    queue[#queue + 1] = ev
end

local function pushLog(line, labels)
    if #logQueue >= MAX_QUEUE then table.remove(logQueue, 1) end
    logQueue[#logQueue + 1] = { ts = now(), line = line, labels = labels }
end

-- Exposes pour server/backfill.lua (meme etat Lua, scripts serveur partages).
TelemetryPush = push
TelemetryQueueSize = function() return #queue end

-- Renvoie citizenid + nom RP pour une source, sans jamais planter si qbx_core absent.
local function ident(src)
    local ok, player = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    if ok and player then
        local pd = player.PlayerData
        local ci = pd.charinfo or {}
        return pd.citizenid, ('%s %s'):format(ci.firstname or '?', ci.lastname or '?')
    end
    return nil, GetPlayerName(src)
end

--------------------------------------------------------------------------------
-- Envoi par lots
--------------------------------------------------------------------------------

local function flush()
    if #queue == 0 and #logQueue == 0 then return end

    local events = {}
    for _ = 1, math.min(#queue, MAX_BATCH) do
        events[#events + 1] = table.remove(queue, 1)
    end
    local logs = {}
    for _ = 1, math.min(#logQueue, MAX_BATCH) do
        logs[#logs + 1] = table.remove(logQueue, 1)
    end

    PerformHttpRequest(URL .. '/v1/batch', function(status)
        if status ~= 200 then
            -- On remet en tete de file (borne par MAX_QUEUE au prochain push).
            for i = #events, 1, -1 do table.insert(queue, 1, events[i]) end
            for i = #logs, 1, -1 do table.insert(logQueue, 1, logs[i]) end
        end
    end, 'POST', json.encode({ events = events, logs = logs }), {
        ['Content-Type']  = 'application/json',
        ['Authorization'] = 'Bearer ' .. TOKEN,
    })
end

CreateThread(function()
    while true do
        Wait(FLUSH_INTERVAL_MS)
        flush()
    end
end)

--------------------------------------------------------------------------------
-- Console complete -> logs (filtre anti-bruit, pas de boucle sur nos propres prints)
--------------------------------------------------------------------------------

if RegisterConsoleListener then
    RegisterConsoleListener(function(channel, message)
        if not message or message == '' then return end
        if channel and channel:find('bl_telemetry') then return end
        if message:find('bl_telemetry') then return end
        -- Bruit recurrent sans valeur d'analyse.
        if message:find('Sending heartbeat') or message:find('server thread hitch') == 1 then return end
        local level = 'info'
        local low = message:lower()
        if low:find('error') or low:find('erreur') or low:find('exception') then level = 'error'
        elseif low:find('warn') then level = 'warn' end
        pushLog(message:sub(1, 4000), { channel = channel or 'console', level = level, source = 'console' })
    end)
else
    print('^3[bl_telemetry] RegisterConsoleListener indisponible — capture console desactivee^0')
end

--------------------------------------------------------------------------------
-- Sessions (connexion / deconnexion)
--------------------------------------------------------------------------------

AddEventHandler('playerJoining', function()
    local src = source
    push({
        type = 'session_start',
        src = src,
        player_name = GetPlayerName(src),
        data = { license = GetPlayerIdentifierByType(src, 'license') },
    })
end)

-- Une fois le personnage charge, on complete avec le citizenid.
RegisterNetEvent('QBCore:Server:OnPlayerLoaded', function()
    local src = source
    local cid, name = ident(src)
    push({ type = 'event', subtype = 'character_loaded', src = src, citizenid = cid, player_name = name, data = {} })
end)

AddEventHandler('playerDropped', function(reason)
    local src = source
    local cid, name = ident(src)
    push({
        type = 'session_end',
        src = src,
        citizenid = cid,
        player_name = name,
        data = { reason = reason, license = GetPlayerIdentifierByType(src, 'license') },
    })
end)

--------------------------------------------------------------------------------
-- Morts et kills (baseevents, declenches par le client cfx-default)
--------------------------------------------------------------------------------

RegisterNetEvent('baseevents:onPlayerDied', function(killerType, coords)
    local src = source
    local cid, name = ident(src)
    push({
        type = 'death', src = src, citizenid = cid, player_name = name,
        data = {
            cause = 'died', killer_type = killerType,
            x = coords and coords[1], y = coords and coords[2], z = coords and coords[3],
        },
    })
end)

RegisterNetEvent('baseevents:onPlayerKilled', function(killerId, deathData)
    local src = source
    local cid, name = ident(src)
    local kcid, kname
    if killerId and killerId > 0 then kcid, kname = ident(killerId) end
    deathData = deathData or {}
    local coords = deathData.killerpos or {}
    push({
        type = 'death', src = src, citizenid = cid, player_name = name,
        data = {
            cause = 'killed',
            killer_cid = kcid, killer_name = kname,
            weapon = deathData.weaponhash and tostring(deathData.weaponhash) or nil,
            x = coords[1], y = coords[2], z = coords[3],
        },
    })
end)

--------------------------------------------------------------------------------
-- Chat / commandes
--------------------------------------------------------------------------------

AddEventHandler('chatMessage', function(src, _, message)
    if src <= 0 then return end
    local cid, name = ident(src)
    push({
        type = 'event',
        subtype = message:sub(1, 1) == '/' and 'command' or 'chat',
        src = src, citizenid = cid, player_name = name,
        data = { message = message:sub(1, 500) },
    })
end)

--------------------------------------------------------------------------------
-- Actions staff txAdmin
--------------------------------------------------------------------------------

local function txEvent(action)
    return function(data)
        data = data or {}
        push({
            type = 'admin_action',
            data = {
                action = action,
                admin_name = data.author,
                target_name = data.targetName or (data.target and tostring(data.target)),
                reason = data.reason,
                duration = data.durationTranslated or data.duration,
            },
        })
    end
end

AddEventHandler('txAdmin:events:playerKicked', txEvent('kick'))
AddEventHandler('txAdmin:events:playerBanned', txEvent('ban'))
AddEventHandler('txAdmin:events:playerWarned', txEvent('warn'))
AddEventHandler('txAdmin:events:serverShuttingDown', txEvent('server_shutdown'))
AddEventHandler('txAdmin:events:scheduledRestart', txEvent('scheduled_restart'))

--------------------------------------------------------------------------------
-- Explosions (anticheat / anomalies)
--------------------------------------------------------------------------------

AddEventHandler('explosionEvent', function(sender, ev)
    local cid, name = ident(sender)
    push({
        type = 'event', subtype = 'explosion', src = sender, citizenid = cid, player_name = name,
        data = { explosion_type = ev and ev.explosionType, x = ev and ev.posX, y = ev and ev.posY, z = ev and ev.posZ },
    })
end)

--------------------------------------------------------------------------------
-- Interface pour les autres ressources (achats bl_shops, banque, etc.)
--  TriggerEvent('bl_telemetry:event', { type='purchase', citizenid=..., data={...} })
--  exports.bl_telemetry:LogEvent({...})
--------------------------------------------------------------------------------

local function logEvent(ev)
    if type(ev) ~= 'table' or not ev.type then return end
    push(ev)
end

AddEventHandler('bl_telemetry:event', logEvent)
exports('LogEvent', logEvent)

--------------------------------------------------------------------------------
-- Snapshots periodiques : economie + joueurs online
--------------------------------------------------------------------------------

local function snapshotEconomy()
    MySQL.single([[
        SELECT COUNT(*) AS chars_total,
               COALESCE(SUM(CAST(JSON_EXTRACT(money, '$.cash') AS DECIMAL(18,2))), 0)   AS total_cash,
               COALESCE(SUM(CAST(JSON_EXTRACT(money, '$.bank') AS DECIMAL(18,2))), 0)   AS total_bank,
               COALESCE(SUM(CAST(JSON_EXTRACT(money, '$.crypto') AS DECIMAL(18,4))), 0) AS total_crypto
        FROM players
    ]], {}, function(row)
        if not row then return end
        push({
            type = 'economy_snapshot',
            data = {
                player_count = #GetPlayers(),
                chars_total = tonumber(row.chars_total) or 0,
                total_cash = math.floor(tonumber(row.total_cash) or 0),
                total_bank = math.floor(tonumber(row.total_bank) or 0),
                total_crypto = tonumber(row.total_crypto) or 0,
            },
        })
    end)
end

-- Inventaire compact {n=nom, c=quantite} pour un joueur online (ox_inventory).
local function inventoryOf(src)
    local ok, items = pcall(function() return exports.ox_inventory:GetInventoryItems(src) end)
    if not ok or type(items) ~= 'table' then return nil end
    local out = {}
    for _, it in pairs(items) do
        if it and it.name then out[#out + 1] = { n = it.name, c = it.count or 1 } end
    end
    return out
end

local function snapshotPlayers()
    local ok, players = pcall(function() return exports.qbx_core:GetQBPlayers() end)
    if not ok or not players then return end
    for _, player in pairs(players) do
        local pd = player.PlayerData
        if pd and pd.citizenid then
            local ci = pd.charinfo or {}
            local money = pd.money or {}
            push({
                type = 'player_snapshot',
                citizenid = pd.citizenid,
                player_name = ('%s %s'):format(ci.firstname or '?', ci.lastname or '?'),
                src = pd.source,
                data = {
                    job = pd.job and pd.job.name, job_grade = pd.job and pd.job.grade and pd.job.grade.level,
                    gang = pd.gang and pd.gang.name,
                    cash = money.cash or 0, bank = money.bank or 0, crypto = money.crypto or 0,
                    online = true,
                    extra = { inventory = inventoryOf(pd.source) },
                },
            })
        end
    end
end

local function snapshotVehicles()
    MySQL.query([[
        SELECT citizenid, plate, vehicle, garage, state FROM player_vehicles LIMIT 8000
    ]], {}, function(rows)
        if not rows then return end
        for _, r in ipairs(rows) do
            push({
                type = 'vehicle_snapshot',
                citizenid = r.citizenid,
                data = { plate = r.plate, model = r.vehicle, garage = r.garage, state = r.state },
            })
        end
    end)
end

CreateThread(function()
    Wait(15000) -- laisse qbx_core/oxmysql demarrer
    push({ type = 'event', subtype = 'server_start', data = {} })
    snapshotEconomy()
    snapshotVehicles()
    local lastVehicles = os.time()
    while true do
        Wait(SNAPSHOT_INTERVAL_S * 1000)
        snapshotEconomy()
        snapshotPlayers()
        if os.time() - lastVehicles >= VEHICLE_INTERVAL_S then
            lastVehicles = os.time()
            snapshotVehicles()
        end
    end
end)

print(('^2[bl_telemetry] actif -> %s (lots: %dms)^0'):format(URL, FLUSH_INTERVAL_MS))
