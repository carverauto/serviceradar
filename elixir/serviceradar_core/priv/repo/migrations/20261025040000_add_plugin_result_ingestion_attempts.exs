defmodule ServiceRadar.Repo.Migrations.AddPluginResultIngestionAttempts do
  @moduledoc """
  Adds `platform.plugin_result_ingestion_attempts` for durable per-observation
  retained plugin result ingestion attempt tracking and quarantine.
  """
  use Ecto.Migration

  @prefix "platform"

  def change do
    create table(:plugin_result_ingestion_attempts, primary_key: false, prefix: @prefix) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")
      add :agent_id, :text, null: false
      add :result_key, :text, null: false
      add :gateway_id, :text
      add :partition, :text, null: false, default: "default"
      add :service_type, :text, null: false, default: "plugin"
      add :service_name, :text, null: false, default: "unknown"
      add :observation_timestamp, :utc_datetime_usec, null: false
      add :payload_digest, :text, null: false
      add :payload_bytes, :integer, null: false, default: 0
      add :attempt_count, :integer, null: false, default: 0
      add :consecutive_timeout_count, :integer, null: false, default: 0
      add :state, :text, null: false, default: "active"
      add :last_outcome, :text
      add :last_error, :text
      add :quarantine_reason, :text
      add :quarantined_at, :utc_datetime_usec
      add :last_attempt_at, :utc_datetime_usec, null: false
      add :retained_status, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:plugin_result_ingestion_attempts, [:agent_id, :result_key],
             prefix: @prefix,
             name: :plugin_result_ingestion_attempts_agent_result_uidx
           )

    create index(:plugin_result_ingestion_attempts, [:state, :quarantined_at],
             prefix: @prefix,
             name: :plugin_result_ingestion_attempts_quarantined_idx
           )

    create index(:plugin_result_ingestion_attempts, [:agent_id, :state],
             prefix: @prefix,
             name: :plugin_result_ingestion_attempts_agent_state_idx
           )
  end
end
