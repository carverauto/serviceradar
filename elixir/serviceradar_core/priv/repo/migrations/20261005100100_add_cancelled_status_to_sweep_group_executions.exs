defmodule ServiceRadar.Repo.Migrations.AddCancelledStatusToSweepGroupExecutions do
  use Ecto.Migration

  def up do
    # Drop the existing check constraint and re-create it with :cancelled included.
    # The constraint name matches the one Ash/Ecto generates for the status column.
    execute """
    ALTER TABLE platform.sweep_group_executions
      DROP CONSTRAINT IF EXISTS sweep_group_executions_status_check
    """

    execute """
    ALTER TABLE platform.sweep_group_executions
      ADD CONSTRAINT sweep_group_executions_status_check
      CHECK (status IN ('pending', 'running', 'completed', 'failed', 'cancelled'))
    """
  end

  def down do
    execute """
    ALTER TABLE platform.sweep_group_executions
      DROP CONSTRAINT IF EXISTS sweep_group_executions_status_check
    """

    execute """
    ALTER TABLE platform.sweep_group_executions
      ADD CONSTRAINT sweep_group_executions_status_check
      CHECK (status IN ('pending', 'running', 'completed', 'failed'))
    """
  end
end
