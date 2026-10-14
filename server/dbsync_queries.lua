--[[
    Requetes lues dans la base MySQL du jeu par dbsync.lua et affichees dans le panel (page « Base de donnees »).
    - Uniquement des SELECT (lecture seule). Une table absente est simplement ignoree.
    - Max 500 lignes par requete. Ne jamais remonter d'identifiants sensibles (license, ip, discord, steam).
    - Ajouter une entree = une nouvelle carte dans le panel, sans toucher a l'API ni au site.
      kind : 'table' (tableau), 'bar' (barres : 1re colonne = libelle, 2e = valeur), 'donut',
             'hidden' (utilise par le panel mais pas affiche tel quel) ; max = nombre de lignes (5000 au plus)
]]

DBSYNC_QUERIES = {
    {
        name = 'wealth_brackets', label = 'Répartition des fortunes', kind = 'bar',
        sql = [[
            SELECT bracket AS tranche, COUNT(*) AS personnages FROM (
                SELECT CASE
                    WHEN w < 10000 THEN '1. < 10 k$'
                    WHEN w < 100000 THEN '2. 10 k$ – 100 k$'
                    WHEN w < 1000000 THEN '3. 100 k$ – 1 M$'
                    WHEN w < 10000000 THEN '4. 1 M$ – 10 M$'
                    ELSE '5. > 10 M$' END AS bracket
                FROM (SELECT COALESCE(CAST(JSON_EXTRACT(money, '$.cash') AS DOUBLE), 0)
                           + COALESCE(CAST(JSON_EXTRACT(money, '$.bank') AS DOUBLE), 0) AS w FROM players) t
            ) b GROUP BY bracket ORDER BY bracket
        ]],
    },
    {
        name = 'retention', label = 'Dernière connexion des personnages', kind = 'bar',
        sql = [[
            SELECT CASE
                WHEN last_logged_out IS NULL THEN '5. jamais'
                WHEN last_logged_out > NOW() - INTERVAL 1 DAY THEN '1. < 24 h'
                WHEN last_logged_out > NOW() - INTERVAL 7 DAY THEN '2. < 7 jours'
                WHEN last_logged_out > NOW() - INTERVAL 30 DAY THEN '3. < 30 jours'
                ELSE '4. > 30 jours' END AS periode,
                COUNT(*) AS personnages
            FROM players GROUP BY periode ORDER BY periode
        ]],
    },
    {
        name = 'jobs', label = 'Personnages par métier', kind = 'donut',
        sql = [[
            SELECT COALESCE(JSON_UNQUOTE(JSON_EXTRACT(job, '$.name')), '?') AS metier, COUNT(*) AS personnages
            FROM players GROUP BY metier ORDER BY personnages DESC LIMIT 15
        ]],
    },
    {
        name = 'items_players', label = 'Objets les plus détenus (joueurs)', kind = 'table',
        sql = [[
            SELECT jt.name AS objet, SUM(COALESCE(jt.count, 1)) AS quantite, COUNT(DISTINCT p.citizenid) AS joueurs
            FROM players p,
                 JSON_TABLE(p.inventory, '$[*]' COLUMNS (name VARCHAR(100) PATH '$.name', count INT PATH '$.count')) jt
            WHERE jt.name IS NOT NULL
            GROUP BY jt.name ORDER BY quantite DESC LIMIT 100
        ]],
    },
    {
        name = 'items_stashes', label = 'Objets dans les coffres', kind = 'table',
        sql = [[
            SELECT jt.name AS objet, SUM(COALESCE(jt.count, 1)) AS quantite, COUNT(DISTINCT CONCAT(o.owner, o.name)) AS coffres
            FROM ox_inventory o,
                 JSON_TABLE(o.data, '$[*]' COLUMNS (name VARCHAR(100) PATH '$.name', count INT PATH '$.count')) jt
            WHERE jt.name IS NOT NULL
            GROUP BY jt.name ORDER BY quantite DESC LIMIT 100
        ]],
    },
    {
        name = 'vehicle_models', label = 'Véhicules les plus possédés', kind = 'bar',
        sql = [[
            SELECT vehicle AS modele, COUNT(*) AS exemplaires FROM player_vehicles
            GROUP BY vehicle ORDER BY exemplaires DESC LIMIT 15
        ]],
    },
    {
        name = 'vehicle_garages', label = 'Véhicules par garage', kind = 'table',
        sql = [[
            SELECT COALESCE(garage, '?') AS garage,
                   SUM(state = 1) AS au_garage, SUM(state = 0) AS sortis, SUM(state NOT IN (0, 1)) AS fourriere_ou_autre,
                   COUNT(*) AS total
            FROM player_vehicles GROUP BY garage ORDER BY total DESC LIMIT 50
        ]],
    },
    {
        -- Comptes lies : empreinte de la licence (jamais la licence elle-meme) par personnage. Non affiche tel quel.
        name = 'license_map', label = 'Empreintes de licence', kind = 'hidden', max = 5000,
        sql = [[
            SELECT citizenid AS citizenid, LEFT(SHA2(license, 256), 16) AS empreinte,
                   CONCAT(COALESCE(JSON_UNQUOTE(JSON_EXTRACT(charinfo, '$.firstname')), '?'), ' ',
                          COALESCE(JSON_UNQUOTE(JSON_EXTRACT(charinfo, '$.lastname')), '?')) AS nom
            FROM players WHERE license IS NOT NULL
        ]],
    },
    {
        name = 'bans', label = 'Derniers bannissements', kind = 'table',
        sql = [[
            SELECT name AS joueur, reason AS raison, bannedby AS par,
                   CASE WHEN expire IS NULL OR expire >= 2147483647 THEN 'permanent'
                        ELSE DATE_FORMAT(FROM_UNIXTIME(expire), '%d/%m/%Y %H:%i') END AS expire
            FROM bans ORDER BY id DESC LIMIT 50
        ]],
    },
}
