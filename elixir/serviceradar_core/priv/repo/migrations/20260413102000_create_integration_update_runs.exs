defmodule ServiceRadar.Repo.Migrations.CreateIntegrationUpdateRuns do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:integration_update_runs, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :integration_source_id,
          references(:integration_sources,
            column: :id,
            type: :uuid,
            prefix: "platform",
            on_delete: :delete_all
          ),
          null: false

      add :run_type, :text, null: false
      add :status, :text, null: false, default: "running"
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :device_count, :bigint, null: false, default: 0
      add :updated_count, :bigint, null: false, default: 0
      add :skipped_count, :bigint, null: false, default: 0
      add :error_count, :bigint, null: false, default: 0
      add :error_message, :text
      add :oban_job_id, :bigint
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:integration_update_runs, [:integration_source_id], prefix: "platform")

    create index(:integration_update_runs, [:integration_source_id, :inserted_at],
             prefix: "platform",
             name: "integration_update_runs_source_inserted_at_idx"
           )

    create index(:integration_update_runs, [:integration_source_id, :started_at],
             prefix: "platform",
             name: "integration_update_runs_source_started_at_idx"
           )

    create index(:integration_update_runs, [:run_type, :status],
             prefix: "platform",
             name: "integration_update_runs_type_status_idx"
           )

    create unique_index(:integration_update_runs, [:oban_job_id],
             prefix: "platform",
             name: "integration_update_runs_oban_job_id_uidx",
             where: "oban_job_id IS NOT NULL"
           )

    create constraint(:integration_update_runs, :integration_update_runs_count_consistency,
             check: "device_count >= updated_count + skipped_count + error_count",
             prefix: "platform"
           )
  end
end
