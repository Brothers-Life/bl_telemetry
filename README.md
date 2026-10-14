# bl_telemetry

Ressource FiveM (Qbox) qui envoie la télémétrie du serveur vers **bl-panel-api** (`POST /v1/batch`), affichée dans le panel Brothers Life.
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
| `telemetry_commands_ms` | `5000` | Relève des ordres du panel (annonces) (`0` = off) |
| `telemetry_db_s` | `900` | Lecture de la base du jeu par `dbsync.lua` (`0` = off) |
| `telemetry_society_sql` | — | Requête qui renvoie le total des comptes sociétés (colonne unique). Sans elle, essaie `management_funds` puis `bank_accounts_new` |

## Ce qui est envoyé automatiquement

- Console serveur complète (niveau déduit du message ; les détections du canal anticheat passent en `warn`)
- Connexions / déconnexions, personnage chargé (rattaché à la session), relevé « hors ligne » à la déconnexion
- Morts : position de la **victime** et cause lues côté serveur (OneSync), nom de l'arme, tueur
- Chat et commandes, actions staff txAdmin, explosions
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

## Annonces depuis le panel

Le script relève toutes les 5 s les ordres envoyés depuis le panel (`GET /v1/commands`) et les exécute : annonce dans le chat et/ou notification `ox_lib` à tous les joueurs, puis renvoie le résultat.

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
