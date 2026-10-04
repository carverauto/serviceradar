defmodule ServiceRadar.Repo.Migrations.KeepRolloutHistoryWhenAssignmentDeleted do
  @moduledoc """
  Lets an add-on assignment be deleted without deleting, or being blocked by,
  the rollout history that once targeted it.

  `addon_rollout_targets.assignment_id` was `NOT NULL ... ON DELETE RESTRICT`,
  so once any rollout had ever targeted an assignment, removing that assignment
  (or the profile that owns it) failed with an opaque foreign-key error. A
  target row already carries everything needed to render history without the
  assignment (`agent_uid`, `addon_id`, `source_type`, `source_id`, both package
  ids), so the pointer becomes nullable and is cleared on delete.

  Deleting an assignment that an active rollout still holds is refused before
  it reaches the database by the resource's destroy validation
  (`ServiceRadar.Plugins.Validations.NotHeldByActiveRollout`).
  """

  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE platform.addon_rollout_targets
    ALTER COLUMN assignment_id DROP NOT NULL
    """)

    execute("""
    ALTER TABLE platform.addon_rollout_targets
    DROP CONSTRAINT IF EXISTS addon_rollout_targets_assignment_id_fkey
    """)

    execute("""
    ALTER TABLE platform.addon_rollout_targets
    ADD CONSTRAINT addon_rollout_targets_assignment_id_fkey
    FOREIGN KEY (assignment_id)
    REFERENCES platform.addon_assignments(id)
    ON DELETE SET NULL
    """)
  end

  def down do
    execute("""
    ALTER TABLE platform.addon_rollout_targets
    DROP CONSTRAINT IF EXISTS addon_rollout_targets_assignment_id_fkey
    """)

    # serviceradar:allow-startup-maintenance: this DELETE runs only in `down`
    # (rollback, never the first-boot `up` path) and is bounded to target rows
    # whose assignment was deleted under ON DELETE SET NULL; those rows cannot
    # satisfy the restored NOT NULL constraint and there is no assignment to
    # point them back at, so they must be removed before re-adding NOT NULL.
    # Rows whose assignment was deleted under SET NULL cannot satisfy the old
    # NOT NULL constraint; there is no assignment to point them back at.
    execute("""
    DELETE FROM platform.addon_rollout_targets WHERE assignment_id IS NULL
    """)

    execute("""
    ALTER TABLE platform.addon_rollout_targets
    ALTER COLUMN assignment_id SET NOT NULL
    """)

    execute("""
    ALTER TABLE platform.addon_rollout_targets
    ADD CONSTRAINT addon_rollout_targets_assignment_id_fkey
    FOREIGN KEY (assignment_id)
    REFERENCES platform.addon_assignments(id)
    ON DELETE RESTRICT
    """)
  end
end
