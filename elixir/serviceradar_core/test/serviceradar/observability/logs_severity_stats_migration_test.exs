defmodule ServiceRadar.Observability.LogsSeverityStatsMigrationTest do
  use ExUnit.Case, async: true

  @migration_path "priv/repo/migrations/20260812140000_ensure_logs_severity_stats_5m_cagg.exs"

  test "creates the SRQL severity rollup as a startup-safe continuous aggregate" do
    migration = File.read!(@migration_path)

    assert migration =~ ~s(@view "platform.logs_severity_stats_5m")
    assert migration =~ ~s(@candidate_view "platform.logs_severity_stats_5m_v2")
    assert migration =~ "CREATE MATERIALIZED VIEW IF NOT EXISTS \#{@candidate_view}"
    assert migration =~ "timescaledb.continuous,"
    assert migration =~ "timescaledb.create_group_indexes = false"
    assert migration =~ ~s(@source_table "platform.logs")
    assert migration =~ "FROM \#{@source_table}"
    assert migration =~ "WITH NO DATA"
    refute migration =~ "refresh_continuous_aggregate"

    for column <-
          ~w(bucket service_name total_count fatal_count error_count warning_count info_count debug_count) do
      assert migration =~ column
    end

    refute migration =~ "idx_logs_severity_stats_5m_bucket\n"
    assert migration =~ "idx_logs_severity_stats_5m_v2_service_bucket"
    assert migration =~ "ON \#{@candidate_view} (service_name, bucket DESC)"
  end

  test "atomically promotes the normalized candidate and preserves a rollback CAGG" do
    migration = File.read!(@migration_path)
    up_body = function_body!(migration, "up")
    up_lines = up_body |> String.split("\n") |> Enum.map(&String.trim/1)

    assert "if promotion_already_complete?() do" in up_lines

    assert ["create_severity_classifier()", "configure_promoted_policy()"] in Enum.chunk_every(
             up_lines,
             2,
             1,
             :discard
           )

    assert [
             "preflight_promotion()",
             "create_severity_classifier()",
             "create_candidate()",
             "configure_candidate_policy()",
             "remove_current_policy()",
             "promote_candidate()"
           ] in Enum.chunk_every(up_lines, 6, 1, :discard)

    preflight_body = function_body!(migration, "preflight_promotion")
    replay_body = function_body!(migration, "promotion_already_complete?")
    promotion_body = function_body!(migration, "promote_candidate")

    assert migration =~ ~s(@legacy_view "platform.logs_severity_stats_5m_legacy")
    assert preflight_body =~ "to_regclass('\#{@legacy_view}')"
    assert preflight_body =~ "refusing an ambiguous CAGG promotion"

    assert replay_body =~ "to_regclass($1) IS NOT NULL"
    assert replay_body =~ "to_regclass($2) IS NULL"
    assert replay_body =~ "FROM timescaledb_information.continuous_aggregates"
    assert replay_body =~ "view_schema = 'platform'"
    assert replay_body =~ "view_name = 'logs_severity_stats_5m'"
    assert replay_body =~ "serviceradar_log_severity_bucket"
    assert replay_body =~ "[@view, @candidate_view]"
    refute replay_body =~ "@legacy_view"
    refute replay_body =~ "pg_get_viewdef"

    assert promotion_body =~ "ALTER MATERIALIZED VIEW \#{@view}"
    assert promotion_body =~ "RENAME TO logs_severity_stats_5m_legacy"
    assert promotion_body =~ "ALTER MATERIALIZED VIEW \#{@candidate_view}"
    assert promotion_body =~ "RENAME TO logs_severity_stats_5m"
    refute promotion_body =~ "RAISE EXCEPTION"
    refute promotion_body =~ "add_continuous_aggregate_policy"
    refute promotion_body =~ "remove_continuous_aggregate_policy"
    refute migration =~ ~r/\bDROP\b/
    refute migration =~ ~r/\bDELETE\b/
  end

  test "matches canonical, syslog, and OTel enum severity forms" do
    migration = File.read!(@migration_path)
    classifier_body = function_body!(migration, "create_severity_classifier")

    assert migration =~ ~s(@classifier "platform.serviceradar_log_severity_bucket")
    assert classifier_body =~ "IMMUTABLE"
    assert classifier_body =~ "PARALLEL SAFE"

    for value <-
          ~w(fatal critical emergency alert error err warning warn info information informational notice debug trace) do
      assert classifier_body =~ "'#{value}'"
    end

    for level <- ~w(fatal error warn info debug trace) do
      for suffix <- ["", "2", "3", "4"] do
        assert classifier_body =~ "severity_number_#{level}#{suffix}"
      end
    end

    assert classifier_body =~ "WHEN severity_number BETWEEN 21 AND 24 THEN 'fatal'"
    assert classifier_body =~ "WHEN severity_number BETWEEN 17 AND 20 THEN 'error'"
    assert classifier_body =~ "WHEN severity_number BETWEEN 13 AND 16 THEN 'warning'"
    assert classifier_body =~ "WHEN severity_number BETWEEN 9 AND 12 THEN 'info'"
    assert classifier_body =~ "WHEN severity_number BETWEEN 1 AND 8 THEN 'debug'"

    create_body = function_body!(migration, "create_candidate")

    for bucket <- ~w(fatal error warning info debug) do
      assert create_body =~ "\#{@classifier}(severity_text, severity_number) = '#{bucket}'"
    end
  end

  test "installs the right-sized asynchronous refresh policy" do
    migration = File.read!(@migration_path)
    candidate_policy_body = function_body!(migration, "configure_candidate_policy")
    promoted_policy_body = function_body!(migration, "configure_promoted_policy")
    policy_body = function_body!(migration, "configure_policy")
    remove_current_policy_body = function_body!(migration, "remove_current_policy")

    assert migration =~ ~s(@refresh_start_offset "3 hours")
    assert migration =~ ~s(@refresh_end_offset "30 minutes")
    assert migration =~ ~s(@refresh_interval "10 minutes")
    assert candidate_policy_body =~ "configure_policy(@candidate_view)"
    assert promoted_policy_body =~ "configure_policy(@view)"
    assert policy_body =~ "add_continuous_aggregate_policy"
    assert policy_body =~ "'\#{view}'"
    assert policy_body =~ "if_not_exists => true"
    refute policy_body =~ "remove_continuous_aggregate_policy"

    assert remove_current_policy_body =~ "remove_continuous_aggregate_policy"
    assert remove_current_policy_body =~ "'\#{@view}'"
    assert remove_current_policy_body =~ "if_exists => true"
    refute remove_current_policy_body =~ "add_continuous_aggregate_policy"
  end

  defp function_body!(source, function_name) do
    pattern = ~r/  defp? #{Regex.escape(function_name)}(?:\([^)]*\))? do\n(?<body>.*?)\n  end/s

    case Regex.named_captures(pattern, source) do
      %{"body" => body} -> body
      _ -> flunk("could not find #{function_name}/0 in migration source")
    end
  end
end
