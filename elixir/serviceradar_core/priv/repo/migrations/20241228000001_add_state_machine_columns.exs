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
    ALTER TABLE IF EXISTS pollers
    ALTER COLUMN status SET DEFAULT 'inactive';
    """

    execute """
    DO $$
    BEGIN
      IF to_regclass('public.pollers') IS NOT NULL THEN
        UPDATE pollers
        SET status = CASE status
          WHEN 'active' THEN 'healthy'
          WHEN 'inactive' THEN 'inactive'
          WHEN 'degraded' THEN 'degraded'
          ELSE 'inactive'
        END
        WHERE status NOT IN ('healthy', 'degraded', 'offline', 'recovering', 'maintenance', 'draining', 'inactive');
      END IF;
    END
    $$;
    """

    # Add new columns to checkers table
    execute """
    ALTER TABLE IF EXISTS checkers
      ADD COLUMN IF NOT EXISTS status text DEFAULT 'active',
      ADD COLUMN IF NOT EXISTS consecutive_failures integer DEFAULT 0,
      ADD COLUMN IF NOT EXISTS last_success timestamptz,
      ADD COLUMN IF NOT EXISTS last_failure timestamptz,
      ADD COLUMN IF NOT EXISTS failure_reason text;
    """

    # Create index for status-based queries
    execute """
    DO $$
    BEGIN
      IF to_regclass('public.pollers') IS NOT NULL THEN
        CREATE INDEX IF NOT EXISTS pollers_status_index ON pollers (status);
        CREATE INDEX IF NOT EXISTS pollers_tenant_id_status_index ON pollers (tenant_id, status);
      END IF;
      IF to_regclass('public.checkers') IS NOT NULL THEN
        CREATE INDEX IF NOT EXISTS checkers_status_index ON checkers (status);
        CREATE INDEX IF NOT EXISTS checkers_tenant_id_status_index ON checkers (tenant_id, status);
        CREATE INDEX IF NOT EXISTS checkers_consecutive_failures_index ON checkers (consecutive_failures);
      END IF;
    END
    $$;
    """
  end

  def down do
    # Revert pollers status to old values
    execute """
    DO $$
    BEGIN
      IF to_regclass('public.pollers') IS NOT NULL THEN
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
      END IF;
    END
    $$;
    """

    execute """
    ALTER TABLE IF EXISTS pollers
    ALTER COLUMN status SET DEFAULT 'active';
    """

    # Remove checker columns
    execute """
    ALTER TABLE IF EXISTS checkers
      DROP COLUMN IF EXISTS status,
      DROP COLUMN IF EXISTS consecutive_failures,
      DROP COLUMN IF EXISTS last_success,
      DROP COLUMN IF EXISTS last_failure,
      DROP COLUMN IF EXISTS failure_reason;
    """

    drop_if_exists index(:pollers, [:status])
    drop_if_exists index(:pollers, [:tenant_id, :status])
    drop_if_exists index(:checkers, [:status])
    drop_if_exists index(:checkers, [:tenant_id, :status])
    drop_if_exists index(:checkers, [:consecutive_failures])
  end
end
