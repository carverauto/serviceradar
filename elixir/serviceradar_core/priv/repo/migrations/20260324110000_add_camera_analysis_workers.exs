defmodule ServiceRadar.Repo.Migrations.AddCameraAnalysisWorkers do
  @moduledoc """
  Adds a platform-owned registry of camera analysis workers.
  """

  use Ecto.Migration

  def up do
    create table(:camera_analysis_workers, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :worker_id, :text, null: false
      add :display_name, :text
      add :adapter, :text, null: false, default: "http"
      add :endpoint_url, :text, null: false
      add :capabilities, {:array, :text}, null: false, default: []
      add :enabled, :boolean, null: false, default: true
      add :headers, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:camera_analysis_workers, [:worker_id],
             prefix: "platform",
             name: "camera_analysis_workers_worker_id_uidx"
           )

    create index(:camera_analysis_workers, [:enabled],
             prefix: "platform",
             name: "camera_analysis_workers_enabled_idx"
           )

    create index(:camera_analysis_workers, [:adapter],
             prefix: "platform",
             name: "camera_analysis_workers_adapter_idx"
           )

    create index(:camera_analysis_workers, [:capabilities],
             prefix: "platform",
             using: "GIN",
             name: "camera_analysis_workers_capabilities_gin_idx"
           )
  end

  def down do
    drop_if_exists index(:camera_analysis_workers, [:capabilities],
                     prefix: "platform",
                     name: "camera_analysis_workers_capabilities_gin_idx"
                   )

    drop_if_exists index(:camera_analysis_workers, [:adapter],
                     prefix: "platform",
                     name: "camera_analysis_workers_adapter_idx"
                   )

    drop_if_exists index(:camera_analysis_workers, [:enabled],
                     prefix: "platform",
                     name: "camera_analysis_workers_enabled_idx"
                   )

    drop_if_exists unique_index(:camera_analysis_workers, [:worker_id],
                     prefix: "platform",
                     name: "camera_analysis_workers_worker_id_uidx"
                   )

    drop_if_exists table(:camera_analysis_workers, prefix: "platform")
  end
end
