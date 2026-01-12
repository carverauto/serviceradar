defmodule ServiceRadar.Repo.TenantMigrations.AddScannerMetricsToExecutions do
  @moduledoc """
  Adds scanner_metrics column to sweep_group_executions table.

  This column stores performance metrics from the network scanner including:
  - Packet statistics (sent, received, dropped)
  - Ring buffer statistics
  - Retry statistics
  - Port allocation statistics
  - Rate limiting statistics
  """

  use Ecto.Migration

  def up do
    alter table(:sweep_group_executions, prefix: prefix()) do
      add :scanner_metrics, :map, null: true, default: %{}
    end
  end

  def down do
    alter table(:sweep_group_executions, prefix: prefix()) do
      remove :scanner_metrics
    end
  end
end
