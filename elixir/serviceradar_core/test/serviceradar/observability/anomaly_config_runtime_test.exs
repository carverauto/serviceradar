defmodule ServiceRadar.Observability.AnomalyConfigRuntimeTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.AnomalyConfigRuntime
  alias ServiceRadar.Observability.AnomalyDetectionConfig
  alias ServiceRadar.Observability.CapacityForecastConfig

  setup do
    AnomalyConfigRuntime.clear_cache_for_test()

    on_exit(fn ->
      AnomalyConfigRuntime.clear_cache_for_test()
    end)
  end

  test "converts anomaly settings into runtime series config" do
    settings = %AnomalyDetectionConfig{
      n_sigma: 4.5,
      window_size: 600,
      window_duration_seconds: 1_200,
      confirm_slots: 7,
      min_samples: 45,
      metric_class_overrides: %{
        "interface" => %{"n_sigma" => 5.5},
        "memory" => %{"window_size" => 120, "window_duration_seconds" => 300}
      }
    }

    config = AnomalyConfigRuntime.anomaly_series_config_from_settings(settings)

    assert config.metric_class_defaults["default"]["n_sigma"] == 4.5
    refute Map.has_key?(config.metric_class_defaults, "cpu")
    assert config.metric_class_defaults["interface"]["n_sigma"] == 5.5
    assert config.metric_class_defaults["interface"]["window_size"] == 600
    assert config.metric_class_defaults["memory"]["window_size"] == 120
    refute Map.has_key?(config.metric_class_defaults["default"], "window_duration_seconds")
    refute Map.has_key?(config.metric_class_defaults["memory"], "window_duration_seconds")
    refute Map.has_key?(config.metric_class_defaults, "mem")
  end

  test "converts anomaly settings into seasonal disposition worker options" do
    settings = %AnomalyDetectionConfig{
      n_sigma: 4.5,
      window_size: 600,
      confirm_slots: 7,
      min_samples: 45,
      metric_class_overrides: %{"interface" => %{"seasonal_n_sigma" => 5.5}}
    }

    opts = AnomalyConfigRuntime.seasonal_disposition_opts_from_settings(settings)

    assert opts[:seasonal_n_sigma] == 4.5
    assert opts[:min_bucket_samples] == 45
    assert opts[:confirm_slots] == 7
    assert opts[:seasonal_metric_class_overrides]["interface"]["seasonal_n_sigma"] == 5.5
  end

  test "converts forecast settings into worker options" do
    settings = %CapacityForecastConfig{
      forecast_horizon_seconds: 15_552_000,
      warning_horizon_seconds: 1_209_600,
      warning_threshold_percent: 75.0,
      model: :seasonal_linear,
      minimum_history_points: 96,
      metric_class_overrides: %{"disk" => %{"minimum_history_points" => 120}}
    }

    opts = AnomalyConfigRuntime.capacity_forecasting_opts_from_settings(settings)

    assert opts[:horizon_seconds] == 15_552_000
    assert opts[:warning_horizon_seconds] == 1_209_600
    assert opts[:warning_threshold_percent] == 75.0
    assert opts[:forecast_model] == "seasonal_linear"
    assert opts[:min_points] == 96
    assert opts[:capacity_metric_class_overrides]["disk"]["minimum_history_points"] == 120
  end

  test "forecast source opt-ins are forwarded only when operators selected sources" do
    settings = %CapacityForecastConfig{
      forecast_horizon_seconds: 15_552_000,
      warning_horizon_seconds: 1_209_600,
      warning_threshold_percent: 75.0,
      model: :linear,
      minimum_history_points: 96,
      metric_class_overrides: %{},
      default_source_opt_ins: ["cpu_usage", "interface_rate"]
    }

    opts = AnomalyConfigRuntime.capacity_forecasting_opts_from_settings(settings)

    assert opts[:default_source_opt_ins] == ["cpu_usage", "interface_rate"]

    # An untouched Settings list must not mask env opt-ins: the worker merges
    # DB-derived opts over its env config, so the key is omitted when empty.
    for empty <- [[], nil] do
      opts =
        AnomalyConfigRuntime.capacity_forecasting_opts_from_settings(%{
          settings
          | default_source_opt_ins: empty
        })

      refute Keyword.has_key?(opts, :default_source_opt_ins)
    end
  end

  test "linear forecast model is forwarded to the worker" do
    settings = %CapacityForecastConfig{
      forecast_horizon_seconds: 15_552_000,
      warning_horizon_seconds: 1_209_600,
      warning_threshold_percent: 75.0,
      model: :linear,
      minimum_history_points: 96,
      metric_class_overrides: %{}
    }

    opts = AnomalyConfigRuntime.capacity_forecasting_opts_from_settings(settings)

    assert opts[:forecast_model] == "linear"
  end

  test "refresh hot-swaps cached settings without restarting callers" do
    {:ok, settings} =
      Agent.start_link(fn ->
        %{
          anomaly: %AnomalyDetectionConfig{
            n_sigma: 3.0,
            window_size: 300,
            confirm_slots: 5,
            min_samples: 30,
            metric_class_overrides: %{}
          },
          forecast: %CapacityForecastConfig{
            forecast_horizon_seconds: 7_776_000,
            warning_horizon_seconds: 2_592_000,
            warning_threshold_percent: 80.0,
            model: :linear,
            minimum_history_points: 72,
            metric_class_overrides: %{}
          }
        }
      end)

    name = :"#{__MODULE__}.Runtime"

    start_supervised!(
      {AnomalyConfigRuntime,
       name: name,
       refresh_interval_ms: 60_000,
       anomaly_fetcher: fn _actor -> {:ok, Agent.get(settings, & &1.anomaly)} end,
       forecast_fetcher: fn _actor -> {:ok, Agent.get(settings, & &1.forecast)} end}
    )

    assert AnomalyConfigRuntime.anomaly_series_config().metric_class_defaults["default"][
             "n_sigma"
           ] == 3.0

    assert AnomalyConfigRuntime.capacity_forecasting_opts()[:warning_threshold_percent] == 80.0

    Agent.update(settings, fn state ->
      %{
        state
        | anomaly: %{state.anomaly | n_sigma: 6.0},
          forecast: %{state.forecast | warning_threshold_percent: 70.0}
      }
    end)

    assert {:ok, _cache} = AnomalyConfigRuntime.refresh(name)

    assert AnomalyConfigRuntime.anomaly_series_config().metric_class_defaults["default"][
             "n_sigma"
           ] == 6.0

    assert AnomalyConfigRuntime.capacity_forecasting_opts()[:warning_threshold_percent] == 70.0
  end
end
