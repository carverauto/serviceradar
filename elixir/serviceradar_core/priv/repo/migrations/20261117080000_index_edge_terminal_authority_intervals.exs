defmodule ServiceRadar.Repo.Migrations.IndexEdgeTerminalAuthorityIntervals do
  @moduledoc """
  A partial index over the authority intervals that ended `certificate_revoked` or
  `revoked_cause_unknown`. `ServiceRadar.Edge.RecordTrust` lists them in every trust document
  (the gateway's global snapshot and each agent's own), so the read touches only those rows
  instead of scanning the whole history (openspec add-edge-production-time-admission, task 2.6a).
  The history table is small (ordinary intervals are pruned after the late window), so a plain
  index build holds its lock briefly.
  """
  use Ecto.Migration

  def up do
    schema = prefix() || "platform"

    # Never queue behind a long transaction: fail fast and let the migration be retried.
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    CREATE INDEX IF NOT EXISTS edge_authority_history_terminal_idx
      ON #{schema}.edge_authority_history (agent_id)
      WHERE ended_reason IN ('certificate_revoked', 'revoked_cause_unknown')
    """)
  end

  def down do
    schema = prefix() || "platform"
    execute("DROP INDEX IF EXISTS #{schema}.edge_authority_history_terminal_idx")
  end
end
