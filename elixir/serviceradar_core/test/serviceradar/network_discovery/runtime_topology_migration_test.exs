defmodule ServiceRadar.NetworkDiscovery.RuntimeTopologyMigrationTest do
  use ExUnit.Case, async: true

  @runtime_topology_migration_path "priv/repo/migrations/20260624120000_add_topology_rebuild_input_hash.exs"
  @seasonal_disposition_migration_path "priv/repo/migrations/20260627002000_add_last_disposition_to_seasonal_disposition_states.exs"
  @churn_tuning_migration_path "priv/repo/migrations/20260629140000_tune_churn_table_autovacuum_fillfactor.exs"

  test "input-hash migration repairs restored baselines missing projection metadata" do
    migration = File.read!(@runtime_topology_migration_path)

    assert migration =~ "create_if_not_exists table(:runtime_topology_projection_meta"
    assert migration =~ ~s(prefix: "platform")
    assert migration =~ "ADD COLUMN IF NOT EXISTS input_hash"
    assert migration =~ "ADD COLUMN IF NOT EXISTS input_hashed_at"
  end

  test "seasonal disposition migration repairs restored baselines missing state table" do
    migration = File.read!(@seasonal_disposition_migration_path)

    assert migration =~ "create_if_not_exists table(:seasonal_disposition_states"
    assert migration =~ ~s(prefix: "platform")
    assert migration =~ "seasonal_disposition_states_dow_check"
    assert migration =~ "seasonal_disposition_states_source_expires_idx"

    for column <- ["last_disposition", "last_status", "last_score", "last_evaluated_at"] do
      assert migration =~ "ADD COLUMN IF NOT EXISTS #{column}"
    end
  end

  test "churn tuning migration skips tables missing from restored baselines" do
    migration = File.read!(@churn_tuning_migration_path)

    assert migration =~ "to_regclass('platform.flow_process_attribution_current') IS NOT NULL"
    assert migration =~ "to_regclass('platform.gateways') IS NOT NULL"
  end
end
