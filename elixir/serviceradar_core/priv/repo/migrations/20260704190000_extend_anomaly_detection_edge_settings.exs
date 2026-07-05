defmodule ServiceRadar.Repo.Migrations.ExtendAnomalyDetectionEdgeSettings do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE platform.anomaly_detection_configs
      ADD COLUMN metric_denylist text[] NOT NULL DEFAULT ARRAY['cpu.frequency_hz']::text[]
    """)

    execute("""
    ALTER TABLE platform.anomaly_detection_configs
      ADD COLUMN emission jsonb NOT NULL DEFAULT '{
        "cooldown_secs": 300,
        "budget_per_tick": 100,
        "episode_update_interval_secs": 1800,
        "reopen_cooldown_secs": 600
      }'::jsonb
    """)
  end

  def down do
    alter table(:anomaly_detection_configs, prefix: "platform") do
      remove :emission
      remove :metric_denylist
    end
  end
end
