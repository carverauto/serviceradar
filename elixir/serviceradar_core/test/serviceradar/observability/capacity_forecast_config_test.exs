defmodule ServiceRadar.Observability.CapacityForecastConfigTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias AshPostgres.DataLayer.Info, as: PostgresInfo
  alias ServiceRadar.Observability
  alias ServiceRadar.Observability.CapacityForecastConfig

  @moduletag :requires_app

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
      :metric_class_overrides,
      :default_source_opt_ins
    ]

    assert create_action.accept == expected_fields
    assert update_action.accept == expected_fields
    assert read_action.get?
  end

  test "resource mirrors the warning horizon cross-field constraint in Ash and Postgres" do
    validations = Info.validations(CapacityForecastConfig)
    check_constraints = PostgresInfo.check_constraints(CapacityForecastConfig)

    assert Enum.any?(validations, fn validation ->
             validation.module == Ash.Resource.Validation.Compare and
               validation.opts[:attribute] == :warning_horizon_seconds and
               validation.opts[:less_than_or_equal_to] == {:ref, :forecast_horizon_seconds}
           end)

    assert Enum.any?(check_constraints, fn constraint ->
             constraint.name == "capacity_forecast_configs_horizon_check" and
               constraint.attribute == :warning_horizon_seconds
           end)
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
             ["cpu", "disk", "flow", "interface", "memory"]

    assert attributes.default_source_opt_ins.default == []
    refute attributes.default_source_opt_ins.allow_nil?
  end

  test "source opt-ins accept only the bursty opt-in sources" do
    invalid =
      Ash.Changeset.for_create(CapacityForecastConfig, :create, %{
        default_source_opt_ins: ["cpu_usage", "bogus_source"]
      })

    refute invalid.valid?

    assert Enum.any?(invalid.errors, fn error ->
             Map.get(error, :field) == :default_source_opt_ins
           end)

    valid =
      Ash.Changeset.for_create(CapacityForecastConfig, :create, %{
        default_source_opt_ins: ["cpu_usage", "interface_rate", "flow_bytes_per_hour"]
      })

    assert valid.valid?
  end

  test "opt-in migration adds the text[] column with an empty array default" do
    migration =
      File.read!("priv/repo/migrations/20260712113000_add_capacity_forecast_source_opt_ins.exs")

    assert migration =~ "ALTER TABLE platform.capacity_forecast_configs"
    assert migration =~ "default_source_opt_ins text[] NOT NULL DEFAULT '{}'::text[]"
  end

  test "migration creates unseeded platform forecast config with guard constraints" do
    migration = File.read!(@migration_path)

    assert migration =~ "create table(:capacity_forecast_configs"
    assert migration =~ ~s(prefix: "platform")
    assert migration =~ "warning_horizon_seconds <= forecast_horizon_seconds"
    assert migration =~ "warning_threshold_percent >= 1.0"
    assert migration =~ "model IN ('linear', 'seasonal_linear', 'holt_winters')"
    refute migration =~ "INSERT INTO platform.capacity_forecast_configs"
    refute migration =~ "public.capacity_forecast_configs"
  end
end
