defmodule ServiceRadar.Repo.Migrations.CreateThreatIntelSyncStatuses do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:threat_intel_sync_statuses, primary_key: false, prefix: "platform") do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :provider, :text, null: false
      add :source, :text, null: false
      add :collection_id, :text, null: false, default: ""
      add :agent_id, :text, null: false, default: ""
      add :gateway_id, :text, null: false, default: ""
      add :plugin_id, :text, null: false, default: ""

      add :execution_mode, :text, null: false, default: "edge_plugin"
      add :last_status, :text, null: false, default: "unknown"
      add :last_message, :text
      add :last_error, :text
      add :last_attempt_at, :utc_datetime_usec, null: false
      add :last_success_at, :utc_datetime_usec
      add :last_failure_at, :utc_datetime_usec

      add :objects_count, :integer, null: false, default: 0
      add :indicators_count, :integer, null: false, default: 0
      add :skipped_count, :integer, null: false, default: 0
      add :total_count, :integer, null: false, default: 0
      add :cursor, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:threat_intel_sync_statuses, [:source], prefix: "platform")
    create index(:threat_intel_sync_statuses, [:provider], prefix: "platform")
    create index(:threat_intel_sync_statuses, [:last_status], prefix: "platform")
    create index(:threat_intel_sync_statuses, [:last_attempt_at], prefix: "platform")

    create unique_index(
             :threat_intel_sync_statuses,
             [:source, :collection_id, :agent_id, :gateway_id, :plugin_id],
             prefix: "platform",
             name: "threat_intel_sync_statuses_identity_uidx"
           )
  end
end
