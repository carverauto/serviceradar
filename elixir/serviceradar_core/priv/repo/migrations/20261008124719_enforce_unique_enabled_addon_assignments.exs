defmodule ServiceRadar.Repo.Migrations.EnforceUniqueEnabledAddonAssignments do
  @moduledoc """
  Preserve the assignment already selected for delivery, then enforce one
  enabled assignment per agent and logical add-on across every source.

  Shadowed rows are disabled, never deleted, preserving assignment references
  and rollout history. Active rollout work on a shadowed row is canceled the way
  an operator cancel would: its open targets are canceled with reason
  `assignment_deduplicated`, its rollout override is cleared, and a rollout
  sourced from it is canceled. A refusal here could not be cleared by hand,
  because rollout reconciliation restarts a canceled `track_latest` rollout
  within seconds. Completed rollouts' targets stay as history.
  The table locks and index are committed together, so concurrent writers cannot
  recreate duplicates between cleanup and installing the constraint.
  """

  use Ecto.Migration

  @active_rollout_states "('pending', 'running', 'paused', 'rolling_back')"
  # The states addon_rollout_targets_one_active_target_index treats as active.
  @open_target_states "('pending', 'waiting_health', 'healthy_soak', 'rollback_pending', 'succeeded')"

  def up do
    # serviceradar:allow-startup-maintenance - schema-critical bounded cleanup before adding
    # the partial unique index; without it index creation fails on existing duplicates, and
    # the cleanup must commit in the same migration with the table lock so concurrent writers
    # cannot recreate duplicates between cleanup and installing the constraint.
    # platform.addon_assignments is a small control-plane table (not a hypertable). Only rows
    # sharing an (agent_uid, addon_id) key with more than one enabled assignment are disabled
    # (never deleted, preserving assignment references and completed rollout history), plus a
    # canonicalization UPDATE limited to rows whose denormalized addon_id is distinct from
    # their package. Shadowed rows are ranked once into a temporary table, so clearing their
    # rollout overrides cannot change the ranking used by later statements. Active rollout
    # work on those rows is canceled. Every statement is idempotent, and a re-query refuses to
    # converge if any duplicate enabled key remains.
    Enum.each(cleanup_statements(), &execute/1)

    create unique_index(:addon_assignments, [:agent_uid, :addon_id],
             name: :addon_assignments_one_enabled_per_agent_addon_index,
             where: "enabled = true",
             prefix: "platform"
           )

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM platform.addon_assignments WHERE enabled
        GROUP BY agent_uid, addon_id HAVING count(*) > 1
        ) THEN
          RAISE EXCEPTION 'Enabled add-on assignment deduplication did not converge';
        END IF;
    END;
    $$
    """)
  end

  def down do
    drop index(:addon_assignments, [:agent_uid, :addon_id],
           name: :addon_assignments_one_enabled_per_agent_addon_index,
           prefix: "platform"
         )
  end

  @doc false
  def cleanup_statements do
    [
      "LOCK TABLE platform.addon_assignments, platform.addon_rollout_targets, platform.addon_rollouts IN SHARE ROW EXCLUSIVE MODE",

      # Package identity is authoritative, including for old rows written before
      # the atomic SetAssignmentAddonId change maintained the denormalized key.
      """
      UPDATE platform.addon_assignments AS assignment
      SET addon_id = package.addon_id
      FROM platform.addon_packages AS package
      WHERE package.id = assignment.addon_package_id
        AND assignment.addon_id IS DISTINCT FROM package.addon_id
      """,

      "DROP TABLE IF EXISTS pg_temp.addon_assignment_dedupe_losers",
      """
      CREATE TEMP TABLE addon_assignment_dedupe_losers ON COMMIT DROP AS
      #{ranked_sql()}
      SELECT id FROM ranked WHERE position > 1
      """,

      # Cancel open targets on shadowed rows, and every open target of a rollout
      # sourced from a shadowed row, but only while that rollout is active.
      """
      UPDATE platform.addon_rollout_targets AS target
      SET state = 'canceled', reason_code = 'assignment_deduplicated',
          completed_at = now() AT TIME ZONE 'utc', updated_at = now() AT TIME ZONE 'utc'
      FROM platform.addon_rollouts AS rollout
      WHERE rollout.id = target.rollout_id
        AND rollout.state IN #{@active_rollout_states}
        AND target.state IN #{@open_target_states}
        AND (
          target.assignment_id IN (SELECT id FROM addon_assignment_dedupe_losers)
          OR (rollout.source_type = 'assignment'
              AND rollout.source_id IN (SELECT id FROM addon_assignment_dedupe_losers))
        )
      """,
      """
      UPDATE platform.addon_rollouts AS rollout
      SET state = 'canceled', blocked_reason = 'source_assignment_deduplicated',
          canceled_at = now() AT TIME ZONE 'utc', updated_at = now() AT TIME ZONE 'utc'
      WHERE rollout.source_type = 'assignment'
        AND rollout.state IN #{@active_rollout_states}
        AND rollout.source_id IN (SELECT id FROM addon_assignment_dedupe_losers)
      """,
      """
      UPDATE platform.addon_assignments AS assignment
      SET rollout_package_id = NULL, rollout_id = NULL, rollout_started_at = NULL
      WHERE assignment.rollout_id IS NOT NULL
        AND assignment.id IN (SELECT id FROM addon_assignment_dedupe_losers)
      """,
      """
      UPDATE platform.addon_assignments AS assignment
      SET enabled = false
      WHERE assignment.id IN (SELECT id FROM addon_assignment_dedupe_losers)
      """
    ]
  end

  defp ranked_sql do
    """
    WITH ranked AS (
      SELECT assignment.id,
             row_number() OVER (
               PARTITION BY assignment.agent_uid, assignment.addon_id
               ORDER BY
                 CASE WHEN package.status = 'approved'
                       AND package.verification_status IS DISTINCT FROM 'blob_missing'
                      THEN 0 ELSE 1 END,
                 CASE assignment.source WHEN 'manual' THEN 0 WHEN 'profile' THEN 1 ELSE 2 END,
                 CASE WHEN assignment.source = 'profile'
                           AND jsonb_typeof(assignment.profile_metadata->'priority') = 'number'
                           AND (assignment.profile_metadata->>'priority') ~ '^-?[0-9]+$'
                      THEN (assignment.profile_metadata->>'priority')::numeric
                      WHEN assignment.source = 'profile' THEN 100 ELSE 0 END,
                 COALESCE(assignment.updated_at, assignment.inserted_at) DESC,
                 assignment.id ASC
             ) AS position
      FROM platform.addon_assignments AS assignment
      JOIN platform.addon_packages AS package
        ON package.id = CASE WHEN assignment.rollout_id IS NOT NULL
                             THEN COALESCE(assignment.rollout_package_id, assignment.addon_package_id)
                             ELSE assignment.addon_package_id END
      WHERE assignment.enabled
    )
    """
  end
end
