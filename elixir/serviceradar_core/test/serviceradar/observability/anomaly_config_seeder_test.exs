defmodule ServiceRadar.Observability.AnomalyConfigSeederTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.AnomalyConfigSeeder

  @moduletag :requires_app

  test "anomaly seed attrs default to the Helm-backed first-boot values" do
    attrs = AnomalyConfigSeeder.anomaly_attrs_from_env(fn _ -> nil end)

    assert attrs.n_sigma == 3.0
    assert attrs.window_size == 300
    assert attrs.window_duration_seconds == 900
    assert attrs.confirm_slots == 5
    assert attrs.min_samples == 30

    assert attrs.metric_class_overrides |> Map.keys() |> Enum.sort() ==
             ["cpu", "disk", "icmp", "interface", "memory", "other", "red"]

    assert attrs.metric_class_overrides["interface"]["drift_mode"] == "deseasonalized_only"
    assert attrs.metric_denylist == ["cpu.frequency_hz"]

    assert attrs.emission == %{
             "cooldown_secs" => 300,
             "budget_per_tick" => 100,
             "episode_update_interval_secs" => 1_800,
             "reopen_cooldown_secs" => 600
           }
  end

  test "anomaly seed attrs parse Helm-rendered env values" do
    env = %{
      "SERVICERADAR_ANOMALY_N_SIGMA" => "4.5",
      "SERVICERADAR_ANOMALY_WINDOW_SIZE" => "600",
      "SERVICERADAR_ANOMALY_WINDOW_DURATION_SECONDS" => "1800",
      "SERVICERADAR_ANOMALY_CONFIRM_SLOTS" => "7",
      "SERVICERADAR_ANOMALY_MIN_SAMPLES" => "45",
      "SERVICERADAR_ANOMALY_METRIC_CLASS_OVERRIDES_JSON" =>
        ~s({"interface":{"drift_mode":"deseasonalized_only","drift_min_effect":2.5}}),
      "SERVICERADAR_ANOMALY_METRIC_DENYLIST_JSON" =>
        ~s(["cpu.frequency_hz"," custom.metric ","custom.metric"]),
      "SERVICERADAR_ANOMALY_EMISSION_JSON" =>
        ~s({"cooldown_secs":120,"budget_per_tick":25,"episode_update_interval_secs":900,"reopen_cooldown_secs":300})
    }

    attrs = AnomalyConfigSeeder.anomaly_attrs_from_env(&Map.get(env, &1))

    assert attrs.n_sigma == 4.5
    assert attrs.window_size == 600
    assert attrs.window_duration_seconds == 1800
    assert attrs.confirm_slots == 7
    assert attrs.min_samples == 45
    assert attrs.metric_class_overrides["interface"]["drift_min_effect"] == 2.5
    assert attrs.metric_denylist == ["cpu.frequency_hz", "custom.metric"]
    assert attrs.emission["cooldown_secs"] == 120
    assert attrs.emission["budget_per_tick"] == 25
  end

  test "forecast seed attrs parse Helm-rendered env values" do
    env = %{
      "SERVICERADAR_CAPACITY_FORECAST_CONFIG_HORIZON_SECONDS" => "15552000",
      "SERVICERADAR_CAPACITY_FORECAST_CONFIG_WARNING_HORIZON_SECONDS" => "604800",
      "SERVICERADAR_CAPACITY_FORECAST_CONFIG_WARNING_THRESHOLD_PERCENT" => "90.0",
      "SERVICERADAR_CAPACITY_FORECAST_CONFIG_MODEL" => "seasonal_linear",
      "SERVICERADAR_CAPACITY_FORECAST_CONFIG_MINIMUM_HISTORY_POINTS" => "168",
      "SERVICERADAR_CAPACITY_FORECAST_CONFIG_METRIC_CLASS_OVERRIDES_JSON" =>
        ~s({"disk":{"warning_threshold_percent":85.0}})
    }

    attrs = AnomalyConfigSeeder.forecast_attrs_from_env(&Map.get(env, &1))

    assert attrs.forecast_horizon_seconds == 15_552_000
    assert attrs.warning_horizon_seconds == 604_800
    assert attrs.warning_threshold_percent == 90.0
    assert attrs.model == :seasonal_linear
    assert attrs.minimum_history_points == 168
    assert attrs.metric_class_overrides["disk"]["warning_threshold_percent"] == 85.0
  end

  test "forecast seed attrs parse comma-separated source opt-ins" do
    env = %{
      "SERVICERADAR_CAPACITY_FORECASTING_SOURCE_OPT_INS" =>
        "cpu_usage, interface_rate,,cpu_usage,bogus_source,memory_usage"
    }

    attrs = AnomalyConfigSeeder.forecast_attrs_from_env(&Map.get(env, &1))

    # memory_usage forecasts by default and bogus_source is unknown; only the
    # resource's allowed opt-ins survive so first-boot creation cannot fail.
    assert attrs.default_source_opt_ins == ["cpu_usage", "interface_rate"]
  end

  test "absent source opt-in env seeds an empty opt-in list" do
    attrs = AnomalyConfigSeeder.forecast_attrs_from_env(fn _ -> nil end)

    assert attrs.default_source_opt_ins == []
  end

  test "empty JSON map env values seed the code defaults instead of empty maps" do
    env = %{
      "SERVICERADAR_ANOMALY_METRIC_CLASS_OVERRIDES_JSON" => "{}",
      "SERVICERADAR_ANOMALY_EMISSION_JSON" => "{}",
      "SERVICERADAR_CAPACITY_FORECAST_CONFIG_METRIC_CLASS_OVERRIDES_JSON" => "{}"
    }

    anomaly_attrs = AnomalyConfigSeeder.anomaly_attrs_from_env(&Map.get(env, &1))
    forecast_attrs = AnomalyConfigSeeder.forecast_attrs_from_env(&Map.get(env, &1))

    assert anomaly_attrs.metric_class_overrides["cpu"]["drift_mode"] == "deseasonalized_only"
    assert anomaly_attrs.metric_class_overrides["disk"]["drift_mode"] == "off"
    assert anomaly_attrs.emission["cooldown_secs"] == 300

    assert forecast_attrs.metric_class_overrides |> Map.keys() |> Enum.sort() ==
             ["cpu", "disk", "flow", "interface", "memory"]
  end

  test "explicit non-empty override env replaces the code defaults" do
    env = %{
      "SERVICERADAR_ANOMALY_METRIC_CLASS_OVERRIDES_JSON" => ~s({"cpu":{"drift_mode":"off"}})
    }

    attrs = AnomalyConfigSeeder.anomaly_attrs_from_env(&Map.get(env, &1))

    assert attrs.metric_class_overrides == %{"cpu" => %{"drift_mode" => "off"}}
  end

  test "anomaly seed attrs clamp out-of-range numeric env values" do
    env = %{
      "SERVICERADAR_ANOMALY_N_SIGMA" => "50",
      "SERVICERADAR_ANOMALY_WINDOW_SIZE" => "1",
      "SERVICERADAR_ANOMALY_WINDOW_DURATION_SECONDS" => "90000",
      "SERVICERADAR_ANOMALY_CONFIRM_SLOTS" => "20000",
      "SERVICERADAR_ANOMALY_MIN_SAMPLES" => "100000"
    }

    attrs = AnomalyConfigSeeder.anomaly_attrs_from_env(&Map.get(env, &1))

    assert attrs.n_sigma == 20.0
    assert attrs.window_size == 2
    assert attrs.window_duration_seconds == 86_400
    assert attrs.confirm_slots == 10_000
    assert attrs.min_samples == 86_400
  end

  test "forecast seed attrs clamp out-of-range numeric env values" do
    env = %{
      "SERVICERADAR_CAPACITY_FORECAST_CONFIG_HORIZON_SECONDS" => "1",
      "SERVICERADAR_CAPACITY_FORECAST_CONFIG_WARNING_HORIZON_SECONDS" => "999999999",
      "SERVICERADAR_CAPACITY_FORECAST_CONFIG_WARNING_THRESHOLD_PERCENT" => "500",
      "SERVICERADAR_CAPACITY_FORECAST_CONFIG_MINIMUM_HISTORY_POINTS" => "1"
    }

    attrs = AnomalyConfigSeeder.forecast_attrs_from_env(&Map.get(env, &1))

    assert attrs.forecast_horizon_seconds == 3_600
    assert attrs.warning_horizon_seconds == 63_115_200
    assert attrs.warning_threshold_percent == 100.0
    assert attrs.minimum_history_points == 2
  end

  test "invalid env values fall back to defaults" do
    env = %{
      "SERVICERADAR_ANOMALY_N_SIGMA" => "not-a-float",
      "SERVICERADAR_ANOMALY_WINDOW_SIZE" => "twelve",
      "SERVICERADAR_ANOMALY_METRIC_CLASS_OVERRIDES_JSON" => "{bad-json",
      "SERVICERADAR_ANOMALY_METRIC_DENYLIST_JSON" => ~s({"not":"a-list"}),
      "SERVICERADAR_ANOMALY_EMISSION_JSON" => "[]",
      "SERVICERADAR_CAPACITY_FORECAST_CONFIG_MODEL" => "unsupported_model",
      "SERVICERADAR_CAPACITY_FORECAST_CONFIG_WARNING_THRESHOLD_PERCENT" => "eighty",
      "SERVICERADAR_CAPACITY_FORECAST_CONFIG_METRIC_CLASS_OVERRIDES_JSON" => "[]"
    }

    anomaly_attrs = AnomalyConfigSeeder.anomaly_attrs_from_env(&Map.get(env, &1))
    forecast_attrs = AnomalyConfigSeeder.forecast_attrs_from_env(&Map.get(env, &1))

    assert anomaly_attrs.n_sigma == 3.0
    assert anomaly_attrs.window_size == 300
    assert Map.has_key?(anomaly_attrs.metric_class_overrides, "interface")
    assert anomaly_attrs.metric_denylist == ["cpu.frequency_hz"]
    assert anomaly_attrs.emission["cooldown_secs"] == 300

    assert forecast_attrs.model == :linear
    assert forecast_attrs.warning_threshold_percent == 80.0

    assert forecast_attrs.metric_class_overrides |> Map.keys() |> Enum.sort() ==
             ["cpu", "disk", "flow", "interface", "memory"]

    assert Map.has_key?(forecast_attrs.metric_class_overrides, "interface")
  end
end
