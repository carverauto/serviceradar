defmodule ServiceRadar.Repo.Migrations.AddNorthboundFieldsToIntegrationSources do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:integration_sources, prefix: "platform") do
      add :northbound_enabled, :boolean, default: false, null: false
      add :northbound_interval_seconds, :bigint, default: 3600, null: false
      add :northbound_last_run_at, :utc_datetime
      add :northbound_last_result, :text
      add :northbound_last_device_count, :bigint, default: 0, null: false
      add :northbound_last_updated_count, :bigint, default: 0, null: false
      add :northbound_last_skipped_count, :bigint, default: 0, null: false
      add :northbound_last_error_message, :text
      add :northbound_status, :text, default: "idle", null: false
      add :northbound_consecutive_failures, :bigint, default: 0, null: false
    end

    create index(:integration_sources, [:northbound_enabled], prefix: "platform")

    create index(:integration_sources, [:northbound_status],
             prefix: "platform",
             name: "integration_sources_northbound_status_idx"
           )

    create index(:integration_sources, [:northbound_last_run_at],
             prefix: "platform",
             name: "integration_sources_northbound_last_run_at_idx"
           )
  end
end
