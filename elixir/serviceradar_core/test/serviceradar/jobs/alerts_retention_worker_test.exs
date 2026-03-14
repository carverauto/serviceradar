defmodule ServiceRadar.Jobs.AlertsRetentionWorkerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Jobs.AlertsRetentionWorker

  describe "delete_batch_sql/0" do
    test "deletes alerts by triggered_at in batches" do
      sql = AlertsRetentionWorker.delete_batch_sql()

      assert sql =~ "SELECT id"
      assert sql =~ "FROM alerts"
      assert sql =~ "triggered_at < $1"
      assert sql =~ "LIMIT $2"
      assert sql =~ "DELETE FROM alerts AS alerts"
    end
  end

  describe "config/0" do
    test "uses defaults when runtime config is absent" do
      original = Application.get_env(:serviceradar_core, AlertsRetentionWorker)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:serviceradar_core, AlertsRetentionWorker)
        else
          Application.put_env(:serviceradar_core, AlertsRetentionWorker, original)
        end
      end)

      Application.delete_env(:serviceradar_core, AlertsRetentionWorker)

      assert AlertsRetentionWorker.config() == %{
               retention_days: 3,
               batch_size: 10_000,
               max_batches: 100
             }
    end

    test "uses configured runtime overrides" do
      original = Application.get_env(:serviceradar_core, AlertsRetentionWorker)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:serviceradar_core, AlertsRetentionWorker)
        else
          Application.put_env(:serviceradar_core, AlertsRetentionWorker, original)
        end
      end)

      Application.put_env(:serviceradar_core, AlertsRetentionWorker,
        retention_days: 5,
        batch_size: 2_500,
        max_batches: 8
      )

      assert AlertsRetentionWorker.config() == %{
               retention_days: 5,
               batch_size: 2_500,
               max_batches: 8
             }
    end
  end
end
