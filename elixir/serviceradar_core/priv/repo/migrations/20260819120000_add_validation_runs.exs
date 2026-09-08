defmodule ServiceRadar.Repo.Migrations.AddValidationRuns do
  @moduledoc """
  NCO composite-check validation runs and per-device rows.
  """

  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS platform")

    create table(:validation_runs, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :check_slug, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :deadline_at, :utc_datetime_usec, null: false
      add :error, :text
      add :scan_run_ids, {:array, :uuid}, null: false, default: []
      add :requested_by, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :check_id,
          references(:composite_checks,
            column: :id,
            name: "validation_runs_check_id_fkey",
            type: :uuid,
            prefix: "platform",
            on_delete: :delete_all
          ),
          null: false
    end

    create index(:validation_runs, [:status],
             name: "validation_runs_status_idx",
             prefix: "platform"
           )

    create index(:validation_runs, [:inserted_at],
             name: "validation_runs_inserted_at_idx",
             prefix: "platform"
           )

    create table(:validation_run_devices, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :ip, :text, null: false
      add :partition, :text, null: false, default: "default"
      add :mac, :text
      add :device_uid, :text, null: false
      add :coverage, :map, null: false, default: %{}
      add :verdict, :text
      add :verdict_status, :text
      add :inputs, :map, null: false, default: %{}
      add :evaluated_at, :utc_datetime_usec
      add :error, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :run_id,
          references(:validation_runs,
            column: :id,
            name: "validation_run_devices_run_id_fkey",
            type: :uuid,
            prefix: "platform",
            on_delete: :delete_all
          ),
          null: false
    end

    create index(:validation_run_devices, [:run_id],
             name: "validation_run_devices_run_id_idx",
             prefix: "platform"
           )

    create index(:validation_run_devices, [:device_uid],
             name: "validation_run_devices_device_uid_idx",
             prefix: "platform"
           )
  end

  def down do
    drop_if_exists table(:validation_run_devices, prefix: "platform")
    drop_if_exists table(:validation_runs, prefix: "platform")
  end
end
