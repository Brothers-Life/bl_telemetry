# bl_telemetry

Ressource FiveM (Qbox) qui envoie la télémétrie du serveur (`POST /v1/batch`) et une copie des tables du jeu (`POST /v1/mirror`) au panel Brothers Life (le bot, depuis sa v2 ; avant, **bl-panel-api**).
Tout est sortant, par lots, sans jamais bloquer le tick serveur.

## Installation

```cfg
ensure oxmysql
ensure qbx_core
ensure bl_telemetry

set telemetry_url   "<URL de bl-panel-api>"
set telemetry_token "<INGEST_TOKEN de l'API>"
```

| Convar | Défaut | Rôle |
| --- | --- | --- |
| `telemetry_flush_ms` | `5000` | Fréquence d'envoi des lots |
| `telemetry_snapshot_s` | `300` | Relevé économie + joueurs en ligne |
| `telemetry_vehicles_s` | `21600` | Relevé du parc de véhicules |
| `telemetry_live_ms` | `30000` | Relecture des tables `bank_flows`, `bank_audit_log`, `bl_shops_admin_logs` (`0` = off) |
| `telemetry_commands` | `1` | Annonces du panel reçues avec chaque envoi (`0` = off) |
| `telemetry_db_s` | `900` | Lecture de la base du jeu par `dbsync.lua` (`0` = off) |
| `telemetry_perf_s` | `300` | Regroupement des performances joueurs + entités (`0` = off) |
| `telemetry_profiler_min` | `30` | Échantillon du profiler FiveM toutes les N minutes (`0` = off) |
| `telemetry_profiler_frames` | `300` | Durée de chaque échantillon (en images serveur) |
| `telemetry_society_sql` | — | Requête qui renvoie le total des comptes sociétés (colonne unique). Sans elle, essaie `management_funds` puis `bank_accounts_new` |
| `telemetry_mirror` | `1` | Copie des tables du jeu vers le panel (`0` = off) |
| `telemetry_mirror_s` | `60` | Un passage sur toutes les tables copiées toutes les N secondes |
| `telemetry_mirror_hash_s` | `180` | Tables sans journal ni `ON UPDATE` : relues toutes les N secondes |
| `telemetry_mirror_keys_s` | `900` | Liste complète des clés (rattrape les suppressions), et nombre de lignes des tables comptées |

## Mise à jour automatique (`update.lua`)

À chaque démarrage de la ressource (redémarrage du serveur ou `restart bl_telemetry`), une seule requête lit la version du `fxmanifest.lua` sur GitHub. Si elle est plus récente, tous les fichiers sont téléchargés (rien n'est écrit si un seul téléchargement échoue), remplacés, puis la ressource redémarre seule. Ensuite, plus rien ne tourne.

```cfg
# Pour que la ressource puisse se redemarrer seule apres une mise a jour
add_ace resource.bl_telemetry command.refresh allow
add_ace resource.bl_telemetry command.restart allow
```

| Convar | Défaut | Rôle |
| --- | --- | --- |
| `telemetry_autoupdate` | `1` | `0` = jamais de mise à jour automatique |
| `telemetry_update_repo` | `Brothers-Life/bl_telemetry` | Dépôt GitHub suivi |
| `telemetry_update_branch` | `main` | Branche suivie |
| `telemetry_update_keep` | — | Fichiers à ne jamais remplacer, séparés par des virgules (ex. `server/dbsync_queries.lua` si tu l'as modifié) |

Une nouvelle version = un `version` plus grand dans `fxmanifest.lua`, poussé sur la branche suivie. Sans les `add_ace`, la mise à jour est installée et la console demande un `restart bl_telemetry`.

## Copie des tables du jeu (`mirror.lua`, page Données FiveM du panel)

Le panel n'a plus besoin d'accéder à MariaDB : `mirror.lua` copie dans sa base les tables listées dans `server/mirror_tables.lua` (fiches joueurs, statistiques, logs du jeu, rôles Discord). La base du jeu reste fermée à Internet.

Seul ce qui a changé part, en arrière-plan, une table après l'autre, jamais dans le tick :

| Table | Ce qui est relu | Exemples |
| --- | --- | --- |
| Journal (`log = true`) | Les lignes au-delà du dernier id envoyé, plus les lignes encore ouvertes (`refresh`) | `bank_flows`, `bl_mc_sessions`, logs admin |
| Colonne `ON UPDATE CURRENT_TIMESTAMP` | Les lignes modifiées depuis le dernier passage | `players`, `ox_inventory` |
| Petite table (< 3 000 lignes) | La table entière, seulement si son `CHECKSUM` a changé | `management_groups`, `users` |
| Le reste | Une empreinte CRC32 par ligne (gardée en KVP) : seules les lignes changées ou supprimées partent | `player_vehicles` |
| `MirrorCounted` | Seulement le nombre de lignes | `ox_doorlock`, `shops` |

- Jamais envoyés : `sky_phone_accounts`, les colonnes `ip`, `tokens`, `password`, `email`, `hwid`, `secret` (et `*_ip`…), les colonnes binaires. Le panel refuse aussi de les stocker.
- Au redémarrage de la ressource, la copie reprend où elle en était (positions gardées par le panel, empreintes en KVP) : rien n'est renvoyé en entier.
- Premier envoi : progressif (pages de 1 000 lignes avec une pause), les grosses tables arrivent en quelques minutes.
- Ajouter une table : une ligne dans `MirrorTables`, la requête qui la lit côté panel, rien d'autre.

## Ce qui est envoyé automatiquement

- Console serveur complète (niveau déduit du message ; les détections du canal anticheat passent en `warn`)
- Connexions / déconnexions, personnage chargé (rattaché à la session), relevé « hors ligne » à la déconnexion
- Morts : position de la **victime** et cause lues côté serveur (OneSync), nom de l'arme, tueur
- Chat et commandes, actions staff txAdmin (kick, ban, warn, soin, message privé, annonce, annulation, whitelist, redémarrages), explosions
- Relevés périodiques : économie (cash, banque, crypto, sociétés), joueurs en ligne (argent, métier, gang, inventaire), véhicules
- Historique au premier démarrage (`backfill.lua`), puis suivi continu (`live.lua`)

## Lecture de la base du jeu (`dbsync.lua`)

Toutes les 15 min, le script lit la base MySQL du jeu et envoie au panel (page **Base de données**) :

- la taille et le nombre de lignes de chaque table ;
- le résultat de chaque requête de `server/dbsync_queries.lua` : répartition des fortunes, dernière connexion des personnages, métiers, objets les plus détenus (joueurs et coffres ox_inventory), véhicules les plus possédés, véhicules par garage, derniers bannissements.

Pour ajouter une info, il suffit d'ajouter une entrée dans `dbsync_queries.lua` (un `SELECT` avec des alias `AS`) : une nouvelle carte apparaît dans le panel, sans toucher à l'API ni au site. Une requête en erreur (table absente…) est ignorée et signalée une fois dans la console. Ne jamais y remonter d'identifiants sensibles (license, IP, Discord).

## Suivi des tables de journal du jeu (`live.lua`)

En plus de `bank_flows`, `bank_audit_log` et `bl_shops_admin_logs`, `live.lua` suit les tables listées dans `FOLLOW` (détections `bl_ac_detections`, sanctions et journal `admindash_*`, `mdt_audit`, `xt_prison`, achats premium, logs garages / jobs / shops, transactions téléphone…).
Chaque nouvelle ligne est envoyée telle quelle (event `game_log`), **sans les colonnes sensibles** (license, IP, Discord, Steam, token, hwid…). Une table absente est ignorée. Une détection `bl_ac_detections` déclenche aussi une alerte anticheat.
Elles alimentent la recherche globale et le journal des joueurs dans le panel.

## Performances (page Performances du panel)

- **Joueurs** (`client/perf.lua`, très léger) : toutes les 20 s, FPS sur 1 s, pire image, position, intérieur (MLO) et nombre d'entités chargées autour ; envoyé par paquets (1 message / min / joueur, limité côté serveur).
- **Serveur** (`server/perf.lua`) : toutes les 5 min, un seul résumé : FPS par zone de 250 m, par intérieur (MLO) et par joueur (avec ping), répartition des FPS, entités existantes (véhicules, peds, objets) et modèles les plus nombreux.
- **Coût des ressources** : échantillon du profiler FiveM toutes les 30 min, temps passé par ressource. Nécessite dans `server.cfg` :

```cfg
add_ace resource.bl_telemetry command.profiler allow
```

- **Ressources** : carte / MLO (`this_is_a_map`), fichiers de données, scripts client / serveur et fichiers envoyés aux joueurs.

## Annonces depuis le panel

Les annonces envoyées depuis le panel arrivent dans la réponse de chaque envoi (`POST /v1/batch?commands=1`, toutes les 5 s) : annonce dans le chat et/ou notification `ox_lib` à tous les joueurs ; le résultat repart avec l'envoi suivant. Aucune requête en plus.

## Performances

- Files d'attente à indices (ajout/retrait instantanés), bornées à 10 000 éléments chacune, avec avertissement si des éléments sont abandonnés.
- Un seul envoi à la fois, lots de 300 événements + 500 lignes de console ; s'il reste du retard, renvoi immédiat ; si l'API est en panne, attente croissante (2 s → 60 s) sans rien perdre.
- Identité des joueurs mise en cache 60 s ; explosions limitées à 10 par joueur et par 10 s (au-delà, un résumé `explosion_flood`).
- Relevé des véhicules et suivi des tables étalés pour ne jamais saturer la file.

## Envoyer des données depuis une autre ressource

### Achat (boutiques)

```lua
exports.bl_telemetry:LogEvent({
    type = 'purchase', citizenid = cid, player_name = name,
    data = { shop = '24/7 Grove', item = 'water', label = 'Eau', qty = 2, unit_price = 5, total = 10, currency = 'cash' },
})
```

### Flux bancaire

```lua
exports.bl_telemetry:LogEvent({
    type = 'event', subtype = 'bank_flow', citizenid = fromCid,
    data = { kind = 'transfer', from_cid = fromCid, to_cid = toCid, amount = 1500, note = 'loyer' },
})
```

(inutile si la ressource écrit déjà dans `bank_flows` : `live.lua` la suit.)

### Détection anticheat → alerte immédiate dans le panel et sur Discord

```lua
exports.bl_telemetry:Anticheat(source, 'noclip', { vitesse = 42 })
-- ou
TriggerEvent('bl_telemetry:anticheat', source, 'noclip', { vitesse = 42 })
```

### Mort avec capture d'écran

```lua
exports.bl_telemetry:LogEvent({
    type = 'death', citizenid = cid, player_name = name,
    data = { cause = 'balle', weapon = 'WEAPON_PISTOL', x = x, y = y, z = z, screenshot_url = url },
})
```
