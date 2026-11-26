-- READ ONLY: запускать в SQL Editor тестовой ветки Neon до импорта.
SELECT current_database() AS database_name, current_user AS sql_user, version() AS postgres_version;

SELECT schema_name
FROM information_schema.schemata
WHERE schema_name IN ('public','auth','neon_auth')
ORDER BY schema_name;

SELECT n.nspname AS schema_name, p.proname AS function_name,
       pg_get_function_identity_arguments(p.oid) AS arguments,
       pg_get_function_result(p.oid) AS result_type
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE (n.nspname='auth' AND p.proname IN ('uid','user_id'))
   OR (n.nspname='public' AND p.proname='claim_legacy_account')
ORDER BY 1,2;

SELECT rolname, rolsuper, rolcanlogin
FROM pg_roles
WHERE rolname IN ('authenticated','anonymous','anon')
ORDER BY rolname;

SELECT table_schema, table_name
FROM information_schema.tables
WHERE table_schema IN ('public','neon_auth')
  AND table_name IN ('user','account','session')
ORDER BY table_schema, table_name;
