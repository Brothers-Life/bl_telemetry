--[[
    bl_telemetry/perf — de quoi savoir quoi optimiser :
      1. FPS des joueurs (client/perf.lua) regroupes toutes les 5 min par zone (250 m), par interieur (MLO)
         et par joueur, avec la repartition des FPS et le ping ;
      2. entites existantes sur le serveur (vehicules, peds, objets) et modeles les plus nombreux ;
      3. cout de chaque ressource serveur, mesure avec le profiler FiveM (echantillon court toutes les 30 min).
    Un seul event agrege par fenetre : tres peu de donnees envoyees.
    Convars : telemetry_perf_s (300, 0 = off), telemetry_profiler_min (30, 0 = off), telemetry_profiler_frames (300).
    Le profiler demande : add_ace resource.bl_telemetry command.profiler allow
]]

local push = TelemetryPush
local WINDOW_S = GetConvarInt('telemetry_perf_s', 300)
local PROFILER_MIN = GetConvarInt('telemetry_profiler_min', 30)
local PROFILER_FRAMES = GetConvarInt('telemetry_profiler_frames', 300)
local CELL = 250

if not push then return end

--------------------------------------------------------------------------------
-- 1. FPS des joueurs
--------------------------------------------------------------------------------

local function newWindow()
    return { start = os.time(), global = { n = 0, fps = 0, worst = 0, min = 999, hist = { 0, 0, 0, 0, 0 } }, zones = {}, interiors = {}, players = {} }
end
local W = newWindow()
local lastPerf = {}

local function bin(fps)
    if fps < 20 then return 1 elseif fps < 30 then return 2 elseif fps < 45 then return 3 elseif fps < 60 then return 4 end
    return 5
end

local function add(bucket, s)
    bucket.n = bucket.n + 1
    bucket.fps = bucket.fps + s.fps
    bucket.worst = (bucket.worst or 0) + s.worst
    if s.fps < bucket.min then bucket.min = s.fps end
    bucket.obj = (bucket.obj or 0) + s.obj
    bucket.peds = (bucket.peds or 0) + s.peds
    bucket.veh = (bucket.veh or 0) + s.veh
end

local function num(v, lo, hi)
    v = tonumber(v)
    if not v or v ~= v or v < lo or v > hi then return nil end
    return v
end

RegisterNetEvent('bl_telemetry:perf', function(list)
    local src = source
    local t = GetGameTimer()
    if lastPerf[src] and t - lastPerf[src] < 45000 then return end -- 1 message / 45 s max par joueur
    lastPerf[src] = t
    if type(list) ~= 'table' then return end
    local cid, name
    local ok, player = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    if ok and player and player.PlayerData then
        local ci = player.PlayerData.charinfo or {}
        cid, name = player.PlayerData.citizenid, ('%s %s'):format(ci.firstname or '?', ci.lastname or '?')
    end
    local key = cid or ('src' .. src)
    for i = 1, math.min(#list, 5) do
        local r = list[i]
        local s = type(r) == 'table' and {
            fps = num(r.fps, 1, 1000), worst = num(r.worst, 0, 60000) or 0,
            x = num(r.x, -20000, 20000), y = num(r.y, -20000, 20000), z = num(r.z, -2000, 5000) or 0,
            obj = num(r.obj, 0, 100000) or 0, peds = num(r.peds, 0, 10000) or 0, veh = num(r.veh, 0, 10000) or 0,
        }
        if s and s.fps and s.x and s.y then
            local g = W.global
            add(g, s)
            g.hist[bin(s.fps)] = g.hist[bin(s.fps)] + 1

            local zk = math.floor(s.x / CELL) .. ':' .. math.floor(s.y / CELL)
            local z = W.zones[zk] or { n = 0, fps = 0, min = 999, x = 0, y = 0 }
            add(z, s); z.x = z.x + s.x; z.y = z.y + s.y
            W.zones[zk] = z

            local ih = num(r.int, -4294967296, 4294967296)
            if ih and ih ~= 0 then
                local ik = tostring(math.floor(ih))
                local it = W.interiors[ik] or { n = 0, fps = 0, min = 999, players = {}, x = num(r.ix, -20000, 20000) or s.x, y = num(r.iy, -20000, 20000) or s.y, z = num(r.iz, -2000, 5000) or s.z }
                add(it, s); it.players[key] = true
                W.interiors[ik] = it
            end

            local p = W.players[key] or { n = 0, fps = 0, min = 999, cid = cid, name = name or GetPlayerName(src) }
            add(p, s); p.ping = GetPlayerPing(src)
            W.players[key] = p
        end
    end
end)

AddEventHandler('playerDropped', function() lastPerf[source] = nil end)

local function round(v, d) local m = 10 ^ (d or 0); return math.floor(v * m + 0.5) / m end
local function summary(b)
    return {
        n = b.n, fps = round(b.fps / b.n, 1), min = round(b.min, 1), worst = round((b.worst or 0) / b.n),
        obj = round((b.obj or 0) / b.n), peds = round((b.peds or 0) / b.n), veh = round((b.veh or 0) / b.n),
    }
end
local function top(map, limit, build)
    local arr = {}
    for k, b in pairs(map) do if b.n > 0 then arr[#arr + 1] = build(k, b) end end
    table.sort(arr, function(a, b) return a.fps < b.fps end) -- les pires d'abord
    while #arr > limit do arr[#arr] = nil end
    return arr
end

--------------------------------------------------------------------------------
-- 2. Entites du serveur
--------------------------------------------------------------------------------

local function entityStats()
    local out = {}
    for kind, getter in pairs({ vehicles = GetAllVehicles, peds = GetAllPeds, objects = GetAllObjects }) do
        local ok, list = pcall(getter)
        if ok and type(list) == 'table' then
            local models, n = {}, #list
            for i = 1, n do
                local m = GetEntityModel(list[i])
                models[m] = (models[m] or 0) + 1
            end
            local arr = {}
            for m, c in pairs(models) do arr[#arr + 1] = { model = m, n = c } end
            table.sort(arr, function(a, b) return a.n > b.n end)
            while #arr > 10 do arr[#arr] = nil end
            out[kind] = { total = n, top = arr }
        end
    end
    return out
end

CreateThread(function()
    if WINDOW_S <= 0 then return end
    while true do
        Wait(WINDOW_S * 1000)
        local w = W
        W = newWindow()
        local data = { window_s = os.time() - w.start, players_online = #GetPlayers(), entities = entityStats() }
        if w.global.n > 0 then
            data.global = summary(w.global)
            data.global.hist = w.global.hist
            data.zones = top(w.zones, 150, function(k, b) local s = summary(b); s.key = k; s.x = round(b.x / b.n); s.y = round(b.y / b.n); return s end)
            data.interiors = top(w.interiors, 150, function(k, b)
                local s = summary(b); s.key = k; s.x, s.y, s.z = b.x, b.y, b.z
                local n = 0; for _ in pairs(b.players) do n = n + 1 end
                s.players = n
                return s
            end)
            data.players = top(w.players, 300, function(_, b) local s = summary(b); s.cid = b.cid; s.name = b.name; s.ping = b.ping; return s end)
        end
        push({ type = 'perf_snapshot', data = data })
    end
end)

--------------------------------------------------------------------------------
-- 3. Profiler FiveM : cout de chaque ressource serveur
--------------------------------------------------------------------------------

-- Attribue chaque evenement de la trace a une ressource connue (en cherchant son nom dans le libelle).
local function parseProfile(text, resources)
    local ok, trace = pcall(json.decode, text)
    if not ok or type(trace) ~= 'table' then return nil end
    local events = trace.traceEvents or trace
    if type(events) ~= 'table' then return nil end
    local perRes, perName, tMin, tMax, total = {}, {}, nil, nil, 0
    for _, ev in ipairs(events) do
        local dur = tonumber(ev.dur)
        local ts = tonumber(ev.ts)
        if ts then tMin = tMin and math.min(tMin, ts) or ts; tMax = tMax and math.max(tMax, ts + (dur or 0)) or ts end
        if dur and dur > 0 then
            local label = tostring(ev.name or '')
            local res
            for word in (label .. ' ' .. tostring(ev.cat or '') .. ' ' .. tostring(type(ev.args) == 'table' and (ev.args.resource or ev.args.name) or '')):gmatch('[%w_%-%.]+') do
                if resources[word] then res = word break end
            end
            res = res or '(non attribué)'
            local r = perRes[res] or { ms = 0, n = 0 }
            r.ms = r.ms + dur / 1000; r.n = r.n + 1
            perRes[res] = r
            local key = label:sub(1, 80)
            local e = perName[key] or { ms = 0, n = 0, res = res }
            e.ms = e.ms + dur / 1000; e.n = e.n + 1
            perName[key] = e
            total = total + dur / 1000
        end
    end
    local spanMs = (tMin and tMax) and (tMax - tMin) / 1000 or 0
    local resArr, nameArr = {}, {}
    for name, r in pairs(perRes) do resArr[#resArr + 1] = { name = name, ms = round(r.ms, 2), n = r.n } end
    for name, e in pairs(perName) do nameArr[#nameArr + 1] = { name = name, res = e.res, ms = round(e.ms, 2), n = e.n } end
    table.sort(resArr, function(a, b) return a.ms > b.ms end)
    table.sort(nameArr, function(a, b) return a.ms > b.ms end)
    while #resArr > 60 do resArr[#resArr] = nil end
    while #nameArr > 40 do nameArr[#nameArr] = nil end
    return { span_ms = round(spanMs), total_ms = round(total, 1), events = #events, resources = resArr, top = nameArr }
end

local function knownResources()
    local set = {}
    for i = 0, GetNumResources() - 1 do
        local n = GetResourceByFindIndex(i)
        if n then set[n] = true end
    end
    return set
end

CreateThread(function()
    if PROFILER_MIN <= 0 then return end
    local path = GetResourcePath(GetCurrentResourceName()) .. '/profile.json'
    local warned = false
    Wait(5 * 60000) -- pas pendant le demarrage
    while true do
        os.remove(path)
        ExecuteCommand(('profiler record %d'):format(PROFILER_FRAMES))
        Wait(math.max(10000, PROFILER_FRAMES * 60)) -- ~ duree d'enregistrement
        ExecuteCommand(('profiler saveJSON "%s"'):format(path))
        Wait(5000)
        local f = io.open(path, 'r')
        if f then
            local text = f:read('a')
            f:close()
            os.remove(path)
            local result = parseProfile(text, knownResources())
            if result then
                result.frames = PROFILER_FRAMES
                push({ type = 'profiler_snapshot', data = result })
            end
        elseif not warned then
            warned = true
            print('^3[bl_telemetry] profiler indisponible : ajoute "add_ace resource.bl_telemetry command.profiler allow" dans server.cfg (ou telemetry_profiler_min 0)^0')
        end
        Wait(PROFILER_MIN * 60000)
    end
end)
