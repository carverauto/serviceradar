defmodule ServiceRadar.Observability.MtrRetentionPolicyMigrationTest do
  use ExUnit.Case, async: true

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260720173602_reconcile_mtr_retention_policy.exs",
                    __DIR__
                  )
  @external_resource @migration_path

  test "bootstrap migration seeds MTR settings and reconciles both retention policies" do
    migration = File.read!(@migration_path)

    assert migration =~ "INSERT INTO platform.mtr_settings"
    assert migration =~ "MTR_RETENTION_DAYS"
    assert migration =~ "WHERE NOT EXISTS (SELECT 1 FROM platform.mtr_settings)"
    assert migration =~ "ARRAY['mtr_traces', 'mtr_hops']"
    assert migration =~ "timescaledb_information.hypertables"
    assert migration =~ "create_hypertable"
    assert migration =~ "migrate_data => true"
    assert migration =~ "remove_retention_policy"
    assert migration =~ "add_retention_policy"
    assert migration =~ "retention_days"
    refute migration =~ "public.mtr_"
  end
end
