defmodule ServiceRadar.Observability.RuleSeederTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.RuleSeeder
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "seeds the endpoint inventory vulnerability stateful alert rule" do
    actor = SystemActor.system(:test)

    assert :ok = RuleSeeder.seed_all()

    query =
      StatefulAlertRule
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(name == "endpoint_inventory_vulnerability")

    assert {:ok, [rule]} = Ash.read(query, actor: actor)
    assert rule.enabled
    assert rule.signal == :event
    assert rule.match["subject_prefix"] == "signals.analytics.inventory"
    assert rule.match["attribute_equals"] == %{"signal_type" => "inventory"}
    assert rule.group_by == ["device"]
    assert rule.threshold == 1
    assert rule.event["log_name"] == "alert.security.endpoint_inventory.vulnerability"
    assert rule.alert["severity"] == "critical"
  end

  test "seeds the causal prediction health stateful alert rule" do
    actor = SystemActor.system(:test)

    assert :ok = RuleSeeder.seed_all()

    query =
      StatefulAlertRule
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(name == "causal_prediction_health_finding")

    assert {:ok, [rule]} = Ash.read(query, actor: actor)
    assert rule.enabled
    assert rule.signal == :event
    assert rule.match["subject_prefix"] == "signals.analytics.predictions"

    assert rule.match["attribute_equals"] == %{
             "signal_type" => "prediction",
             "event_type" => ["anomaly", "anomaly_detection"],
             "anomaly.state" => ["anomaly_open", "anomaly_drift_open", "open", "anomalous"]
           }

    assert rule.match["recovery"]["attribute_equals"]["anomaly.state"] == [
             "anomaly_clear",
             "anomaly_drift_clear",
             "clear",
             "cleared",
             "inactive"
           ]

    assert rule.group_by == ["device", "anomaly.series_key"]
    assert rule.threshold == 1
    assert rule.event["log_name"] == "alert.health.causal_prediction"
    assert rule.alert["severity_from"] == "source"
  end

  test "seeds the capacity forecast health stateful alert rule" do
    actor = SystemActor.system(:test)

    assert :ok = RuleSeeder.seed_all()

    query =
      StatefulAlertRule
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(name == "causal_capacity_health_finding")

    assert {:ok, [rule]} = Ash.read(query, actor: actor)
    assert rule.enabled
    assert rule.signal == :event
    assert rule.match["subject_prefix"] == "signals.analytics.predictions"

    assert rule.match["attribute_equals"] == %{
             "signal_type" => "prediction",
             "event_type" => "capacity_forecast",
             "capacity_forecast.status" => "projected"
           }

    assert rule.match["recovery"]["attribute_equals"]["capacity_forecast.status"] == [
             "inactive",
             "skipped"
           ]

    assert rule.group_by == ["device", "capacity_forecast.resource_key"]
    assert rule.threshold == 1
    assert rule.event["log_name"] == "alert.health.capacity_forecast"
    assert rule.alert["severity_from"] == "source"
  end
end
