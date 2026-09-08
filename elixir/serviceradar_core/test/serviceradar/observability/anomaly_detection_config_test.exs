defmodule ServiceRadar.Observability.AnomalyDetectionConfigTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias AshPostgres.DataLayer.Info, as: PostgresInfo
  alias ServiceRadar.Observability
  alias ServiceRadar.Observability.AnomalyDetectionConfig

  @migration_path "priv/repo/migrations/20260612100000_create_anomaly_capacity_configs.exs"

  test "resource is managed in the platform schema" do
    assert PostgresInfo.table(AnomalyDetectionConfig) == "anomaly_detection_configs"
    assert PostgresInfo.schema(AnomalyDetectionConfig) == "platform"
    assert AnomalyDetectionConfig in Ash.Domain.Info.resources(Observability)
  end

  test "singleton actions expose operator-managed anomaly tuning fields" do
    create_action = Info.action(AnomalyDetectionConfig, :create)
    update_action = Info.action(AnomalyDetectionConfig, :update)
    read_action = Info.action(AnomalyDetectionConfig, :get_singleton)

    expected_fields = [
      :n_sigma,
      :window_size,
      :window_duration_seconds,
      :confirm_slots,
      :min_samples,
      :metric_class_overrides,
      :metric_denylist,
      :emission
    ]

    assert create_action.accept == expected_fields
    assert update_action.accept == expected_fields
    assert read_action.get?
  end

  test "resource mirrors the minimum samples cross-field constraint in Ash and Postgres" do
    validations = Info.validations(AnomalyDetectionConfig)
    check_constraints = PostgresInfo.check_constraints(AnomalyDetectionConfig)

    assert Enum.any?(validations, fn validation ->
             validation.module == Ash.Resource.Validation.Compare and
               validation.opts[:attribute] == :min_samples and
               validation.opts[:less_than_or_equal_to] == {:ref, :window_size}
           end)

    assert Enum.any?(check_constraints, fn constraint ->
             constraint.name == "anomaly_detection_configs_window_check" and
               constraint.attribute == :min_samples
           end)
  end

  test "resource captures required anomaly defaults and class overrides" do
    attributes = AnomalyDetectionConfig |> Info.attributes() |> Map.new(&{&1.name, &1})

    assert attributes.key.primary_key?
    assert attributes.n_sigma.default == 3.0
    assert attributes.window_size.default == 300
    assert attributes.window_duration_seconds.default == 900
    assert attributes.confirm_slots.default == 5
    assert attributes.min_samples.default == 30

    assert attributes.metric_class_overrides.default |> Map.keys() |> Enum.sort() ==
             ["cpu", "disk", "icmp", "interface", "memory", "other", "red"]

    assert attributes.metric_class_overrides.default["interface"]["drift_mode"] ==
             "deseasonalized_only"

    assert attributes.metric_denylist.default == ["cpu.frequency_hz"]

    assert attributes.emission.default == %{
             "cooldown_secs" => 300,
             "budget_per_tick" => 100,
             "episode_update_interval_secs" => 1_800,
             "reopen_cooldown_secs" => 600
           }
  end

  test "migration creates unseeded platform anomaly config with guard constraints" do
    migration = File.read!(@migration_path)

    assert migration =~ "create table(:anomaly_detection_configs"
    assert migration =~ ~s(prefix: "platform")
    assert migration =~ "n_sigma >= 0.1 AND n_sigma <= 20.0"
    assert migration =~ "min_samples <= window_size"
    refute migration =~ "INSERT INTO platform.anomaly_detection_configs"
    refute migration =~ "public.anomaly_detection_configs"
  end

  test "edge settings migration extends anomaly config without reseeding rows" do
    migration =
      File.read!("priv/repo/migrations/20260704190000_extend_anomaly_detection_edge_settings.exs")

    assert migration =~ "ADD COLUMN metric_denylist"
    assert migration =~ "ADD COLUMN emission"
    refute migration =~ "INSERT INTO platform.anomaly_detection_configs"
  end
end
