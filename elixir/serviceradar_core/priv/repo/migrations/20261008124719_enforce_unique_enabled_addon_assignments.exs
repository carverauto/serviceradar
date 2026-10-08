defmodule ServiceRadar.Repo.Migrations.EnforceUniqueEnabledAddonAssignments do
  @moduledoc """
  Preserve the assignment already selected for delivery, then enforce one
  enabled assignment per agent and logical add-on across every source.

  Shadowed rows are disabled, never deleted, preserving assignment references
  and rollout history. A shadowed assignment participating in an active rollout
  requires that rollout to be resolved first; cleanup does not bypass its owner.
  The table locks and index are committed together, so concurrent writers cannot
  recreate duplicates between cleanup and installing the constraint.
  """

  use Ecto.Migration

  def up do
    # serviceradar:allow-startup-maintenance - schema-critical bounded cleanup before adding
    # the partial unique index; without it index creation fails on existing duplicates, and
    # the cleanup must commit in the same migration with the table lock so concurrent writers
    # cannot recreate duplicates between cleanup and installing the constraint.
    # platform.addon_assignments is a small control-plane table (not a hypertable). Only rows
    # sharing an (agent_uid, addon_id) key with more than one enabled assignment are disabled
    # (never deleted, preserving assignment references and completed rollout history), plus a
    # canonicalization UPDATE limited to rows whose denormalized addon_id is distinct from
    # their package. Both statements are idempotent single statements, fail closed by raising
    # when a shadowed row is owned by an active rollout, and are followed by a re-query that
    # refuses to converge if any duplicate enabled key remains.
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

      """
      DO $$
      BEGIN
        IF EXISTS (
        #{ranked_sql()}
        SELECT 1 FROM ranked AS loser
        JOIN platform.addon_assignments AS assignment ON assignment.id = loser.id
        WHERE loser.position > 1
          AND (
            assignment.rollout_id IS NOT NULL
            OR EXISTS (
              SELECT 1 FROM platform.addon_rollout_targets AS target
              JOIN platform.addon_rollouts AS target_rollout ON target_rollout.id = target.rollout_id
              WHERE target.assignment_id = assignment.id
                AND target_rollout.state IN ('pending', 'running', 'paused', 'rolling_back')
                AND target.state IN ('pending', 'waiting_health', 'healthy_soak', 'rollback_pending', 'succeeded')
            )
            OR EXISTS (
              SELECT 1 FROM platform.addon_rollouts AS rollout
              WHERE rollout.source_type = 'assignment' AND rollout.source_id = assignment.id
                AND rollout.state IN ('pending', 'running', 'paused', 'rolling_back')
            )
          )
        ) THEN
          RAISE EXCEPTION 'Resolve active rollouts on shadowed add-on assignments before deduplication';
        END IF;
      END;
      $$
      """,

      """
      #{ranked_sql()}
      UPDATE platform.addon_assignments AS assignment
      SET enabled = false
      FROM ranked AS loser
      WHERE assignment.id = loser.id AND loser.position > 1
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
