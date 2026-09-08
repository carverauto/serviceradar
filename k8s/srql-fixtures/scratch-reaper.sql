-- Drop leftover scratch databases on the shared srql-fixtures CNPG cluster.
--
-- Protected names must stay in sync with go/pkg/srqlfixture/reaper and
-- rust/integration-db. Timescale background workers are not live clients;
-- FORCE is what actually lets the DROP succeed against them.
SELECT format('DROP DATABASE IF EXISTS %I WITH (FORCE)', d.datname)
FROM pg_database AS d
JOIN pg_tablespace AS t ON t.oid = d.dattablespace
WHERE NOT d.datistemplate
  AND d.datname NOT IN (
      'postgres',
      'template0',
      'template1',
      'srql_fixture',
      'sr_core_template'
  )
  -- Reserve the entire generation namespace, including malformed candidates.
  -- Only dedicated registry cleanup may remove template generations.
  AND d.datname !~ '^sr_tpl_'
  AND d.datname ~ '^[A-Za-z_][A-Za-z0-9_]{0,62}$'
  AND t.spcname = 'pg_default'
  AND (pg_stat_file(format('base/%s/PG_VERSION', d.oid), true)).modification
      < now() - interval '6 hours'
  AND NOT EXISTS (
        SELECT 1
        FROM pg_stat_activity AS a
        WHERE a.datname = d.datname
          AND a.backend_type = 'client backend'
          AND coalesce(a.application_name, '') NOT ILIKE 'TimescaleDB%'
          AND a.pid <> pg_backend_pid()
      );
\gexec
