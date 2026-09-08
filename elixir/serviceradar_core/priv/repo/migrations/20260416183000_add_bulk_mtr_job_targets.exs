defmodule ServiceRadar.Repo.Migrations.AddBulkMtrJobTargets do
  @moduledoc """
  Adds persisted bulk MTR target state and command progress payloads.
  """

  use Ecto.Migration

  def up do
    alter table(:agent_commands, prefix: "platform") do
      add(:progress_payload, :map)
    end

    create table(:mtr_bulk_job_targets, primary_key: false, prefix: "platform") do
      add(:id, :uuid,
        null: false,
        default: fragment("gen_random_uuid()"),
        primary_key: true
      )

      add(
        :command_id,
        references(:agent_commands,
          column: :command_id,
          type: :uuid,
          on_delete: :delete_all,
          prefix: "platform"
        ),
        null: false
      )

      add(:target, :text, null: false)
      add(:status, :text, null: false, default: "queued")
      add(:trace_id, :uuid)
      add(:result_payload, :map)
      add(:error, :text)
      add(:attempt_count, :integer, null: false, default: 0)
      add(:started_at, :utc_datetime)
      add(:completed_at, :utc_datetime)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(unique_index(:mtr_bulk_job_targets, [:command_id, :target], prefix: "platform"))
    create(index(:mtr_bulk_job_targets, [:command_id, :status], prefix: "platform"))
  end

  def down do
    drop(table(:mtr_bulk_job_targets, prefix: "platform"))

    alter table(:agent_commands, prefix: "platform") do
      remove(:progress_payload)
    end
  end
end
