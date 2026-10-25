defmodule ServiceRadar.Repo.Migrations.KeyEnabledPluginAssignmentsPerOwner do
  @moduledoc """
  Keys the one-enabled-assignment index per owner.

  `plugin_assignments_one_enabled_per_edge_plugin_index` allowed one enabled
  assignment per `(partition_id, agent_uid, plugin_id)`. Assignments owned by
  different credential rules are allowed to coexist on one agent (for example
  one agent bridging two controllers of the same kind with different tokens),
  so the index now also includes an owner key derived from `policy_id` the way
  `ServiceRadar.Plugins.AssignmentOwner.owner/1` derives it:

    * the credential rule id for `network-credential-rule:<rule id>[:<suffix>]`;
    * an empty string for every other owner (manual rows and other policy ids),
      which therefore still share one enabled assignment per plugin and agent.

  Both sides trim surrounding whitespace before matching; keep them identical.
  A manual or non-rule policy row next to a rule-owned row is still refused,
  by `NoDuplicateEnabledAssignment` only: a unique index cannot express that
  pairing.

  `plugin_assignments` holds a few rows per agent, so the index is built inside
  the migration transaction. The new index is created before the old one is
  dropped, and the existing rows already satisfy it because the old index was
  stricter.

  Rolling back fails while two owners hold enabled assignments of one plugin on
  one agent; disable one of them first.
  """

  use Ecto.Migration

  @prefix "platform"
  @old_index "plugin_assignments_one_enabled_per_edge_plugin_index"
  @new_index "plugin_assignments_one_enabled_per_edge_plugin_owner_index"

  @owner_key """
  COALESCE(
    substring(
      regexp_replace(policy_id, '^[[:space:]]+|[[:space:]]+$', '', 'g')
      FROM '^network-credential-rule:([^:]+)'
    ),
    ''
  )
  """

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS #{@new_index}
    ON #{@prefix}.plugin_assignments (partition_id, agent_uid, plugin_id, (#{@owner_key}))
    WHERE enabled = true
    """)

    execute("DROP INDEX IF EXISTS #{@prefix}.#{@old_index}")
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS #{@old_index}
    ON #{@prefix}.plugin_assignments (partition_id, agent_uid, plugin_id)
    WHERE enabled = true
    """)

    execute("DROP INDEX IF EXISTS #{@prefix}.#{@new_index}")
  end
end
