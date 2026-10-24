--[[
    Tables du jeu copiees dans le panel (page Donnees FiveM) par mirror.lua.
    Une table absente de ce serveur est ignoree. Le mode de copie est choisi tout seul :
      - log = true      : journal, les lignes ne changent plus une fois ecrites -> seules les nouvelles partent ;
                          refresh = condition SQL des lignes encore ouvertes (relues tant qu'elles la verifient)
      - colonne ON UPDATE CURRENT_TIMESTAMP : seules les lignes modifiees depuis le dernier passage partent
      - petite table    : envoyee entiere, seulement quand son CHECKSUM change
      - sinon           : empreinte par ligne, seules les lignes changees ou supprimees partent
    columns = { ... } limite les colonnes envoyees (le reste ne sert pas au panel).
    Jamais envoyes, quoi qu'il arrive : sky_phone_accounts, et les colonnes ip, tokens, password, email, hwid, secret.
]]

MirrorTables = {
    -- Comptes, personnages, metiers
    { name = 'users' },
    { name = 'players' },
    { name = 'management_groups' },
    { name = 'player_groups' },
    { name = 'player_jobs_activity' },
    { name = 'job_duty_time' },
    { name = 'job_level_state' },
    { name = 'job_open_state' },
    { name = 'job_week_duty' },
    { name = 'job_week_stats' },
    { name = 'qbx_gang_meta' },
    { name = 'playerskins', columns = { 'id', 'citizenid', 'active' } },
    { name = 'ox_inventory' },
    { name = 'properties' },
    { name = 'qbx_custom_garages' },
    { name = 'player_vehicles' },
    { name = 'xt_prison' },
    { name = 'harvest_zones' },
    { name = 'harvest_zone_player_stats' },
    { name = 'bl_safezones_zones' },

    -- Connexions et staff
    { name = 'bl_mc_sessions', log = true, refresh = 'left_at IS NULL' },
    { name = 'bl_mc_session_chars', log = true },
    { name = 'admindash_staff_sessions', log = true, refresh = 'ended_at IS NULL' },
    { name = 'admindash_roles' },
    { name = 'admindash_role_actions' },
    { name = 'admindash_reports', log = true, refresh = 'resolved_at IS NULL' },
    { name = 'admindash_sanctions' },
    { name = 'bans' },

    -- Economie, boutique, telephone
    { name = 'bank_accounts_new' },
    { name = 'bank_flows', log = true },
    { name = 'premium_points' },
    { name = 'premium_loyalty' },
    { name = 'premium_shop_items' },
    { name = 'premium_shop_item_purchases', log = true },
    { name = 'premium_bundle_purchases', log = true },
    { name = 'premium_crate_openings', log = true },
    { name = 'premium_promo_redemptions', log = true },
    { name = 'premium_gifts' },
    { name = 'premium_shop_logs', log = true },
    { name = 'selfmenu_invoices' },
    { name = 'job_payroll_runs', log = true },
    { name = 'job_payroll_lines', log = true },
    { name = 'sky_phone_bank_transactions', log = true },
    { name = 'sky_phone_billing_invoices' },
    { name = 'sky_phone_calls', log = true },
    { name = 'sky_phone_health_daily' },
    { name = 'sky_phone_crypto_markets' },
    { name = 'sky_phone_crypto_market_ticks', log = true },
    { name = 'sky_phone_crypto_balances' },

    -- Justice et police
    { name = 'mdt_calls' },
    { name = 'mdt_audit', log = true },

    -- Journaux du jeu (page Logs du jeu)
    { name = 'admindash_audit_log', log = true },
    { name = 'admindash_staffmsg_history', log = true },
    { name = 'admindash_blip_logs', log = true },
    { name = 'garage_admin_logs', log = true },
    { name = 'job_admin_logs', log = true },
    { name = 'job_action_history', log = true },
    { name = 'job_safe_log', log = true },
    { name = 'gang_admin_logs', log = true },
    { name = 'gang_safe_log', log = true },
    { name = 'shop_admin_logs', log = true },
    { name = 'bl_shops_admin_logs', log = true },
    { name = 'door_logs', log = true },
    { name = 'harvest_zone_logs', log = true },
    { name = 'bl_crafting_logs', log = true },
    { name = 'bl_safezones_audit', log = true },
    { name = 'bl_safezones_visits', log = true },
    { name = 'teleport_admin_logs', log = true },
    { name = 'mapeditor_audit', log = true },
    { name = 'bank_audit_log', log = true },
    { name = 'dj_audit', log = true },
    { name = 'carplay_logs', log = true },
    { name = 'billboard_history', log = true },
    { name = 'tv_admin_logs', log = true },
    { name = 'sky_phone_admin_audit', log = true },
}

-- Tables dont le panel n'affiche que le nombre de lignes : seul ce nombre part
MirrorCounted = {
    'admindash_blips', 'ox_doorlock', 'shops', 'market_markets', 'mapeditor_objects', 'bl_crafting_tables',
    'bl_crafting_recipes', 'tv_screens', 'billboards', 'dj_venues', 'qbx_teleport_overrides', 'bl_hotels',
    'sky_phone_company_profiles',
}
