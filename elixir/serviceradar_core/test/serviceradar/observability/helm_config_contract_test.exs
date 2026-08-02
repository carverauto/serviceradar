defmodule ServiceRadar.Observability.HelmConfigContractTest do
  @moduledoc """
  Drift guard between ServiceRadar.Observability.AnomalyConfigSeeder and the Helm chart.

  The seeder takes its first-boot defaults from SERVICERADAR_ANOMALY_* and
  SERVICERADAR_CAPACITY_FORECAST_* environment variables, so values.yaml has to declare the
  blocks and templates/core.yaml has to wire the variables into the pod. Adding a knob to the
  seeder and forgetting the chart would otherwise ship silent defaults to a real deployment.

  Deliberately its own module, split out of anomaly_config_seeder_test.exs. It reads two
  files and asserts on their text: no repo, no Ash, no application. Carrying
  `@moduletag :requires_app` put it in the tier that needs a provisioned database, which made
  a pure string check depend on the CNPG fixture being up -- and dragged the Helm chart in as
  a runtime input of the database-backed suite.
  """
  use ExUnit.Case, async: true

  # Module level, so these are compile-time reads: the files must be declared Bazel inputs
  # (//helm/serviceradar:values) or this file fails to load rather than failing an assertion.
  @values_path Path.expand("../../../../../helm/serviceradar/values.yaml", __DIR__)
  @core_template_path Path.expand("../../../../../helm/serviceradar/templates/core.yaml", __DIR__)

  @first_boot_env [
    "SERVICERADAR_ANOMALY_N_SIGMA",
    "SERVICERADAR_ANOMALY_METRIC_DENYLIST_JSON",
    "SERVICERADAR_ANOMALY_EMISSION_JSON",
    "SERVICERADAR_ANOMALY_METRIC_CLASS_OVERRIDES_JSON",
    "SERVICERADAR_CAPACITY_FORECAST_CONFIG_HORIZON_SECONDS",
    "SERVICERADAR_CAPACITY_FORECAST_CONFIG_WARNING_THRESHOLD_PERCENT",
    "SERVICERADAR_CAPACITY_FORECAST_CONFIG_METRIC_CLASS_OVERRIDES_JSON"
  ]

  test "Helm values and core pod template expose first-boot config defaults" do
    values = File.read!(@values_path)
    template = File.read!(@core_template_path)

    assert values =~ "anomalyDetectionConfig:"
    assert values =~ "capacityForecastConfig:"

    for env_name <- @first_boot_env do
      assert template =~ env_name
    end
  end
end
