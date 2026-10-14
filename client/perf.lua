--[[
    bl_telemetry/client/perf — mesure tres legere des performances cote joueur.
    Toutes les 20 s : FPS sur 1 s, pire image (saccade), position, interieur (MLO) et nombre
    d'entites chargees autour du joueur. Envoye au serveur par paquets de 3 (1 message / min).
    Sert a reperer les zones et les MLO qui font chuter les FPS.
]]

local SAMPLE_EVERY_MS = 20000
local PER_MESSAGE = 3
local samples = {}

-- FPS moyens et pire image sur une fenetre d'une seconde.
local function measure()
    local frames, worst, start = 0, 0.0, GetGameTimer()
    while GetGameTimer() - start < 1000 do
        local ft = GetFrameTime()
        if ft > worst then worst = ft end
        frames = frames + 1
        Wait(0)
    end
    local elapsed = math.max(1, GetGameTimer() - start) / 1000
    return frames / elapsed, worst * 1000
end

local function interiorInfo(ped)
    local interior = GetInteriorFromEntity(ped)
    if not interior or interior == 0 then return nil end
    local a, b = GetInteriorLocationAndNamehash(interior)
    local pos, hash
    if type(a) == 'vector3' then pos, hash = a, b else hash = a end
    return hash, pos
end

CreateThread(function()
    Wait(60000) -- laisse le joueur charger
    while true do
        Wait(SAMPLE_EVERY_MS)
        local ped = PlayerPedId()
        if IsScreenFadedIn() and not IsPauseMenuActive() and not IsPlayerSwitchInProgress() and ped ~= 0 then
            local fps, worstMs = measure()
            local c = GetEntityCoords(ped)
            local ihash, ipos = interiorInfo(ped)
            samples[#samples + 1] = {
                fps = math.floor(fps * 10 + 0.5) / 10,
                worst = math.floor(worstMs + 0.5),
                x = math.floor(c.x), y = math.floor(c.y), z = math.floor(c.z),
                int = ihash,
                ix = ipos and math.floor(ipos.x) or nil, iy = ipos and math.floor(ipos.y) or nil, iz = ipos and math.floor(ipos.z) or nil,
                obj = #GetGamePool('CObject'), peds = #GetGamePool('CPed'), veh = #GetGamePool('CVehicle'),
                inveh = GetVehiclePedIsIn(ped, false) ~= 0,
            }
            if #samples >= PER_MESSAGE then
                TriggerServerEvent('bl_telemetry:perf', samples)
                samples = {}
            end
        end
    end
end)
