--[[
    bl_telemetry — pousse la telemetrie du serveur vers l'ingest-api (Postgres/Grafana).
    Tout est sortant (HTTP POST), aucun port entrant. File d'attente + envoi par lots :
    jamais bloquant pour le tick serveur ; en cas de panne de l'API les lots sont
    gardes (borne TELEMETRY_MAX_QUEUE) puis abandonnes en silence.

    Convars (server.cfg) :
        set telemetry_url   "https://ingest-api.webgune.dev"
        set telemetry_token "<token>"
    Facultatif :
        set telemetry_society_sql "SELECT COALESCE(SUM(amount),0) AS total FROM management_funds"
        set telemetry_live_ms 30000   -- relecture des tables banque / shops (0 = off)
        set telemetry_commands 1       -- ordres du panel (annonces) recus avec chaque envoi (0 = off)
]]

local URL   = GetConvar('telemetry_url', '')
local TOKEN = GetConvar('telemetry_token', '')

local FLUSH_INTERVAL_MS   = GetConvarInt('telemetry_flush_ms', 5000)
local SNAPSHOT_INTERVAL_S = GetConvarInt('telemetry_snapshot_s', 300)   -- economie + joueurs online
local VEHICLE_INTERVAL_S  = GetConvarInt('telemetry_vehicles_s', 21600) -- parc vehicules complet
local MAX_QUEUE           = 10000  -- par file (events / logs)
local MAX_BATCH_EVENTS    = 300
local MAX_BATCH_LOGS      = 500
local COMMANDS_ENABLED    = GetConvarInt('telemetry_commands', 1) == 1

if URL == '' or TOKEN == '' then
    print('^1[bl_telemetry] telemetry_url / telemetry_token manquants — telemetrie desactivee^0')
    return
end
URL = URL:gsub('/$', '')

-- File FIFO a indices (ajout et retrait en O(1), contrairement a table.remove(t, 1)).
local function newQueue() return { first = 1, last = 0, items = {}, dropped = 0 } end
local function qsize(q) return q.last - q.first + 1 end
local function qpush(q, v)
    if qsize(q) >= MAX_QUEUE then -- file pleine : on sacrifie le plus ancien
        q.items[q.first] = nil
        q.first = q.first + 1
        q.dropped = q.dropped + 1
    end
    q.last = q.last + 1
    q.items[q.last] = v
end
local function qtake(q, n)
    local out = {}
    for i = 1, math.min(n, qsize(q)) do
        out[i] = q.items[q.first]
        q.items[q.first] = nil
        q.first = q.first + 1
    end
    return out
end
local function qrequeue(q, list) -- remet un lot non envoye en tete, dans l'ordre
    for i = #list, 1, -1 do
        q.first = q.first - 1
        q.items[q.first] = list[i]
    end
    while qsize(q) > MAX_QUEUE do q.items[q.first] = nil; q.first = q.first + 1; q.dropped = q.dropped + 1 end
end

local queue = newQueue()      -- events
local logQueue = newQueue()   -- lignes console / logs

local function now() return os.time() * 1000 end

local function push(ev)
    ev.ts = ev.ts or now()
    qpush(queue, ev)
end

local function pushLog(line, labels)
    qpush(logQueue, { ts = now(), line = line, labels = labels })
end

-- Exposes pour backfill.lua, live.lua et dbsync.lua (meme etat Lua, scripts serveur partages).
TelemetryPush = push
TelemetryQueueSize = function() return qsize(queue) end

-- citizenid + nom RP d'une source, avec cache (60 s) : evite un appel a qbx_core a chaque chat / mort / explosion.
local identCache = {}
local function ident(src)
    src = tonumber(src)
    if not src or src <= 0 then return nil, nil end
    local c = identCache[src]
    if c and GetGameTimer() - c.t < 60000 then return c.cid, c.name end
    local cid, name
    local ok, player = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    if ok and player and player.PlayerData then
        local pd = player.PlayerData
        local ci = pd.charinfo or {}
        cid, name = pd.citizenid, ('%s %s'):format(ci.firstname or '?', ci.lastname or '?')
    else
        name = GetPlayerName(src)
    end
    identCache[src] = { cid = cid, name = name, t = GetGameTimer() }
    return cid, name
end

-- Hash d'arme -> nom lisible. Les hash arrivent signes ou non selon la source : on normalise.
local function normHash(h)
    h = tonumber(h)
    if not h then return nil end
    h = math.floor(h)
    if h > 2147483647 then h = h - 4294967296 end
    return h
end

local WEAPONS = {
    -- corps a corps
    'WEAPON_UNARMED', 'WEAPON_KNIFE', 'WEAPON_NIGHTSTICK', 'WEAPON_HAMMER', 'WEAPON_BAT', 'WEAPON_GOLFCLUB',
    'WEAPON_CROWBAR', 'WEAPON_BOTTLE', 'WEAPON_DAGGER', 'WEAPON_HATCHET', 'WEAPON_KNUCKLE', 'WEAPON_MACHETE',
    'WEAPON_SWITCHBLADE', 'WEAPON_WRENCH', 'WEAPON_BATTLEAXE', 'WEAPON_POOLCUE', 'WEAPON_STONE_HATCHET', 'WEAPON_FLASHLIGHT',
    -- pistolets
    'WEAPON_PISTOL', 'WEAPON_PISTOL_MK2', 'WEAPON_COMBATPISTOL', 'WEAPON_APPISTOL', 'WEAPON_STUNGUN', 'WEAPON_PISTOL50',
    'WEAPON_SNSPISTOL', 'WEAPON_SNSPISTOL_MK2', 'WEAPON_HEAVYPISTOL', 'WEAPON_VINTAGEPISTOL', 'WEAPON_FLAREGUN',
    'WEAPON_MARKSMANPISTOL', 'WEAPON_REVOLVER', 'WEAPON_REVOLVER_MK2', 'WEAPON_DOUBLEACTION', 'WEAPON_RAYPISTOL',
    'WEAPON_CERAMICPISTOL', 'WEAPON_NAVYREVOLVER', 'WEAPON_GADGETPISTOL',
    -- mitraillettes
    'WEAPON_MICROSMG', 'WEAPON_SMG', 'WEAPON_SMG_MK2', 'WEAPON_ASSAULTSMG', 'WEAPON_COMBATPDW', 'WEAPON_MACHINEPISTOL',
    'WEAPON_MINISMG', 'WEAPON_RAYCARBINE',
    -- fusils a pompe
    'WEAPON_PUMPSHOTGUN', 'WEAPON_PUMPSHOTGUN_MK2', 'WEAPON_SAWNOFFSHOTGUN', 'WEAPON_ASSAULTSHOTGUN', 'WEAPON_BULLPUPSHOTGUN',
    'WEAPON_MUSKET', 'WEAPON_HEAVYSHOTGUN', 'WEAPON_DBSHOTGUN', 'WEAPON_AUTOSHOTGUN', 'WEAPON_COMBATSHOTGUN',
    -- fusils d'assaut
    'WEAPON_ASSAULTRIFLE', 'WEAPON_ASSAULTRIFLE_MK2', 'WEAPON_CARBINERIFLE', 'WEAPON_CARBINERIFLE_MK2', 'WEAPON_ADVANCEDRIFLE',
    'WEAPON_SPECIALCARBINE', 'WEAPON_SPECIALCARBINE_MK2', 'WEAPON_BULLPUPRIFLE', 'WEAPON_BULLPUPRIFLE_MK2', 'WEAPON_COMPACTRIFLE',
    'WEAPON_MILITARYRIFLE', 'WEAPON_HEAVYRIFLE', 'WEAPON_TACTICALRIFLE',
    -- mitrailleuses / precision
    'WEAPON_MG', 'WEAPON_COMBATMG', 'WEAPON_COMBATMG_MK2', 'WEAPON_GUSENBERG',
    'WEAPON_SNIPERRIFLE', 'WEAPON_HEAVYSNIPER', 'WEAPON_HEAVYSNIPER_MK2', 'WEAPON_MARKSMANRIFLE', 'WEAPON_MARKSMANRIFLE_MK2',
    'WEAPON_PRECISIONRIFLE',
    -- lourdes / lancers
    'WEAPON_RPG', 'WEAPON_GRENADELAUNCHER', 'WEAPON_MINIGUN', 'WEAPON_FIREWORK', 'WEAPON_RAILGUN', 'WEAPON_HOMINGLAUNCHER',
    'WEAPON_COMPACTLAUNCHER', 'WEAPON_RAYMINIGUN', 'WEAPON_GRENADE', 'WEAPON_BZGAS', 'WEAPON_MOLOTOV', 'WEAPON_STICKYBOMB',
    'WEAPON_PROXMINE', 'WEAPON_PIPEBOMB', 'WEAPON_SMOKEGRENADE', 'WEAPON_FLARE', 'WEAPON_PETROLCAN', 'WEAPON_FIREEXTINGUISHER',
    -- causes environnementales
    'WEAPON_FALL', 'WEAPON_DROWNING', 'WEAPON_DROWNING_IN_VEHICLE', 'WEAPON_RUN_OVER_BY_CAR', 'WEAPON_RAMMED_BY_CAR',
    'WEAPON_EXPLOSION', 'WEAPON_FIRE', 'WEAPON_BLEEDING', 'WEAPON_EXHAUSTION', 'WEAPON_ELECTRIC_FENCE', 'WEAPON_BARBED_WIRE',
    'WEAPON_ANIMAL', 'WEAPON_COUGAR', 'WEAPON_HIT_BY_WATER_CANNON', 'WEAPON_HELI_CRASH', 'VEHICLE_WEAPON_ROTORS',
}
local WEAPON_BY_HASH = {}
for _, name in ipairs(WEAPONS) do WEAPON_BY_HASH[normHash(GetHashKey(name))] = name end

local MELEE = {}
for i = 2, 18 do MELEE[WEAPONS[i]] = true end
local CAUSE_BY_WEAPON = {
    WEAPON_UNARMED = 'poings', WEAPON_FALL = 'chute', WEAPON_DROWNING = 'noyade', WEAPON_DROWNING_IN_VEHICLE = 'noyade',
    WEAPON_RUN_OVER_BY_CAR = 'vehicule', WEAPON_RAMMED_BY_CAR = 'vehicule', WEAPON_HELI_CRASH = 'vehicule', VEHICLE_WEAPON_ROTORS = 'vehicule',
    WEAPON_EXPLOSION = 'explosion', WEAPON_GRENADE = 'explosion', WEAPON_STICKYBOMB = 'explosion', WEAPON_PROXMINE = 'explosion',
    WEAPON_PIPEBOMB = 'explosion', WEAPON_RPG = 'explosion', WEAPON_GRENADELAUNCHER = 'explosion', WEAPON_HOMINGLAUNCHER = 'explosion',
    WEAPON_COMPACTLAUNCHER = 'explosion', WEAPON_FIREWORK = 'explosion', WEAPON_RAILGUN = 'explosion',
    WEAPON_FIRE = 'feu', WEAPON_MOLOTOV = 'feu', WEAPON_PETROLCAN = 'feu', WEAPON_FLAREGUN = 'feu',
    WEAPON_BLEEDING = 'saignement', WEAPON_EXHAUSTION = 'epuisement', WEAPON_ELECTRIC_FENCE = 'electrocution',
    WEAPON_STUNGUN = 'electrocution', WEAPON_BARBED_WIRE = 'barbeles', WEAPON_ANIMAL = 'animal', WEAPON_COUGAR = 'animal',
    WEAPON_BZGAS = 'gaz', WEAPON_SMOKEGRENADE = 'gaz', WEAPON_HIT_BY_WATER_CANNON = 'canon a eau',
}

-- Renvoie nom d'arme + categorie de cause a partir d'un hash.
local function describeWeapon(hash)
    hash = normHash(hash)
    if not hash or hash == 0 then return nil, 'inconnue' end
    local name = WEAPON_BY_HASH[hash]
    if not name then return tostring(hash), 'inconnue' end
    return name, CAUSE_BY_WEAPON[name] or (MELEE[name] and 'arme blanche') or 'balle'
end

-- Position et cause cote serveur (OneSync) : plus fiable que les donnees envoyees par le client.
local function deathInfo(src, clientCoords, clientWeapon)
    local ped = GetPlayerPed(src)
    local x, y, z
    if ped and ped ~= 0 then
        local c = GetEntityCoords(ped)
        if c and (c.x ~= 0 or c.y ~= 0) then x, y, z = c.x, c.y, c.z end
    end
    if not x and type(clientCoords) == 'table' then
        x, y, z = clientCoords.x or clientCoords[1], clientCoords.y or clientCoords[2], clientCoords.z or clientCoords[3]
    end
    local hash = clientWeapon
    if ped and ped ~= 0 then
        local ok, h = pcall(GetPedCauseOfDeath, ped)
        if ok and h and h ~= 0 then hash = h end
    end
    local weapon, cause = describeWeapon(hash)
    return x, y, z, weapon, cause
end

--------------------------------------------------------------------------------
-- Envoi par lots
--------------------------------------------------------------------------------

-- Un seul envoi a la fois ; en cas de panne de l'API, attente croissante (2 s -> 60 s) ;
-- s'il reste du retard apres un envoi reussi, on renvoie aussitot (vidange) au lieu d'attendre 5 s.
-- Les ordres du panel (annonces) arrivent dans la reponse, et leurs resultats repartent avec l'envoi suivant.
local inFlight, failures, nextTry = false, 0, 0
local pendingAcks = {}
local runCommands -- defini plus bas

local HEADERS = { ['Content-Type'] = 'application/json', ['Authorization'] = 'Bearer ' .. TOKEN }

local function flush(force)
    if inFlight or GetGameTimer() < nextTry then return end
    local events = qtake(queue, MAX_BATCH_EVENTS)
    local logs = qtake(logQueue, MAX_BATCH_LOGS)
    local acks = pendingAcks
    if #events == 0 and #logs == 0 and #acks == 0 and not force then return end
    pendingAcks = {}
    inFlight = true

    local body = { events = events, logs = logs }
    if #acks > 0 then body.acks = acks end
    PerformHttpRequest(URL .. '/v1/batch' .. (COMMANDS_ENABLED and '?commands=1' or ''), function(status, resp)
        inFlight = false
        if status ~= 200 then
            qrequeue(queue, events)
            qrequeue(logQueue, logs)
            for _, a in ipairs(acks) do pendingAcks[#pendingAcks + 1] = a end
            failures = failures + 1
            nextTry = GetGameTimer() + math.min(60000, 1000 * 2 ^ math.min(failures, 6))
            return
        end
        failures, nextTry = 0, 0
        if COMMANDS_ENABLED and resp and resp ~= '' and runCommands then runCommands(resp) end
        if qsize(queue) > 0 or qsize(logQueue) >= MAX_BATCH_LOGS or #pendingAcks > 0 then
            SetTimeout(200, flush)
        end
    end, 'POST', json.encode(body), HEADERS)
end

CreateThread(function()
    local lastDropWarn = 0
    while true do
        Wait(FLUSH_INTERVAL_MS)
        flush(COMMANDS_ENABLED) -- envoi a vide si besoin, pour relever les annonces
        local dropped = queue.dropped + logQueue.dropped
        if dropped > 0 and GetGameTimer() - lastDropWarn > 60000 then
            lastDropWarn = GetGameTimer()
            print(('^3[bl_telemetry] file pleine : %d element(s) abandonne(s) (API lente ou injoignable ?)^0'):format(dropped))
            queue.dropped, logQueue.dropped = 0, 0
        end
    end
end)

--------------------------------------------------------------------------------
-- Console complete -> logs (filtre anti-bruit, pas de boucle sur nos propres prints)
--------------------------------------------------------------------------------

if RegisterConsoleListener then
    RegisterConsoleListener(function(channel, message)
        if not message or message == '' then return end
        if channel and channel:find('bl_telemetry', 1, true) then return end
        if message:find('bl_telemetry', 1, true) then return end
        -- Bruit recurrent sans valeur d'analyse.
        if message:find('Sending heartbeat', 1, true) then return end
        local level = 'info'
        local low = message:sub(1, 400):lower() -- le niveau se lit en debut de ligne
        if low:find('error') or low:find('erreur') or low:find('exception') then level = 'error'
        elseif low:find('warn') then level = 'warn' end
        -- Ralentissements du serveur : gardes en warn pour la page Scripts du panel.
        if low:find('hitch warning') then level = 'warn' end
        -- Detections anticheat : remontees en warn pour declencher les alertes du panel.
        if level == 'info' and channel and channel:lower():find('anticheat')
            and (low:find('detect') or low:find('ban') or low:find('kick') or low:find('suspect') or low:find('flag') or low:find('cheat')) then
            level = 'warn'
        end
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
    identCache[src] = nil -- changement de personnage possible
    local cid, name = ident(src)
    -- La licence permet a l'API de rattacher la session ouverte a ce personnage.
    push({ type = 'event', subtype = 'character_loaded', src = src, citizenid = cid, player_name = name,
           data = { license = GetPlayerIdentifierByType(src, 'license') } })
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
    identCache[src] = nil
    -- Dernier releve "hors ligne", sinon le panel garde le joueur en ligne jusqu'au prochain backfill.
    local ok, player = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    local pd = ok and player and player.PlayerData
    if pd and pd.citizenid then
        local money = pd.money or {}
        push({
            type = 'player_snapshot', citizenid = pd.citizenid, player_name = name, src = src,
            data = {
                job = pd.job and pd.job.name, job_grade = pd.job and pd.job.grade and pd.job.grade.level,
                gang = pd.gang and pd.gang.name,
                cash = money.cash or 0, bank = money.bank or 0, crypto = money.crypto or 0,
                online = false,
            },
        })
    end
end)

--------------------------------------------------------------------------------
-- Morts et kills (baseevents, declenches par le client cfx-default)
--------------------------------------------------------------------------------

RegisterNetEvent('baseevents:onPlayerDied', function(killerType, coords)
    local src = source
    local cid, name = ident(src)
    local x, y, z, weapon, cause = deathInfo(src, coords, nil)
    push({
        type = 'death', src = src, citizenid = cid, player_name = name,
        data = { cause = cause, weapon = weapon, killer_type = killerType, x = x, y = y, z = z },
    })
end)

-- Attention : deathData.killerpos est la position du TUEUR ; la position de la victime vient du serveur.
RegisterNetEvent('baseevents:onPlayerKilled', function(killerId, deathData)
    local src = source
    local cid, name = ident(src)
    local kcid, kname
    if killerId and killerId > 0 then kcid, kname = ident(killerId) end
    deathData = deathData or {}
    local x, y, z, weapon, cause = deathInfo(src, nil, deathData.weaponhash)
    push({
        type = 'death', src = src, citizenid = cid, player_name = name,
        data = {
            cause = cause, weapon = weapon,
            killer_cid = kcid, killer_name = kname,
            killer_in_vehicle = deathData.killerinveh or nil,
            x = x, y = y, z = z,
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
        data = type(data) == 'table' and data or {}
        local target = tonumber(data.target or data.targetNetId or data.id)
        local tcid, tname
        if target and target > 0 then tcid, tname = ident(target) end
        push({
            type = 'admin_action',
            citizenid = tcid,
            data = {
                action = action,
                admin_name = data.author or data.adminName or data.revokedBy,
                target_name = data.targetName or tname or (data.target and tostring(data.target)),
                target_cid = tcid,
                reason = data.reason or data.message,
                duration = data.durationTranslated or data.duration,
                source = 'txAdmin',
            },
        })
    end
end

AddEventHandler('txAdmin:events:playerKicked', txEvent('kick'))
AddEventHandler('txAdmin:events:playerBanned', txEvent('ban'))
AddEventHandler('txAdmin:events:playerWarned', txEvent('warn'))
AddEventHandler('txAdmin:events:serverShuttingDown', txEvent('server_shutdown'))
AddEventHandler('txAdmin:events:scheduledRestart', txEvent('scheduled_restart'))
AddEventHandler('txAdmin:events:skippedNextScheduledRestart', txEvent('restart_skipped'))
AddEventHandler('txAdmin:events:playerHealed', txEvent('heal'))
AddEventHandler('txAdmin:events:playerDirectMessage', txEvent('direct_message'))
AddEventHandler('txAdmin:events:announcement', txEvent('announcement'))
AddEventHandler('txAdmin:events:actionRevoked', txEvent('revoke'))
AddEventHandler('txAdmin:events:whitelistPlayer', txEvent('whitelist'))
AddEventHandler('txAdmin:events:whitelistPreApproval', txEvent('whitelist_preapproval'))

--------------------------------------------------------------------------------
-- Explosions (anticheat / anomalies)
--------------------------------------------------------------------------------

-- Limite : 10 explosions par joueur toutes les 10 s ; au-dela, un seul resume (un tricheur peut en generer des centaines).
local explosionWindow = {}
local EXPLOSION_MAX, EXPLOSION_WINDOW_MS = 10, 10000

local function flushExplosionWindow(sender, w)
    if w.suppressed > 0 then
        push({
            type = 'event', subtype = 'explosion_flood', src = sender, citizenid = w.cid, player_name = w.name,
            data = { count = w.count, suppressed = w.suppressed, window_s = EXPLOSION_WINDOW_MS / 1000 },
        })
    end
end

AddEventHandler('explosionEvent', function(sender, ev)
    local t = GetGameTimer()
    local w = explosionWindow[sender]
    if not w or t - w.start > EXPLOSION_WINDOW_MS then
        if w then flushExplosionWindow(sender, w) end
        local cid, name = ident(sender)
        w = { start = t, count = 0, suppressed = 0, cid = cid, name = name }
        explosionWindow[sender] = w
    end
    w.count = w.count + 1
    if w.count > EXPLOSION_MAX then w.suppressed = w.suppressed + 1; return end
    push({
        type = 'event', subtype = 'explosion', src = sender, citizenid = w.cid, player_name = w.name,
        data = { explosion_type = ev and ev.explosionType, x = ev and ev.posX, y = ev and ev.posY, z = ev and ev.posZ },
    })
end)

-- Ferme les fenetres d'explosions terminees (resume des rafales) et nettoie le cache des joueurs partis.
CreateThread(function()
    while true do
        Wait(EXPLOSION_WINDOW_MS)
        local t = GetGameTimer()
        for sender, w in pairs(explosionWindow) do
            if t - w.start > EXPLOSION_WINDOW_MS then flushExplosionWindow(sender, w); explosionWindow[sender] = nil end
        end
    end
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

-- Detection anticheat explicite -> alerte immediate dans le panel (et Discord).
--  exports.bl_telemetry:Anticheat(source, 'noclip', { vitesse = 42 })
--  TriggerEvent('bl_telemetry:anticheat', source, 'noclip', { ... })
local function anticheat(src, reason, details)
    src = tonumber(src)
    local cid, name
    if src and src > 0 then cid, name = ident(src) end
    push({
        type = 'anticheat', src = src, citizenid = cid, player_name = name,
        data = { reason = tostring(reason or 'detection'), details = type(details) == 'table' and details or { info = details } },
    })
end
AddEventHandler('bl_telemetry:anticheat', anticheat)
exports('Anticheat', anticheat)

--------------------------------------------------------------------------------
-- Snapshots periodiques : economie + joueurs online
--------------------------------------------------------------------------------

-- Argent des societes : requete reglable par convar, sinon on essaie les tables courantes.
local SOCIETY_CANDIDATES = {
    GetConvar('telemetry_society_sql', ''),
    'SELECT COALESCE(SUM(amount), 0) AS total FROM management_funds',
    'SELECT COALESCE(SUM(amount), 0) AS total FROM bank_accounts_new',
}
local societySql -- false = aucune table trouvee

local function societyTotal()
    if societySql == false then return nil end
    if societySql then
        local ok, v = pcall(MySQL.scalar.await, societySql)
        return ok and tonumber(v) or nil
    end
    for _, sql in ipairs(SOCIETY_CANDIDATES) do
        if sql ~= '' then
            local ok, v = pcall(MySQL.scalar.await, sql)
            if ok and v ~= nil then
                societySql = sql
                return tonumber(v)
            end
        end
    end
    societySql = false
    print('^3[bl_telemetry] argent des societes : aucune table trouvee (convar telemetry_society_sql)^0')
    return nil
end

local function snapshotEconomy()
    CreateThread(function()
        local row = MySQL.single.await([[
            SELECT COUNT(*) AS chars_total,
                   COALESCE(SUM(CAST(JSON_EXTRACT(money, '$.cash') AS DECIMAL(30,2))), 0)   AS total_cash,
                   COALESCE(SUM(CAST(JSON_EXTRACT(money, '$.bank') AS DECIMAL(30,2))), 0)   AS total_bank,
                   COALESCE(SUM(CAST(JSON_EXTRACT(money, '$.crypto') AS DECIMAL(30,4))), 0) AS total_crypto
            FROM players
        ]])
        if not row then return end
        local society = societyTotal()
        push({
            type = 'economy_snapshot',
            data = {
                player_count = #GetPlayers(),
                chars_total = tonumber(row.chars_total) or 0,
                total_cash = math.floor(tonumber(row.total_cash) or 0),
                total_bank = math.floor(tonumber(row.total_bank) or 0),
                total_crypto = tonumber(row.total_crypto) or 0,
                society_total = society and math.floor(society) or nil,
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
    CreateThread(function()
        local rows = MySQL.query.await('SELECT citizenid, plate, vehicle, garage, state FROM player_vehicles LIMIT 20000') or {}
        for i, r in ipairs(rows) do
            if i % 200 == 0 then
                while qsize(queue) > MAX_QUEUE / 2 do Wait(1000) end -- laisse l'envoi respirer
            end
            push({
                type = 'vehicle_snapshot',
                citizenid = r.citizenid,
                data = { plate = r.plate, model = r.vehicle, garage = r.garage, state = r.state },
            })
        end
    end)
end

-- Etat de toutes les ressources (pages Scripts et Performances du panel) :
-- carte / MLO, fichiers de donnees (data_file), scripts client / serveur et fichiers envoyes aux joueurs.
local function metaCount(name, ...)
    local n = 0
    for _, key in ipairs({ ... }) do n = n + (GetNumResourceMetadata(name, key) or 0) end
    return n
end

local function snapshotResources()
    local rows = {}
    for i = 0, GetNumResources() - 1 do
        local name = GetResourceByFindIndex(i)
        if name then
            local isMap = (GetResourceMetadata(name, 'this_is_a_map', 0) or '') ~= ''
            rows[#rows + 1] = {
                name, GetResourceState(name), GetResourceMetadata(name, 'version', 0) or '', GetResourceMetadata(name, 'author', 0) or '',
                isMap and 1 or 0, metaCount(name, 'data_file'), metaCount(name, 'client_script', 'client_scripts'),
                metaCount(name, 'server_script', 'server_scripts'), metaCount(name, 'file', 'files'),
            }
        end
    end
    push({ type = 'db_snapshot', data = { name = '_resources', label = 'Ressources', kind = 'internal',
        columns = { 'ressource', 'etat', 'version', 'auteur', 'carte', 'data_files', 'scripts_client', 'scripts_serveur', 'fichiers' }, rows = rows } })
end

CreateThread(function()
    Wait(15000) -- laisse qbx_core/oxmysql demarrer
    push({ type = 'event', subtype = 'server_start', data = {} })
    snapshotEconomy()
    snapshotVehicles()
    snapshotResources()
    local lastVehicles = os.time()
    while true do
        Wait(SNAPSHOT_INTERVAL_S * 1000)
        snapshotEconomy()
        snapshotPlayers()
        snapshotResources()
        if os.time() - lastVehicles >= VEHICLE_INTERVAL_S then
            lastVehicles = os.time()
            snapshotVehicles()
        end
    end
end)

--------------------------------------------------------------------------------
-- Ordres envoyes depuis le panel (annonces) : releves sur l'API puis executes ici.
--------------------------------------------------------------------------------

local function announce(p)
    local title = tostring(p.title or 'Annonce')
    local message = tostring(p.message or '')
    if message == '' then return false, 'message vide' end
    local mode = p.mode or 'both'
    local hasLib = GetResourceState('ox_lib') == 'started'
    if mode == 'notify' and not hasLib then mode = 'chat' end
    if mode == 'chat' or mode == 'both' then
        TriggerClientEvent('chat:addMessage', -1, { color = { 255, 138, 31 }, multiline = true, args = { title, message } })
    end
    if (mode == 'notify' or mode == 'both') and hasLib then
        TriggerClientEvent('ox_lib:notify', -1, {
            title = title, description = message, type = p.type or 'inform', position = 'top',
            duration = math.min(tonumber(p.duration) or 10000, 60000),
        })
    end
    return true, ('envoyee a %d joueur(s)'):format(#GetPlayers())
end

local HANDLERS = { announce = announce }

-- Execute les ordres recus dans la reponse de /v1/batch ; le resultat repart avec l'envoi suivant.
runCommands = function(resp)
    local ok, data = pcall(json.decode, resp)
    if not ok or type(data) ~= 'table' or type(data.commands) ~= 'table' then return end
    for _, c in ipairs(data.commands) do
        local handler = HANDLERS[c.type]
        local res, detail
        if handler then
            local okRun, r1, r2 = pcall(handler, c.payload or {})
            res, detail = okRun and r1 == true, okRun and r2 or tostring(r1)
        else
            res, detail = false, 'ordre inconnu : ' .. tostring(c.type)
        end
        pendingAcks[#pendingAcks + 1] = { id = c.id, ok = res, result = detail }
    end
end

print(('^2[bl_telemetry] actif -> %s (lots: %dms, annonces: %s)^0'):format(URL, FLUSH_INTERVAL_MS, COMMANDS_ENABLED and 'oui' or 'non'))
