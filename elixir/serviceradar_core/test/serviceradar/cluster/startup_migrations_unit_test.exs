defmodule ServiceRadar.Cluster.StartupMigrationsUnitTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Cluster.StartupMigrations

  test "classify_bootstrap_state identifies an empty database" do
    assert :empty = StartupMigrations.classify_bootstrap_state([], 0)
  end

  test "classify_bootstrap_state prefers migration history over object count" do
    assert :migrated = StartupMigrations.classify_bootstrap_state([20_260_519_162_000], 0)
    assert :migrated = StartupMigrations.classify_bootstrap_state([20_260_519_162_000], 42)
  end

  test "classify_bootstrap_state fails closed for platform objects without migration history" do
    assert {:ambiguous, %{platform_object_count: 2, migration_versions: []}} =
             StartupMigrations.classify_bootstrap_state([], 2)
  end

  test "managed ownership repair query covers ServiceRadar objects and excludes extensions" do
    sql = StartupMigrations.managed_database_ownership_repair_needed_sql()

    assert sql =~ "n.nspname = 'platform'"

    assert sql =~
             "p.oid = to_regprocedure('public.age_device_neighborhood(text,boolean,boolean)')"

    refute sql =~ "n.nspname IN ('platform', 'public')"
    assert sql =~ "c.relkind IN ('r', 'p', 'S', 'v', 'm', 'f')"
    assert sql =~ "d.deptype = 'e'"
    assert sql =~ "owner_rel.relkind = 'r'"
    assert sql =~ "p.proowner <> r.oid"

    assert sql =~ "p.oid = to_regprocedure('public.user_search(text)')"
    assert sql =~ "p.proowner = r.oid"
    refute sql =~ "AND p.prosecdef"
  end

  test "continuous aggregate backing repair targets missing app-role SELECT privileges" do
    assert StartupMigrations.continuous_aggregate_information_available_query_sql() ==
             "SELECT to_regclass('timescaledb_information.continuous_aggregates') IS NOT NULL"

    sql = StartupMigrations.continuous_aggregate_backing_privileges_query_sql()

    assert sql =~ "timescaledb_information.continuous_aggregates"
    assert sql =~ "ca.view_schema = 'platform'"
    assert sql =~ "ca.view_owner = r.rolname"
    assert sql =~ "NOT has_table_privilege(r.oid, materialization.oid, 'SELECT')"
    assert sql =~ "ca.materialization_hypertable_schema"
    assert sql =~ "ca.materialization_hypertable_name"

    assert StartupMigrations.continuous_aggregate_backing_grant_statement(
             "_timescaledb_internal",
             "_materialized_hypertable_27",
             "service\"radar"
           ) ==
             ~s{GRANT SELECT ON TABLE "_timescaledb_internal"."_materialized_hypertable_27" TO "service""radar"}
  end

  test "function ownership repair excludes unrelated public functions" do
    sql = StartupMigrations.managed_function_ownership_query_sql()

    assert sql =~ "n.nspname = 'platform'"

    assert sql =~
             "p.oid = to_regprocedure('public.age_device_neighborhood(text,boolean,boolean)')"

    refute sql =~ "n.nspname IN ('platform', 'public')"
  end

  test "function ownership statement quotes identifiers and preserves identity args" do
    assert StartupMigrations.function_ownership_statement(
             "public",
             "age_device_neighborhood",
             "p_device_id text, p_collector_owned_only boolean, p_include_topology boolean",
             "service\"radar"
           ) ==
             ~s{ALTER FUNCTION "public"."age_device_neighborhood"(p_device_id text, p_collector_owned_only boolean, p_include_topology boolean) OWNER TO "service""radar"}
  end

  test "CNPG pooler auth recovery inspects an app-owned function before promotion" do
    sql = StartupMigrations.cnpg_pooler_auth_function_recovery_query_sql()

    assert sql =~ "p.oid = to_regprocedure('public.user_search(text)')"
    assert sql =~ "p.proowner = r.oid"
    assert sql =~ "p.prosecdef"
    assert sql =~ "current_user::text"
    assert sql =~ "l.lanname"
    assert sql =~ "pg_get_function_result(p.oid)"
    assert sql =~ "btrim(p.prosrc)"
    refute sql =~ "AND p.prosecdef"

    assert StartupMigrations.cnpg_pooler_auth_function_canonical?(
             "sql",
             "TABLE(usename name, passwd text)",
             true,
             "  SELECT usename, passwd FROM pg_catalog.pg_shadow\nWHERE usename=$1;  "
           )

    assert StartupMigrations.cnpg_pooler_auth_function_canonical?(
             "sql",
             "TABLE(usename name, passwd text)",
             true,
             "SELECT usename, passwd FROM pg_shadow WHERE usename=$1;"
           )

    refute StartupMigrations.cnpg_pooler_auth_function_canonical?(
             "sql",
             "TABLE(usename name, passwd text)",
             true,
             "SELECT usename, passwd FROM pg_catalog.pg_shadow WHERE usename=$1; SELECT 1;"
           )

    refute StartupMigrations.cnpg_pooler_auth_function_canonical?(
             "plpgsql",
             "TABLE(usename name, passwd text)",
             true,
             "SELECT usename, passwd FROM pg_catalog.pg_shadow WHERE usename=$1;"
           )

    refute StartupMigrations.cnpg_pooler_auth_function_canonical?(
             "sql",
             "TABLE(usename name, passwd text)",
             false,
             "SELECT usename, passwd FROM pg_catalog.pg_shadow WHERE usename=$1;"
           )

    recreate_sql = StartupMigrations.cnpg_pooler_auth_function_recreate_statement()

    assert recreate_sql =~ "CREATE OR REPLACE FUNCTION public.user_search(uname text)"
    assert recreate_sql =~ "RETURNS TABLE(usename name, passwd text)"
    assert recreate_sql =~ "SECURITY DEFINER"
    assert recreate_sql =~ "SET search_path = pg_catalog"

    assert recreate_sql =~
             "SELECT usename, passwd FROM pg_catalog.pg_shadow WHERE usename=$1;"

    assert StartupMigrations.cnpg_pooler_auth_function_owner_statement("postgres") ==
             ~s{ALTER FUNCTION "public"."user_search"(text) OWNER TO "postgres"}

    grantees_sql = StartupMigrations.cnpg_pooler_auth_function_grantees_query_sql()

    assert grantees_sql =~ "aclexplode"
    assert grantees_sql =~ "acldefault('f', p.proowner)"
    assert grantees_sql =~ "acl.grantee <> p.proowner"

    assert StartupMigrations.cnpg_pooler_auth_function_revoke_statement("unexpected\"role") ==
             ~s{REVOKE ALL PRIVILEGES ON FUNCTION "public"."user_search"(text) FROM "unexpected""role"}

    assert StartupMigrations.cnpg_pooler_auth_function_grant_statement() ==
             ~s{GRANT EXECUTE ON FUNCTION "public"."user_search"(text) TO "cnpg_pooler_pgbouncer"}
  end
end
