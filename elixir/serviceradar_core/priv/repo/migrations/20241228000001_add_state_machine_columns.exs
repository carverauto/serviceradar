defmodule ServiceRadar.Repo.Migrations.AddStateMachineColumns do
  @moduledoc """
  Adds state machine columns for infrastructure components.

  - Pollers: status column (already exists as string, needs conversion)
  - Checkers: status, consecutive_failures, last_success, last_failure, failure_reason
  """

  use Ecto.Migration

  def up do
    # Update pollers status column from string to text (PostgreSQL doesn't have atom type)
    # The Ash type will handle atom <-> string conversion
    # Just ensure the column can handle the new states
    execute """
    ALTER TABLE pollers
    ALTER COLUMN status SET DEFAULT 'inactive';
    """

    execute """
    UPDATE pollers
    SET status = CASE status
      WHEN 'active' THEN 'healthy'
      WHEN 'inactive' THEN 'inactive'
      WHEN 'degraded' THEN 'degraded'
      ELSE 'inactive'
    END
    WHERE status NOT IN ('healthy', 'degraded', 'offline', 'recovering', 'maintenance', 'draining', 'inactive');
    """

    # Add new columns to checkers table
    alter table(:checkers) do
      add_if_not_exists :status, :string, default: "active"
      add_if_not_exists :consecutive_failures, :integer, default: 0
      add_if_not_exists :last_success, :utc_datetime
      add_if_not_exists :last_failure, :utc_datetime
      add_if_not_exists :failure_reason, :string
    end

    # Create index for status-based queries
    create_if_not_exists index(:pollers, [:status])
    create_if_not_exists index(:pollers, [:tenant_id, :status])
    create_if_not_exists index(:checkers, [:status])
    create_if_not_exists index(:checkers, [:tenant_id, :status])
    create_if_not_exists index(:checkers, [:consecutive_failures])
  end

  def down do
    # Revert pollers status to old values
    execute """
    UPDATE pollers
    SET status = CASE status
      WHEN 'healthy' THEN 'active'
      WHEN 'inactive' THEN 'inactive'
      WHEN 'degraded' THEN 'degraded'
      WHEN 'offline' THEN 'inactive'
      WHEN 'recovering' THEN 'active'
      WHEN 'maintenance' THEN 'inactive'
      WHEN 'draining' THEN 'inactive'
      ELSE 'inactive'
    END;
    """

    execute """
    ALTER TABLE pollers
    ALTER COLUMN status SET DEFAULT 'active';
    """

    # Remove checker columns
    alter table(:checkers) do
      remove_if_exists :status, :string
      remove_if_exists :consecutive_failures, :integer
      remove_if_exists :last_success, :utc_datetime
      remove_if_exists :last_failure, :utc_datetime
      remove_if_exists :failure_reason, :string
    end

    drop_if_exists index(:pollers, [:status])
    drop_if_exists index(:pollers, [:tenant_id, :status])
    drop_if_exists index(:checkers, [:status])
    drop_if_exists index(:checkers, [:tenant_id, :status])
    drop_if_exists index(:checkers, [:consecutive_failures])
  end
end
