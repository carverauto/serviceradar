defmodule ServiceRadar.Observability.AnomalyConfigSeederDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.AnomalyConfigSeeder
  alias ServiceRadar.Observability.AnomalyDetectionConfig
  alias ServiceRadar.Observability.CapacityForecastConfig

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "seed_defaults creates missing singletons with code defaults" do
    actor = SystemActor.system(:anomaly_config_seeder_db_test)

    assert :ok = AnomalyConfigSeeder.seed_defaults()

    assert {:ok, %AnomalyDetectionConfig{} = settings} =
             AnomalyDetectionConfig.get_settings(actor: actor)

    assert settings.metric_class_overrides["cpu"]["drift_mode"] == "deseasonalized_only"
    assert settings.metric_class_overrides["disk"]["drift_mode"] == "off"

    assert {:ok, %CapacityForecastConfig{} = forecast} =
             CapacityForecastConfig.get_settings(actor: actor)

    assert forecast.metric_class_overrides |> Map.keys() |> Enum.sort() ==
             ["cpu", "disk", "flow", "interface", "memory"]

    # No SERVICERADAR_CAPACITY_FORECASTING_SOURCE_OPT_INS in the test env, so
    # first boot seeds an empty opt-in list and env opt-ins stay authoritative.
    assert forecast.default_source_opt_ins == []
  end

  test "seed_defaults leaves existing operator-owned rows untouched" do
    actor = SystemActor.system(:anomaly_config_seeder_db_test)

    operator_overrides = %{"cpu" => %{"drift_mode" => "off"}}

    assert {:ok, _settings} =
             AnomalyDetectionConfig.create_settings(
               %{n_sigma: 9.5, metric_class_overrides: operator_overrides},
               actor: actor
             )

    assert {:ok, _forecast} =
             CapacityForecastConfig.create_settings(
               %{warning_threshold_percent: 55.0},
               actor: actor
             )

    assert :ok = AnomalyConfigSeeder.seed_defaults()

    assert {:ok, %AnomalyDetectionConfig{} = settings} =
             AnomalyDetectionConfig.get_settings(actor: actor)

    assert settings.n_sigma == 9.5
    assert settings.metric_class_overrides == operator_overrides

    assert {:ok, %CapacityForecastConfig{} = forecast} =
             CapacityForecastConfig.get_settings(actor: actor)

    assert forecast.warning_threshold_percent == 55.0
  end
end
