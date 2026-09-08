defmodule ServiceRadar.Observability.OcsfEventsHourlyStatsCaggRepairMigrationTest do
  use ExUnit.Case, async: true

  @migration_path "priv/repo/migrations/20260812202000_repair_ocsf_events_hourly_stats_cagg.exs"

  test "creates a real continuous aggregate with no startup refresh" do
    migration = File.read!(@migration_path)

    assert migration =~ ~s(@view "platform.ocsf_events_hourly_stats")
    assert migration =~ ~s(@candidate_view "platform.ocsf_events_hourly_stats_v2")
    assert migration =~ ~s(@stale_view "platform.ocsf_events_hourly_stats_stale_view")
    assert migration =~ ~s(@source_table "platform.ocsf_events")
    assert migration =~ "CREATE MATERIALIZED VIEW IF NOT EXISTS \#{@candidate_view}"
    assert migration =~ "timescaledb.continuous"
    assert migration =~ "WITH NO DATA"
    assert migration =~ "FROM \#{@source_table}"
    refute migration =~ "refresh_continuous_aggregate"
    refute migration =~ "add_retention_policy"
  end

  test "renames a leftover view instead of querying it as a CAGG" do
    migration = File.read!(@migration_path)
    promotion_body = function_body!(migration, "promote_candidate")
    replay_body = function_body!(migration, "promotion_already_complete?")

    preflight_body = function_body!(migration, "preflight_promotion")

    assert preflight_body =~ "to_regclass('\#{@stale_view}') IS NOT NULL"
    assert preflight_body =~ "to_regclass('\#{@view}') IS NOT NULL"
    assert replay_body =~ "timescaledb_information.continuous_aggregates"
    assert replay_body =~ "view_name = 'ocsf_events_hourly_stats'"
    assert promotion_body =~ "ALTER VIEW \#{@view} RENAME TO ocsf_events_hourly_stats_stale_view"

    assert promotion_body =~
             "ALTER MATERIALIZED VIEW \#{@view} RENAME TO ocsf_events_hourly_stats_stale_view"

    assert promotion_body =~ "ALTER MATERIALIZED VIEW \#{@candidate_view}"
    assert promotion_body =~ "RENAME TO ocsf_events_hourly_stats"
    refute migration =~ ~r/\bDROP\b/
    refute migration =~ ~r/\bDELETE\b/
  end

  test "installs the original asynchronous refresh policy" do
    migration = File.read!(@migration_path)
    policy_body = function_body!(migration, "configure_policy")

    assert migration =~ ~s(@refresh_start_offset "26 hours")
    assert migration =~ ~s(@refresh_end_offset "5 minutes")
    assert migration =~ ~s(@refresh_interval "5 minutes")
    assert policy_body =~ "add_continuous_aggregate_policy"
    assert policy_body =~ "if_not_exists => true"
    refute policy_body =~ "remove_continuous_aggregate_policy"
  end

  defp function_body!(source, function_name) do
    pattern = ~r/  defp? #{Regex.escape(function_name)}(?:\([^)]*\))? do\n(?<body>.*?)\n  end/s

    case Regex.named_captures(pattern, source) do
      %{"body" => body} -> body
      _ -> flunk("could not find #{function_name}/0 in migration source")
    end
  end
end
