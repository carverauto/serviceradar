defmodule ServiceRadar.Observability.MtrHypertableEnsureMigrationTest do
  use ExUnit.Case, async: true

  @migration_path "priv/repo/migrations/20260812200000_ensure_mtr_hypertables.exs"

  test "repairs bounded regular MTR tables without swallowing conversion errors" do
    migration = File.read!(@migration_path)

    assert migration =~ ~s({qualified, name} ->)
    assert migration =~ ~s("platform.mtr_traces")
    assert migration =~ ~s("platform.mtr_hops")
    assert migration =~ ~s(@time_column "time")
    assert migration =~ "@max_automatic_migration_bytes 268_435_456"
    assert migration =~ ~s(@lock_timeout "30s")
    assert migration =~ ~s(@statement_timeout "10min")
    assert migration =~ "create_hypertable"
    assert migration =~ "create_default_indexes => false"
    assert migration =~ "migrate_data => true"
    assert migration =~ "if_not_exists => true"
    assert migration =~ "SET LOCAL lock_timeout"
    assert migration =~ "SET LOCAL statement_timeout"
    assert migration =~ "failed to convert"
    refute migration =~ "add_retention_policy"
    refute migration =~ "EXCEPTION\n      WHEN others"
    refute migration =~ "@disable_ddl_transaction"
    refute migration =~ "@disable_migration_lock"
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
