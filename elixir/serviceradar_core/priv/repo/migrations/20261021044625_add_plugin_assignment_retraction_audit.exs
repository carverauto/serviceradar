defmodule ServiceRadar.Repo.Migrations.AddPluginAssignmentRetractionAudit do
  @moduledoc """
  Records why a plugin assignment was disabled and by whom.

  An assignment owned by a credential rule or a plugin target policy is
  disabled when its owner is disabled, deleted, or narrowed so the agent is no
  longer covered, and when an operator retracts an assignment whose owner had
  already gone. These columns hold the reason code, the acting operator and the
  time. They are nullable with no default, so adding them changes only the
  catalog, and no existing row is rewritten.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    ALTER TABLE #{@prefix}.plugin_assignments
      ADD COLUMN IF NOT EXISTS disabled_reason text,
      ADD COLUMN IF NOT EXISTS disabled_by text,
      ADD COLUMN IF NOT EXISTS disabled_at timestamptz
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    ALTER TABLE #{@prefix}.plugin_assignments
      DROP COLUMN IF EXISTS disabled_at,
      DROP COLUMN IF EXISTS disabled_by,
      DROP COLUMN IF EXISTS disabled_reason
    """)
  end
end
