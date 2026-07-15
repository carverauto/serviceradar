defmodule ServiceRadar.Repo.Migrations.CreatePluginAssignmentRecoveryAudits do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:plugin_assignment_recovery_audits, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:legacy_assignment_id, :uuid, null: false)
      add(:replacement_assignment_id, :uuid)
      add(:actor_id, :text, null: false)
      add(:actor_type, :text, null: false)
      add(:agent_uid, :text, null: false)
      add(:authenticated_agent_id, :text)
      add(:authenticated_partition_id, :text)
      add(:outcome, :text, null: false)
      add(:reason, :text, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      index(:plugin_assignment_recovery_audits, [:legacy_assignment_id, :occurred_at],
        prefix: @prefix,
        name: :plugin_assignment_recovery_audits_legacy_time_idx
      )
    )

    create(
      unique_index(:plugin_assignment_recovery_audits, [:legacy_assignment_id],
        prefix: @prefix,
        name: :plugin_assignment_recovery_audits_one_recovered_idx,
        where: "outcome = 'recovered'"
      )
    )
  end

  def down do
    drop(table(:plugin_assignment_recovery_audits, prefix: @prefix))
  end
end
