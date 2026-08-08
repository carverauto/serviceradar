defmodule ServiceRadar.Observability.MtrRetentionPolicyMigrationTest do
  use ExUnit.Case, async: true

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260720173602_reconcile_mtr_retention_policy.exs",
                    __DIR__
                  )
  @external_resource @migration_path

  test "migration defers MTR Timescale reconciliation to the post-bootstrap seeder" do
    migration = File.read!(@migration_path)

    assert migration =~ "MtrSettingsSeeder"
    assert migration =~ "def up, do: :ok"
    refute migration =~ "create_hypertable"
    refute migration =~ "add_retention_policy"
  end
end
