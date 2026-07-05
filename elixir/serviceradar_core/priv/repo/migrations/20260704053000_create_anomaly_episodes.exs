defmodule ServiceRadar.Repo.Migrations.CreateAnomalyEpisodes do
  @moduledoc """
  Creates the bounded current-state table for anomaly episodes.
  """

  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS platform")

    create table(:anomaly_episodes, primary_key: false, prefix: "platform") do
      add :episode_uid, :text, null: false, primary_key: true
      add :finding_uid, :text, null: false
      add :device_uid, :text, null: false
      add :series_key, :text, null: false
      add :metric_name, :text
      add :if_index, :bigint
      add :metric_class, :text
      add :detector, :text, null: false
      add :status, :text, null: false, default: "open"
      add :severity_id, :bigint, null: false, default: 1
      add :peak_severity_id, :bigint, null: false, default: 1
      add :effect_size, :float
      add :peak_score, :float
      add :opened_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :cleared_at, :utc_datetime_usec
      add :clear_reason, :text
      add :occurrence_count, :bigint, null: false, default: 1
      add :reopen_count, :bigint, null: false, default: 0
      add :producer_version, :text
      add :last_transition, :text
      add :last_payload, :map, null: false, default: %{}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create constraint(:anomaly_episodes, :anomaly_episodes_status_check,
             check: "status IN ('open', 'cleared', 'stale_closed')",
             prefix: "platform"
           )

    create constraint(:anomaly_episodes, :anomaly_episodes_severity_check,
             check:
               "severity_id BETWEEN 0 AND 5 AND peak_severity_id BETWEEN 0 AND 5 AND peak_severity_id >= severity_id",
             prefix: "platform"
           )

    create constraint(:anomaly_episodes, :anomaly_episodes_counts_check,
             check: "occurrence_count >= 1 AND reopen_count >= 0",
             prefix: "platform"
           )

    create constraint(:anomaly_episodes, :anomaly_episodes_if_index_check,
             check: "if_index IS NULL OR if_index > 0",
             prefix: "platform"
           )

    create constraint(:anomaly_episodes, :anomaly_episodes_clear_time_check,
             check:
               "(status = 'open' AND cleared_at IS NULL) OR (status <> 'open' AND cleared_at IS NOT NULL)",
             prefix: "platform"
           )

    create unique_index(:anomaly_episodes, [:episode_uid],
             name: :anomaly_episodes_unique_episode_index,
             prefix: "platform"
           )

    execute("""
    CREATE INDEX idx_anomaly_episodes_device_status_seen
    ON platform.anomaly_episodes (device_uid, status, last_seen_at DESC)
    """)

    execute("""
    CREATE INDEX idx_anomaly_episodes_finding_status_seen
    ON platform.anomaly_episodes (finding_uid, status, last_seen_at DESC)
    """)

    execute("""
    CREATE INDEX idx_anomaly_episodes_series_status_seen
    ON platform.anomaly_episodes (series_key, status, last_seen_at DESC)
    """)

    execute("""
    CREATE INDEX idx_anomaly_episodes_open_last_seen
    ON platform.anomaly_episodes (last_seen_at DESC)
    WHERE status = 'open'
    """)
  end

  def down do
    drop table(:anomaly_episodes, prefix: "platform")
  end
end
