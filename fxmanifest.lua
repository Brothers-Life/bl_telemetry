fx_version 'cerulean'
game 'gta5'

name 'bl_telemetry'
description 'Telemetrie serveur et copie des tables du jeu -> panel Brothers Life'
version '1.5.0'

use_experimental_fxv2_oal 'yes'

client_scripts {
    'client/perf.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/backfill.lua',
    'server/live.lua',
    'server/dbsync_queries.lua',
    'server/dbsync.lua',
    'server/perf.lua',
    'server/mirror_tables.lua',
    'server/mirror.lua',
}

dependencies {
    'oxmysql',
    'qbx_core',
}
