--[[
    bl_telemetry/dbsync — lit la base MySQL du jeu pour enrichir le panel :
      - taille et nombre de lignes de chaque table (information_schema)
      - les requetes de dbsync_queries.lua (fortunes, objets, vehicules, bans...)
    Resultats envoyes en events 'db_snapshot' ; l'API garde la derniere version de chacun.
    Convar : telemetry_db_s (defaut 900 s, 0 = desactive).
]]

local INTERVAL_S = GetConvarInt('telemetry_db_s', 900)
local MAX_ROWS = 500       -- par defaut ; une requete peut fixer son propre max (q.max, 5000 au plus)
local MAX_ROWS_LIMIT = 5000

local pushEvent = TelemetryPush
local disabled = {} -- requetes en erreur (table absente, JSON_TABLE indisponible...) : on ne reessaie pas

-- Valeurs JSON-compatibles uniquement (oxmysql peut renvoyer des types exotiques).
local function clean(v)
    local t = type(v)
    if t == 'number' or t == 'boolean' or v == nil then return v end
    return tostring(v)
end

local function columnsOf(rows)
    -- Ordre des colonnes = ordre du SELECT si oxmysql le respecte, sinon alphabetique.
    local cols, seen = {}, {}
    for k in pairs(rows[1] or {}) do
        if not seen[k] then seen[k] = true; cols[#cols + 1] = k end
    end
    table.sort(cols)
    return cols
end

local function columnsFromSql(sql)
    -- Recupere les alias "AS nom" du premier SELECT pour garder l'ordre voulu.
    local head = sql:match('^%s*SELECT(.-)%sFROM%s') or ''
    local cols = {}
    for alias in head:gmatch('[Aa][Ss]%s+([%w_]+)%s*[,\n]') do cols[#cols + 1] = alias end
    local last = head:match('[Aa][Ss]%s+([%w_]+)%s*$')
    if last then cols[#cols + 1] = last end
    local out, seen = {}, {}
    for _, c in ipairs(cols) do
        if not seen[c] then seen[c] = true; out[#out + 1] = c end
    end
    return out
end

local function runQuery(q, pos)
    if disabled[q.name] then return end
    local ok, rows = pcall(MySQL.query.await, q.sql)
    if not ok or type(rows) ~= 'table' then
        disabled[q.name] = true
        print(('^3[bl_telemetry] dbsync : requete "%s" ignoree (%s)^0'):format(q.name, tostring(rows):sub(1, 160)))
        return
    end
    local cols = columnsFromSql(q.sql)
    if #cols == 0 or (rows[1] and rows[1][cols[1]] == nil) then cols = columnsOf(rows) end
    local out = {}
    local max = math.min(tonumber(q.max) or MAX_ROWS, MAX_ROWS_LIMIT)
    for i = 1, math.min(#rows, max) do
        local line = {}
        for j, c in ipairs(cols) do line[j] = clean(rows[i][c]) end
        out[i] = line
    end
    pushEvent({
        type = 'db_snapshot',
        data = { name = q.name, label = q.label or q.name, kind = q.kind or 'table', pos = pos, columns = cols, rows = out },
    })
end

local function tableStats()
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT table_name AS t, COALESCE(table_rows, 0) AS n, COALESCE(data_length, 0) + COALESCE(index_length, 0) AS b
        FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY b DESC
    ]])
    if not ok or type(rows) ~= 'table' then return end
    local out = {}
    for i, r in ipairs(rows) do
        if i > MAX_ROWS_LIMIT then break end
        out[i] = { clean(r.t or r.TABLE_NAME), tonumber(r.n) or 0, tonumber(r.b) or 0 }
    end
    pushEvent({
        type = 'db_snapshot',
        data = { name = '_tables', label = 'Tables de la base', kind = 'tables', columns = { 'table', 'lignes', 'octets' }, rows = out },
    })
end

-- Structure de la base (noms et types des colonnes, aucune donnee) : sert a construire de nouvelles vues.
local function schemaScan()
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT table_name AS t, column_name AS c, data_type AS d
        FROM information_schema.columns WHERE table_schema = DATABASE()
        ORDER BY table_name, ordinal_position
    ]])
    if not ok or type(rows) ~= 'table' then return end
    local byTable, order = {}, {}
    for _, r in ipairs(rows) do
        local t = clean(r.t or r.TABLE_NAME)
        if not byTable[t] then byTable[t] = {}; order[#order + 1] = t end
        local col = byTable[t]
        col[#col + 1] = clean(r.c or r.COLUMN_NAME) .. ':' .. clean(r.d or r.DATA_TYPE)
    end
    local out = {}
    for i, t in ipairs(order) do
        if i > MAX_ROWS_LIMIT then break end
        out[i] = { t, table.concat(byTable[t], ', ') }
    end
    pushEvent({
        type = 'db_snapshot',
        data = { name = '_columns', label = 'Structure de la base', kind = 'internal', columns = { 'table', 'colonnes' }, rows = out },
    })
end

CreateThread(function()
    if INTERVAL_S <= 0 or not pushEvent or type(DBSYNC_QUERIES) ~= 'table' then return end
    Wait(45000) -- apres le demarrage, le backfill et live.lua
    local lastSchema = 0
    while true do
        tableStats()
        if os.time() - lastSchema > 6 * 3600 then lastSchema = os.time(); schemaScan() end
        for i, q in ipairs(DBSYNC_QUERIES) do
            if type(q) == 'table' and q.name and q.sql then
                runQuery(q, i)
                Wait(500) -- on etale la charge sur la base
            end
        end
        Wait(INTERVAL_S * 1000)
    end
end)
