defmodule ServiceRadar.Repo.Migrations.CreateSyncIngestRuns do
  use Ecto.Migration

  def change do
    create table(:sync_ingest_runs, primary_key: false, prefix: "platform") do
      add :sync_service_id, references(:integration_sources, type: :uuid, prefix: "platform",
                                       on_delete: :delete_all), primary_key: true, null: false
      add :sync_run_id, :text, primary_key: true, null: false
      add :received_chunks, {:array, :integer}, null: false, default: []
      add :total_chunks, :integer, null: false, default: 0
      add :incomplete, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end
    create index(:sync_ingest_runs, [:updated_at], prefix: "platform")
  end
end
