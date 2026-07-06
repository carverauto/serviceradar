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
    assert sql =~ "n.nspname IN ('platform', 'public')"
    assert sql =~ "c.relkind IN ('r', 'p', 'S', 'v', 'm', 'f')"
    assert sql =~ "d.deptype = 'e'"
    assert sql =~ "owner_rel.relkind = 'r'"
    assert sql =~ "p.proowner <> r.oid"
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
end
