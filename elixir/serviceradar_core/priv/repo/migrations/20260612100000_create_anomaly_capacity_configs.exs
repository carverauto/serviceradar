defmodule ServiceRadar.Repo.Migrations.CreateAnomalyCapacityConfigs do
  @moduledoc false
  use Ecto.Migration

  def up do
    create table(:anomaly_detection_configs, primary_key: false, prefix: "platform") do
      add(:key, :text, primary_key: true, null: false, default: "default")
      add(:n_sigma, :float, null: false, default: 3.0)
      add(:window_size, :integer, null: false, default: 300)
      add(:window_duration_seconds, :integer, null: false, default: 900)
      add(:confirm_slots, :integer, null: false, default: 5)
      add(:min_samples, :integer, null: false, default: 30)

      add(:metric_class_overrides, :map,
        null: false,
        default:
          fragment("""
          '{"interface":{},"red":{},"cpu":{},"memory":{},"disk":{}}'::jsonb
          """)
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:anomaly_detection_configs, :anomaly_detection_configs_singleton_key,
        check: "key = 'default'",
        prefix: "platform"
      )
    )

    create(
      constraint(:anomaly_detection_configs, :anomaly_detection_configs_n_sigma_check,
        check: "n_sigma >= 0.1 AND n_sigma <= 20.0",
        prefix: "platform"
      )
    )

    create(
      constraint(:anomaly_detection_configs, :anomaly_detection_configs_window_check,
        check:
          "window_size >= 2 AND window_duration_seconds >= 1 AND min_samples >= 1 AND min_samples <= window_size",
        prefix: "platform"
      )
    )

    create(
      constraint(:anomaly_detection_configs, :anomaly_detection_configs_confirm_slots_check,
        check: "confirm_slots >= 1",
        prefix: "platform"
      )
    )

    create table(:capacity_forecast_configs, primary_key: false, prefix: "platform") do
      add(:key, :text, primary_key: true, null: false, default: "default")
      add(:forecast_horizon_seconds, :integer, null: false, default: 7_776_000)
      add(:warning_horizon_seconds, :integer, null: false, default: 2_592_000)
      add(:warning_threshold_percent, :float, null: false, default: 80.0)
      add(:model, :text, null: false, default: "linear")
      add(:minimum_history_points, :integer, null: false, default: 72)

      add(:metric_class_overrides, :map,
        null: false,
        default: fragment(~s('{"interface":{},"cpu":{},"memory":{},"disk":{}}'::jsonb))
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:capacity_forecast_configs, :capacity_forecast_configs_singleton_key,
        check: "key = 'default'",
        prefix: "platform"
      )
    )

    create(
      constraint(:capacity_forecast_configs, :capacity_forecast_configs_horizon_check,
        check:
          "forecast_horizon_seconds >= 3600 AND warning_horizon_seconds >= 3600 AND warning_horizon_seconds <= forecast_horizon_seconds",
        prefix: "platform"
      )
    )

    create(
      constraint(:capacity_forecast_configs, :capacity_forecast_configs_threshold_check,
        check: "warning_threshold_percent >= 1.0 AND warning_threshold_percent <= 100.0",
        prefix: "platform"
      )
    )

    create(
      constraint(:capacity_forecast_configs, :capacity_forecast_configs_model_check,
        check: "model IN ('linear', 'seasonal_linear', 'holt_winters')",
        prefix: "platform"
      )
    )

    create(
      constraint(:capacity_forecast_configs, :capacity_forecast_configs_history_check,
        check: "minimum_history_points >= 2",
        prefix: "platform"
      )
    )
  end

  def down do
    drop(table(:capacity_forecast_configs, prefix: "platform"))
    drop(table(:anomaly_detection_configs, prefix: "platform"))
  end
end
