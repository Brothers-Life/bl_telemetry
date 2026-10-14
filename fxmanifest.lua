fx_version 'cerulean'
game 'gta5'

name 'bl_telemetry'
description 'Telemetrie serveur -> ingest-api (Postgres/Grafana) : events, logs console, snapshots economie/joueurs/vehicules'
version '1.1.0'

server_only 'yes'

use_experimental_fxv2_oal 'yes'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/backfill.lua',
    'server/live.lua',
}

dependencies {
    'oxmysql',
    'qbx_core',
}
