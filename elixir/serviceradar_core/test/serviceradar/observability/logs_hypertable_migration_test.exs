defmodule ServiceRadar.Observability.LogsHypertableMigrationTest do
  use ExUnit.Case, async: true

  @migration_path "priv/repo/migrations/20260812135000_ensure_logs_hypertable.exs"

  test "repairs a bounded regular logs table before continuous aggregates run" do
    migration = File.read!(@migration_path)

    assert migration =~ ~s(@table "platform.logs")
    assert migration =~ ~s(@time_column "timestamp")
    assert migration =~ "@max_automatic_migration_bytes 268_435_456"
    assert migration =~ ~s(@lock_timeout "30s")
    assert migration =~ ~s(@statement_timeout "10min")
    assert migration =~ "timescaledb_information.hypertables"
    assert migration =~ "pg_total_relation_size"
    assert migration =~ "create_hypertable"
    assert migration =~ "chunk_time_interval => INTERVAL ''\#{chunk_interval_hours} hours''"
    assert migration =~ "create_default_indexes => false"
    assert migration =~ "migrate_data => true"
    assert migration =~ "if_not_exists => true"
    assert migration =~ "SET LOCAL lock_timeout = '\#{@lock_timeout}'"
    assert migration =~ "SET LOCAL statement_timeout = '\#{@statement_timeout}'"
    refute migration =~ "set_config('lock_timeout'"
    refute migration =~ "set_config('statement_timeout'"
    assert migration =~ "automatic hypertable conversion is limited"
    assert migration =~ "during a maintenance window"
    assert migration =~ "failed to convert"
    refute migration =~ "EXCEPTION\n      WHEN others"
    refute migration =~ "@disable_ddl_transaction"
    refute migration =~ "@disable_migration_lock"

    assert migration =~
             ~s{System.get_env("SERVICERADAR_LOGS_CHUNK_INTERVAL_HOURS", "24")}

    assert migration =~ "must be a positive integer"
  end

  test "never attempts a destructive down conversion" do
    migration = File.read!(@migration_path)
    down_body = function_body!(migration, "down")

    refute down_body =~ ~r/\bDROP\b/
    refute down_body =~ ~r/\bDELETE\b/
    refute down_body =~ ~r/\bTRUNCATE\b/
  end

  defp function_body!(source, function_name) do
    pattern = ~r/  defp? #{Regex.escape(function_name)}(?:\([^)]*\))? do\n(?<body>.*?)\n  end/s

    case Regex.named_captures(pattern, source) do
      %{"body" => body} -> body
      _ -> flunk("could not find #{function_name}/0 in migration source")
    end
  end
end
