--[[
    update.lua — mise a jour automatique de bl_telemetry depuis GitHub.

    Une seule verification, au demarrage de la ressource (redemarrage du serveur ou restart bl_telemetry) :
    un fichier de quelques octets (fxmanifest.lua) est lu sur la branche suivie du depot. Si sa version est plus
    recente que celle installee : telecharge tous les fichiers de la ressource (rien n'est ecrit si un seul
    telechargement echoue), les remplace, puis redemarre la ressource. Aucun travail ensuite.

    Convars :
        set telemetry_autoupdate 1                          -- 0 = jamais de mise a jour automatique
        set telemetry_update_repo "Brothers-Life/bl_telemetry"
        set telemetry_update_branch "main"
        set telemetry_update_keep ""                         -- fichiers a ne pas remplacer, separes par des virgules
                                                             -- (ex. "server/dbsync_queries.lua" si tu l'as modifie)
    Pour que la ressource se redemarre seule apres une mise a jour (sinon : message dans la console) :
        add_ace resource.bl_telemetry command.refresh allow
        add_ace resource.bl_telemetry command.restart allow
]]

local RESOURCE = GetCurrentResourceName()
local ENABLED  = GetConvarInt('telemetry_autoupdate', 1) == 1
local REPO     = GetConvar('telemetry_update_repo', 'Brothers-Life/bl_telemetry')
local BRANCH   = GetConvar('telemetry_update_branch', 'main')

if not ENABLED then return end
if not REPO:match('^[%w%-_.]+/[%w%-_.]+$') or not BRANCH:match('^[%w%-_./]+$') then
    print('^1[bl_telemetry:update] telemetry_update_repo / telemetry_update_branch invalides, mise a jour desactivee^0')
    return
end

-- Seuls ces fichiers de la ressource sont mis a jour (jamais un chemin qui sort de la ressource)
local ALLOWED_EXT = { lua = true, md = true, json = true, txt = true }
local HEADERS = { ['User-Agent'] = 'bl_telemetry-updater', ['Accept'] = 'application/vnd.github+json' }

local function log(msg, ...) print(('^5[bl_telemetry:update]^0 ' .. msg):format(...)) end
local function warn(msg, ...) print(('^3[bl_telemetry:update] ' .. msg .. '^0'):format(...)) end

local keep = {}
for path in GetConvar('telemetry_update_keep', ''):gmatch('[^,%s]+') do keep[path] = true end

local function get(url)
    local p = promise.new()
    PerformHttpRequest(url, function(status, body) p:resolve({ status = status, body = body }) end, 'GET', '', HEADERS)
    local r = Citizen.Await(p)
    if r.status ~= 200 or not r.body then return nil, 'HTTP ' .. tostring(r.status) end
    return r.body
end

-- "1.10.2" -> { 1, 10, 2 } ; vrai si a est plus recent que b
local function newer(a, b)
    local function parts(v)
        local out = {}
        for n in tostring(v or ''):gmatch('%d+') do out[#out + 1] = tonumber(n) end
        return out
    end
    local x, y = parts(a), parts(b)
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p > q end
    end
    return false
end

local function safePath(path)
    if path:find('%.%.') or path:find('^/') or path:find('\\') or path:find('[^%w%-_./]') then return false end
    local ext = path:match('%.(%w+)$')
    return ext ~= nil and ALLOWED_EXT[ext:lower()] == true
end

local function check()
    local installed = GetResourceMetadata(RESOURCE, 'version', 0) or '0'
    local raw = ('https://raw.githubusercontent.com/%s/%s/'):format(REPO, BRANCH)
    local manifest, err = get(raw .. 'fxmanifest.lua')
    if not manifest then return warn('version distante illisible (%s)', err) end
    local remote = manifest:match("\nversion%s+'([^']+)'") or manifest:match('\nversion%s+"([^"]+)"')
    if not remote then return warn('pas de version dans le fxmanifest distant') end
    if not newer(remote, installed) then return end
    log('nouvelle version %s (installee : %s), telechargement…', remote, installed)

    -- Liste des fichiers du depot a ce commit
    local commitBody, e1 = get(('https://api.github.com/repos/%s/commits/%s'):format(REPO, BRANCH))
    if not commitBody then return warn('commit distant illisible (%s)', e1) end
    local commit = json.decode(commitBody)
    local sha = commit and commit.sha
    if type(sha) ~= 'string' or not sha:match('^%x+$') then return warn('commit distant illisible') end
    local treeBody, e2 = get(('https://api.github.com/repos/%s/git/trees/%s?recursive=1'):format(REPO, sha))
    if not treeBody then return warn('liste des fichiers illisible (%s)', e2) end
    local tree = json.decode(treeBody)
    if type(tree) ~= 'table' or type(tree.tree) ~= 'table' or tree.truncated then return warn('liste des fichiers illisible') end

    -- Tout est telecharge avant d'ecrire quoi que ce soit (au commit exact : pas de melange de versions)
    local files = {}
    for _, item in ipairs(tree.tree) do
        if item.type == 'blob' and type(item.path) == 'string' and safePath(item.path) and not keep[item.path] then
            local body, e3 = get(('https://raw.githubusercontent.com/%s/%s/%s'):format(REPO, sha, item.path))
            if not body then return warn('%s : telechargement impossible (%s), mise a jour annulee', item.path, e3) end
            files[#files + 1] = { path = item.path, body = body }
        end
    end
    local hasManifest = false
    for _, f in ipairs(files) do if f.path == 'fxmanifest.lua' then hasManifest = true end end
    if not hasManifest or #files < 2 then return warn('depot incomplet, mise a jour annulee') end

    for _, f in ipairs(files) do
        if not SaveResourceFile(RESOURCE, f.path, f.body, -1) then
            return warn('%s : ecriture impossible (dossier manquant ?), mise a jour incomplete : relance la ressource a la main', f.path)
        end
    end
    log('version %s installee (%d fichiers)', remote, #files)

    if IsPrincipalAceAllowed('resource.' .. RESOURCE, 'command.restart') and IsPrincipalAceAllowed('resource.' .. RESOURCE, 'command.refresh') then
        log('redemarrage de la ressource…')
        -- Laisse partir les derniers envois avant de couper
        Wait(5000)
        ExecuteCommand('refresh')
        ExecuteCommand('restart ' .. RESOURCE)
    else
        warn('redemarre la ressource pour appliquer la mise a jour (restart %s), ou autorise-la a le faire seule : add_ace resource.%s command.restart allow et command.refresh allow', RESOURCE, RESOURCE)
    end
    return true
end

-- Une fois, au demarrage de la ressource ; rien ne tourne ensuite
CreateThread(function()
    Wait(5000)
    local ok, err = pcall(check)
    if not ok then warn('verification impossible : %s', tostring(err)) end
end)
