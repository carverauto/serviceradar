defmodule ServiceRadar.Repo.TenantMigrations.AddSweepCleanupIndexes do
  @moduledoc """
  Adds indexes to support efficient cleanup of old sweep data.

  These indexes enable the SweepDataCleanupWorker to efficiently find
  and delete old records without full table scans.
  """

  use Ecto.Migration

  def up do
    # Index for cleaning up old host results by inserted_at
    create index(:sweep_host_results, [:inserted_at],
             name: "sweep_host_results_inserted_at_idx",
             prefix: prefix()
           )

    # Index for cleaning up old executions by started_at and status
    # Only completed/failed executions are cleaned up
    create index(:sweep_group_executions, [:started_at],
             name: "sweep_group_executions_started_at_idx",
             where: "status IN ('completed', 'failed')",
             prefix: prefix()
           )
  end

  def down do
    drop_if_exists index(:sweep_group_executions, [:started_at],
                     name: "sweep_group_executions_started_at_idx",
                     prefix: prefix()
                   )

    drop_if_exists index(:sweep_host_results, [:inserted_at],
                     name: "sweep_host_results_inserted_at_idx",
                     prefix: prefix()
                   )
  end
end
