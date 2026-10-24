--[[
    mirror.lua — copie des tables du jeu (mirror_tables.lua) dans la base du panel (POST /v1/mirror).
    Le panel lit ses fiches joueurs, statistiques et logs du jeu dans cette copie : la base MariaDB
    n'a jamais besoin d'etre ouverte a Internet.

    Seul ce qui a change part, table par table, en arriere-plan (jamais dans le tick) :
      - journaux    : les lignes au-dela du dernier id envoye (+ les lignes encore ouvertes, refresh)
      - ON UPDATE   : les lignes modifiees depuis le dernier passage
      - petites     : la table entiere, seulement quand son CHECKSUM change
      - le reste    : une empreinte CRC32 par ligne (gardee en KVP), seules les lignes changees partent
    Les suppressions sont rattrapees par une liste complete des cles, de temps en temps.

    Convars :
        set telemetry_mirror 1          -- 0 = pas de copie
        set telemetry_mirror_s 60       -- un passage sur toutes les tables toutes les N secondes
        set telemetry_mirror_keys_s 900 -- liste complete des cles (suppressions) toutes les N secondes
        set telemetry_mirror_hash_s 180 -- tables sans journal ni ON UPDATE : empreintes relues toutes les N secondes
]]

local URL     = GetConvar('telemetry_url', ''):gsub('/$', '')
local TOKEN   = GetConvar('telemetry_token', '')
local ENABLED = GetConvarInt('telemetry_mirror', 1) == 1
local PASS_S  = math.max(15, GetConvarInt('telemetry_mirror_s', 60))
local KEYS_S  = math.max(60, GetConvarInt('telemetry_mirror_keys_s', 900))
local HASH_S  = math.max(PASS_S, GetConvarInt('telemetry_mirror_hash_s', 180)) -- tables a empreinte : relues toutes les N secondes

if URL == '' or TOKEN == '' or not ENABLED then return end

local PAGE      = 1000     -- lignes lues par requete
local FETCH     = 300      -- lignes changees relues par requete (IN)
local MAX_BODY  = 1500000  -- octets par envoi
local SMALL     = 3000     -- lignes : en dessous, une table modifiee repart entiere
local PAUSE_MS  = 150      -- pause entre deux pages (laisse respirer MariaDB et le serveur)
local HEADERS   = { ['Content-Type'] = 'application/json', ['Authorization'] = 'Bearer ' .. TOKEN }

local NUMERIC = { tinyint = true, smallint = true, mediumint = true, int = true, integer = true, bigint = true }
local SENSITIVE = { 'ip', 'ips', 'token', 'tokens', 'password', 'passwd', 'pass_hash', 'hwid', 'hwids', 'email', 'mail', 'secret' }
local FORBIDDEN = { sky_phone_accounts = true }

local function log(msg, ...) print(('^5[bl_telemetry:mirror]^0 ' .. msg):format(...)) end
local function warn(msg, ...) print(('^3[bl_telemetry:mirror] ' .. msg .. '^0'):format(...)) end

-- Meme regle que le panel : une colonne nommee ip, *_ip, tokens, *_password… ne part jamais
local function sensitive(col)
    local c = col:lower()
    for _, s in ipairs(SENSITIVE) do
        if c == s or c:sub(-(#s + 1)) == '_' .. s then return true end
    end
    return false
end

local function quoteId(name) return '`' .. name:gsub('`', '``') .. '`' end

-- Requete HTTP synchrone (dans un thread) : donnees decodees, ou nil + raison
local function http(method, path, body)
    local p = promise.new()
    PerformHttpRequest(URL .. path, function(status, resp)
        p:resolve({ status = status, body = resp })
    end, method, body or '', HEADERS)
    local r = Citizen.Await(p)
    if r.status ~= 200 then return nil, 'HTTP ' .. tostring(r.status) end
    local ok, data = pcall(json.decode, r.body or '')
    if not ok or type(data) ~= 'table' then return nil, 'reponse illisible' end
    return data
end

local function sql(query, params)
    local ok, rows = pcall(MySQL.query.await, query, params or {})
    if not ok then error(tostring(rows), 0) end
    return rows or {}
end

-- Une valeur JSON, nil -> null (json.encode laisse des trous dans les tableaux)
local function cell(v)
    if v == nil then return 'null' end
    return json.encode(v)
end

-- Cle d'une ligne (cle primaire, plusieurs colonnes possibles) sous forme de texte
local function keyOf(T, row)
    if #T.pk == 1 then return tostring(row[T.pk[1]]) end
    local parts = {}
    for i, k in ipairs(T.pk) do parts[i] = tostring(row[k]) end
    return table.concat(parts, '\31')
end
local function keyValues(T, row)
    local v = {}
    for i, k in ipairs(T.pk) do v[i] = row[k] end
    return v
end

-- ---------------------------------------------------------------------------------------------
-- Envoi : une table, un lot de lignes (deja triees), avec ses metadonnees
-- ---------------------------------------------------------------------------------------------

local function post(T, meta, rowStrings, extraJson)
    meta.name, meta.mode, meta.schemaHash = T.name, T.mode, T.schemaHash
    meta.fields = T.fields
    local withSchema = not T.schemaSent
    if withSchema then meta.schema = T.schema end
    local head = json.encode(meta)
    local body = '{"tables":[' .. head:sub(1, -2) .. ',"rows":[' .. table.concat(rowStrings or {}, ',') .. ']' .. (extraJson or '') .. '}]}'
    local data, err = http('POST', '/v1/mirror', body)
    if not data then return false, err end
    local res = data.tables and data.tables[T.name] or {}
    if res.needSchema and not withSchema then
        T.schemaSent = false
        meta.schema = nil
        return post(T, meta, rowStrings, extraJson)
    end
    if res.ok then
        T.schemaSent = true
        if res.reset then T.fresh = true end
        return true
    end
    if res.reset then
        -- Table recreee cote panel : on oublie ce qui a ete envoye, tout repart au prochain passage
        T.cursor, T.checksum, T.hashes, T.open, T.sent, T.dirty = nil, nil, {}, {}, {}, true
        T.schemaSent = true
        DeleteResourceKvp('blm:' .. T.name)
        return false, 'table recreee par le panel, renvoi complet'
    end
    return false, res.error or 'refusee'
end

-- Encode les lignes et les envoie par paquets de MAX_BODY octets. meta(lastRow) donne les metadonnees de chaque paquet.
-- done(first, last) est appele apres chaque paquet accepte.
-- dedupe : les lignes relues plusieurs fois (recouvrement, lignes ouvertes) ne repartent que si elles ont change.
local function sendRows(T, rows, meta, done, dedupe)
    local batch, size, first = {}, 0, 1
    local pending = {}
    local function flush(last)
        if #batch == 0 then
            if done and last >= first then done(first, last) end
            first = last + 1
            return true
        end
        local ok, err = post(T, meta(rows[last]), batch)
        if not ok then return false, err end
        for k, s in pairs(pending) do T.sent[k] = s end
        if done then done(first, last) end
        batch, size, first, pending = {}, 0, last + 1, {}
        return true
    end
    for i, row in ipairs(rows) do
        local cells = {}
        for j, f in ipairs(T.fields) do cells[j] = cell(row[f]) end
        local s = '[' .. table.concat(cells, ',') .. ']'
        local skip = false
        if dedupe and #T.pk > 0 then
            -- Empreinte de la ligne telle qu'envoyee (32 bits) : peu de memoire, meme pour une grosse table
            local k, h = keyOf(T, row), GetHashKey(s)
            if T.sent[k] == h then skip = true else pending[k] = h end
            T.keepSent[k] = true
        end
        if not skip then
            if size + #s > MAX_BODY and #batch > 0 then
                local ok, err = flush(i - 1)
                if not ok then return false, err end
            end
            batch[#batch + 1] = s
            size = size + #s + 1
        end
    end
    return flush(#rows)
end

-- ---------------------------------------------------------------------------------------------
-- Les modes de copie
-- ---------------------------------------------------------------------------------------------

local function hashExpr(T)
    local parts = {}
    for i, f in ipairs(T.fields) do parts[i] = ('IFNULL(%s, CHAR(0))'):format(quoteId(f)) end
    return 'CRC32(CONCAT_WS(CHAR(31), ' .. table.concat(parts, ', ') .. '))'
end
local function pkList(T)
    local p = {}
    for i, k in ipairs(T.pk) do p[i] = quoteId(k) end
    return table.concat(p, ', ')
end

-- Relit des lignes par leur cle (paquets de FETCH) et les renvoie en une liste
local function fetchByKeys(T, keys)
    local rows = {}
    for i = 1, #keys, FETCH do
        local chunk, params = {}, {}
        for j = i, math.min(i + FETCH - 1, #keys) do
            local values = keys[j]
            local marks = {}
            for n, v in ipairs(values) do
                marks[n] = '?'
                params[#params + 1] = v
            end
            chunk[#chunk + 1] = '(' .. table.concat(marks, ', ') .. ')'
        end
        local where = ('(%s) IN (%s)'):format(pkList(T), table.concat(chunk, ', '))
        for _, r in ipairs(sql(('SELECT %s FROM %s WHERE %s'):format(T.select, quoteId(T.name), where), params)) do rows[#rows + 1] = r end
        Wait(PAUSE_MS)
    end
    return rows
end

-- Lignes dont l'empreinte a change parmi celles qui verifient `where` (toute la table si nil).
-- Met a jour T.hashes pour ces lignes une fois envoyees ; retourne aussi les cles vues.
local function syncByHash(T, where, whereParams)
    local seen, changed = {}, {}
    local single = #T.pk == 1 and NUMERIC[T.types[T.pk[1]]]
    local last, offset = nil, 0
    while true do
        local cond, params = {}, {}
        if where then cond[#cond + 1] = '(' .. where .. ')'; for _, p in ipairs(whereParams or {}) do params[#params + 1] = p end end
        if single and last ~= nil then cond[#cond + 1] = quoteId(T.pk[1]) .. ' > ?'; params[#params + 1] = last end
        local q = ('SELECT %s, %s AS __h FROM %s %s ORDER BY %s LIMIT %d%s'):format(pkList(T), hashExpr(T), quoteId(T.name),
            #cond > 0 and ('WHERE ' .. table.concat(cond, ' AND ')) or '', pkList(T), PAGE, single and '' or (' OFFSET ' .. offset))
        local rows = sql(q, params)
        for _, r in ipairs(rows) do
            local k = keyOf(T, r)
            seen[k] = true
            if T.hashes[k] ~= r.__h then changed[#changed + 1] = { key = k, values = keyValues(T, r), hash = r.__h } end
        end
        if #rows < PAGE then break end
        last = rows[#rows][T.pk[1]]
        offset = offset + PAGE
        Wait(PAUSE_MS)
    end
    if #changed > 0 then
        local keys = {}
        for i, c in ipairs(changed) do keys[i] = c.values end
        local rows = fetchByKeys(T, keys)
        local hashOf = {}
        for _, c in ipairs(changed) do hashOf[c.key] = c.hash end
        -- Premier passage (rien d'envoye encore) : from absent, le panel accepte une table toute neuve
        local meta = function()
            if T.fresh then return {} end
            return { from = 'h' }
        end
        local ok, err = sendRows(T, rows, meta, function(first, lastIndex)
            for i = first, lastIndex do
                local k = keyOf(T, rows[i])
                T.hashes[k] = hashOf[k]
            end
            T.dirty = true
        end)
        if not ok then return nil, err end
    end
    return seen
end

local function sendKeep(T, keys)
    local list = {}
    for i, v in ipairs(keys) do list[i] = json.encode(v) end
    return post(T, { from = 'k' }, {}, ',"keep":[' .. table.concat(list, ',') .. ']')
end

-- Journal : les nouvelles lignes, dans l'ordre de la cle
local function passAppend(T)
    local key = T.pk[1]
    local strict = #T.pk == 1
    while true do
        local cond = T.cursor and ('WHERE %s %s ?'):format(quoteId(key), strict and '>' or '>=') or ''
        local rows = sql(('SELECT %s FROM %s %s ORDER BY %s LIMIT %d'):format(T.select, quoteId(T.name), cond, strict and quoteId(key) or pkList(T), PAGE),
            T.cursor and { tonumber(T.cursor) } or {})
        if #rows == 0 then break end
        local from = T.cursor
        local ok, err = sendRows(T, rows, function(lastRow) return { from = from, cursor = tostring(lastRow[key]) } end, function(_, lastIndex)
            T.cursor = tostring(rows[lastIndex][key])
        end, not strict)
        if not ok then return false, err end
        if #rows < PAGE then break end
        -- >= sur une cle a plusieurs colonnes : une page entiere sur la meme valeur, on avance quand meme
        if not strict and tostring(rows[1][key]) == T.cursor then T.cursor = tostring(tonumber(T.cursor) + 1) end
        Wait(PAUSE_MS)
    end
    -- Lignes encore ouvertes (sessions en cours…) et celles qui viennent de se fermer : relues si elles ont change
    if T.conf.refresh then
        local open = {}
        for _, r in ipairs(sql(('SELECT %s FROM %s WHERE %s'):format(pkList(T), quoteId(T.name), T.conf.refresh))) do open[keyOf(T, r)] = keyValues(T, r) end
        local keys = {}
        for k, v in pairs(open) do keys[#keys + 1] = v end
        for k, v in pairs(T.open) do if not open[k] then keys[#keys + 1] = v end end
        if #keys > 0 then
            local rows = fetchByKeys(T, keys)
            local ok, err = sendRows(T, rows, function() return { from = T.cursor } end, nil, true)
            if not ok then return false, err end
        end
        T.open = open
    end
    return true
end

-- Colonne ON UPDATE : les lignes modifiees depuis le dernier passage (curseur "secondes:cle")
local function passUpdated(T)
    local col, key = quoteId(T.updatedColumn), quoteId(T.pk[1])
    local first = true
    while true do
        local s, k = nil, nil
        if T.cursor then s, k = T.cursor:match('^(%-?%d+):(.*)$') end
        local cond, params = '', {}
        if s and first then
            -- Debut de passage : 2 s de recouvrement (une ligne modifiee dans la seconde du curseur, avec une cle
            -- plus petite, serait sinon perdue ; la renvoyer ne change rien cote panel)
            cond = ('WHERE UNIX_TIMESTAMP(%s) >= ?'):format(col)
            params = { tonumber(s) - 2 }
        elseif s then
            cond = ('WHERE UNIX_TIMESTAMP(%s) > ? OR (UNIX_TIMESTAMP(%s) = ? AND %s > ?)'):format(col, col, key)
            params = { tonumber(s), tonumber(s), NUMERIC[T.types[T.pk[1]]] and tonumber(k) or k }
        end
        first = false
        local rows = sql(('SELECT UNIX_TIMESTAMP(%s) AS __u, %s FROM %s %s ORDER BY %s, %s LIMIT %d'):format(col, T.select, quoteId(T.name), cond, col, key, PAGE), params)
        if #rows == 0 then break end
        local from = T.cursor
        local cursorOf = function(r) return ('%d:%s'):format(math.floor(tonumber(r.__u) or 0), tostring(r[T.pk[1]])) end
        local ok, err = sendRows(T, rows, function(lastRow) return { from = from, cursor = cursorOf(lastRow) } end, function(_, lastIndex)
            T.cursor = cursorOf(rows[lastIndex])
        end, true)
        if not ok then return false, err end
        if #rows < PAGE then break end
        Wait(PAUSE_MS)
    end
    return true
end

-- Petite table : CHECKSUM, puis toute la table si elle a change
local function passReplace(T)
    local res = sql('CHECKSUM TABLE ' .. quoteId(T.name))
    local checksum = res[1] and tostring(res[1].Checksum or res[1].checksum) or nil
    if checksum and checksum ~= 'nil' and checksum == T.checksum then return true end
    local rows = sql(('SELECT %s FROM %s LIMIT %d'):format(T.select, quoteId(T.name), SMALL * 2))
    if #rows >= SMALL * 2 then
        -- Plus si petite : passe a l'empreinte par ligne
        if #T.pk == 0 then warn('%s : trop grande et sans cle primaire, ignoree', T.name); T.skip = true; return true end
        T.mode = 'hash'
        return true
    end
    local cells = {}
    for i, row in ipairs(rows) do
        local c = {}
        for j, f in ipairs(T.fields) do c[j] = cell(row[f]) end
        cells[i] = '[' .. table.concat(c, ',') .. ']'
    end
    local ok, err = post(T, { replace = true, checksum = checksum }, cells)
    if not ok then return false, err end
    T.checksum = checksum
    return true
end

local function passHash(T)
    local seen, err = syncByHash(T)
    if not seen then return false, err end
    -- Suppressions : les cles connues qui n'existent plus
    local gone = {}
    for k in pairs(T.hashes) do if not seen[k] then gone[#gone + 1] = k end end
    if #gone > 0 then
        local keys = {}
        for i, k in ipairs(gone) do
            local parts = {}
            for p in (k .. '\31'):gmatch('(.-)\31') do parts[#parts + 1] = p end
            keys[i] = #T.pk == 1 and parts[1] or parts
        end
        local list = {}
        for i, v in ipairs(keys) do list[i] = json.encode(type(v) == 'table' and v or { v }) end
        local ok, e = post(T, { from = 'h' }, {}, ',"deletes":[' .. table.concat(list, ',') .. ']')
        if not ok then return false, e end
        for _, k in ipairs(gone) do T.hashes[k] = nil end
        T.dirty = true
    end
    T.fresh = false
    return true
end

-- Liste complete des cles (rattrape les suppressions) pour les modes journal et ON UPDATE
local function passKeys(T)
    local keys = {}
    for _, r in ipairs(sql(('SELECT %s FROM %s'):format(pkList(T), quoteId(T.name)))) do keys[#keys + 1] = keyValues(T, r) end
    return sendKeep(T, keys)
end

-- ---------------------------------------------------------------------------------------------
-- Demarrage : colonnes des tables, etat du panel, choix du mode
-- ---------------------------------------------------------------------------------------------

local tables = {}

local function setup()
    local names, conf = {}, {}
    for _, t in ipairs(MirrorTables or {}) do
        if not FORBIDDEN[t.name] then names[#names + 1] = t.name; conf[t.name] = t end
    end
    local counted = {}
    for _, n in ipairs(MirrorCounted or {}) do counted[n] = true; names[#names + 1] = n end

    local cols = sql([[SELECT TABLE_NAME AS t, COLUMN_NAME AS c, DATA_TYPE AS dt, COLUMN_TYPE AS ct, EXTRA AS extra
        FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN (?) ORDER BY TABLE_NAME, ORDINAL_POSITION]], { names })
    local pks = sql([[SELECT TABLE_NAME AS t, COLUMN_NAME AS c FROM information_schema.KEY_COLUMN_USAGE
        WHERE TABLE_SCHEMA = DATABASE() AND CONSTRAINT_NAME = 'PRIMARY' AND TABLE_NAME IN (?) ORDER BY TABLE_NAME, ORDINAL_POSITION]], { names })
    local sizes = sql([[SELECT TABLE_NAME AS t, TABLE_ROWS AS n FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN (?)]], { names })

    local state, err = http('GET', '/v1/mirror/state')
    if not state then return false, err end
    state = state.tables or {}

    local byName = {}
    for _, c in ipairs(cols) do byName[c.t] = byName[c.t] or {}; table.insert(byName[c.t], c) end
    local pkOf = {}
    for _, p in ipairs(pks) do pkOf[p.t] = pkOf[p.t] or {}; table.insert(pkOf[p.t], p.c) end
    local rowsOf = {}
    for _, s in ipairs(sizes) do rowsOf[s.t] = tonumber(s.n) or 0 end

    tables = {}
    for _, name in ipairs(names) do
        local columns = byName[name]
        if columns and counted[name] then
            tables[#tables + 1] = { name = name, mode = 'count' }
        elseif columns then
            local c = conf[name]
            local wanted
            if c.columns then wanted = {}; for _, w in ipairs(c.columns) do wanted[w] = true end end
            local pk = pkOf[name] or {}
            local isPk = {}
            for _, k in ipairs(pk) do isPk[k] = true end
            local T = { name = name, conf = c, pk = pk, fields = {}, types = {}, schema = { pk = pk, columns = {} }, hashes = {}, open = {}, sent = {}, keepSent = {} }
            local sig = { name }
            for _, col in ipairs(columns) do
                local dt = tostring(col.dt):lower()
                local keep = isPk[col.c] or ((not wanted or wanted[col.c]) and not sensitive(col.c) and not dt:find('blob') and not dt:find('binary'))
                if keep then
                    T.fields[#T.fields + 1] = col.c
                    T.types[col.c] = dt
                    table.insert(T.schema.columns, { name = col.c, type = dt, columnType = col.ct })
                    sig[#sig + 1] = col.c .. ':' .. tostring(col.ct)
                    if not T.updatedColumn and tostring(col.extra):lower():find('on update') then T.updatedColumn = col.c end
                end
            end
            local selectParts = {}
            for i, f in ipairs(T.fields) do selectParts[i] = quoteId(f) end
            T.select = table.concat(selectParts, ', ')
            sig[#sig + 1] = 'pk=' .. table.concat(pk, ',')
            T.schemaHash = tostring(GetHashKey(table.concat(sig, '|')))

            if c.log and #pk >= 1 and NUMERIC[T.types[pk[1]]] then T.mode = 'append'
            elseif T.updatedColumn and #pk == 1 then T.mode = 'updated'
            elseif (rowsOf[name] or 0) < SMALL then T.mode = 'replace'
            elseif #pk > 0 then T.mode = 'hash'
            else T.skip = true; warn('%s : pas de cle primaire et trop grande, ignoree', name) end

            -- Ou en est le panel pour cette table (meme colonnes et meme mode, sinon tout repart)
            local s = state[name]
            if s and s.schemaHash == T.schemaHash and s.mode == T.mode then
                T.schemaSent = true
                T.cursor = s.cursor
                T.checksum = s.checksum
                if T.mode == 'hash' and (s.rows or 0) > 0 then
                    local saved = GetResourceKvpString('blm:' .. name)
                    local ok, map = pcall(json.decode, saved or '')
                    if ok and type(map) == 'table' then T.hashes = map end
                end
            end
            if T.mode == 'hash' and not next(T.hashes) then T.fresh = true end
            if not T.schemaSent then DeleteResourceKvp('blm:' .. name) end
            T.keysAt = GetGameTimer() + math.random(0, KEYS_S * 1000)
            tables[#tables + 1] = T
        end
    end
    local copied, counts = 0, 0
    for _, T in ipairs(tables) do if T.mode == 'count' then counts = counts + 1 elseif not T.skip then copied = copied + 1 end end
    log('%d table(s) copiee(s), %d comptee(s)', copied, counts)
    return true
end

local function runTable(T)
    if T.skip or GetGameTimer() < (T.nextAt or 0) then return true end
    if T.mode == 'count' then
        T.nextAt = GetGameTimer() + KEYS_S * 1000
        local r = sql(('SELECT COUNT(*) AS n FROM %s'):format(quoteId(T.name)))
        local data, err = http('POST', '/v1/mirror', json.encode({ tables = { { name = T.name, mode = 'count', count = r[1] and r[1].n or 0 } } }))
        return data ~= nil, err
    end
    local ok, err
    if T.mode == 'append' then ok, err = passAppend(T)
    elseif T.mode == 'updated' then ok, err = passUpdated(T)
    elseif T.mode == 'replace' then ok, err = passReplace(T)
    else
        ok, err = passHash(T)
        -- Une passe complete relit toute la table : pas a chaque tour (sauf tant que le premier envoi n'est pas fini)
        if ok then T.nextAt = GetGameTimer() + HASH_S * 1000 end
    end
    if ok and (T.mode == 'append' or T.mode == 'updated') and GetGameTimer() >= T.keysAt and #T.pk > 0 then
        T.keysAt = GetGameTimer() + KEYS_S * 1000
        -- Les journaux ne perdent pas de lignes : seules les tables ON UPDATE et les journaux avec refresh en ont besoin
        if T.mode == 'updated' or T.conf.refresh then ok, err = passKeys(T) end
    end
    -- Empreintes des lignes envoyees : on ne garde que celles relues a ce passage (recouvrement, lignes ouvertes)
    local kept = {}
    for k in pairs(T.keepSent) do kept[k] = T.sent[k] end
    T.sent, T.keepSent = kept, {}
    if T.dirty then
        T.dirty = false
        if T.mode == 'hash' then SetResourceKvp('blm:' .. T.name, json.encode(T.hashes)) end
    end
    return ok, err
end

CreateThread(function()
    Wait(15000) -- le serveur finit de demarrer
    local failures = 0
    while true do
        local started = GetGameTimer()
        local called, ready, reason = pcall(setup)
        local err = called and reason or ready
        if called and ready then
            failures = 0
            while true do
                local passStart = GetGameTimer()
                for _, T in ipairs(tables) do
                    local ok, res, e = pcall(runTable, T)
                    if not ok then
                        warn('%s : %s', T.name, tostring(res))
                    elseif res == false then
                        warn('%s : %s', T.name, tostring(e))
                    end
                    Wait(50)
                end
                local elapsed = GetGameTimer() - passStart
                Wait(math.max(1000, PASS_S * 1000 - elapsed))
                -- Une fois par heure, les colonnes sont relues (table ajoutee ou modifiee en jeu)
                if GetGameTimer() - started > 3600000 then break end
            end
        else
            failures = failures + 1
            warn('demarrage impossible (%s), nouvel essai dans %d s', tostring(err), math.min(300, 15 * failures))
            Wait(math.min(300, 15 * failures) * 1000)
        end
    end
end)
