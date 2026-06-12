defmodule ServiceRadar.Observability.CapacityForecastConfigTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias AshPostgres.DataLayer.Info, as: PostgresInfo
  alias ServiceRadar.Observability
  alias ServiceRadar.Observability.CapacityForecastConfig

  @migration_path "priv/repo/migrations/20260612100000_create_anomaly_capacity_configs.exs"

  test "resource is managed in the platform schema" do
    assert PostgresInfo.table(CapacityForecastConfig) == "capacity_forecast_configs"
    assert PostgresInfo.schema(CapacityForecastConfig) == "platform"
    assert CapacityForecastConfig in Ash.Domain.Info.resources(Observability)
  end

  test "singleton actions expose operator-managed forecast tuning fields" do
    create_action = Info.action(CapacityForecastConfig, :create)
    update_action = Info.action(CapacityForecastConfig, :update)
    read_action = Info.action(CapacityForecastConfig, :get_singleton)

    expected_fields = [
      :forecast_horizon_seconds,
      :warning_horizon_seconds,
      :warning_threshold_percent,
      :model,
      :minimum_history_points,
      :metric_class_overrides
    ]

    assert create_action.accept == expected_fields
    assert update_action.accept == expected_fields
    assert read_action.get?
  end

  test "resource captures required forecast defaults and class overrides" do
    attributes = CapacityForecastConfig |> Info.attributes() |> Map.new(&{&1.name, &1})

    assert attributes.key.primary_key?
    assert attributes.forecast_horizon_seconds.default == 7_776_000
    assert attributes.warning_horizon_seconds.default == 2_592_000
    assert attributes.warning_threshold_percent.default == 80.0
    assert attributes.model.default == :linear
    assert attributes.minimum_history_points.default == 72
    assert attributes.model.constraints[:one_of] == [:linear, :seasonal_linear, :holt_winters]

    assert attributes.metric_class_overrides.default |> Map.keys() |> Enum.sort() ==
             ["cpu", "disk", "interface", "memory"]
  end

  test "migration creates seeded platform forecast config with guard constraints" do
    migration = File.read!(@migration_path)

    assert migration =~ "create table(:capacity_forecast_configs"
    assert migration =~ ~s(prefix: "platform")
    assert migration =~ "warning_horizon_seconds <= forecast_horizon_seconds"
    assert migration =~ "warning_threshold_percent >= 1.0"
    assert migration =~ "model IN ('linear', 'seasonal_linear', 'holt_winters')"
    assert migration =~ "INSERT INTO platform.capacity_forecast_configs"
    refute migration =~ "public.capacity_forecast_configs"
  end
end
