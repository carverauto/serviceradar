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
    assert rule.match["subject_prefix"] == "signals.causal.inventory"
    assert rule.match["attribute_equals"] == %{"signal_type" => "inventory"}
    assert rule.group_by == ["device"]
    assert rule.threshold == 1
    assert rule.event["log_name"] == "alert.security.endpoint_inventory.vulnerability"
    assert rule.alert["severity"] == "critical"
  end

  test "seeds transition-gated causal prediction stateful alert rules" do
    actor = SystemActor.system(:test)

    assert :ok = RuleSeeder.seed_all()

    anomaly_query =
      StatefulAlertRule
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(name == "causal_prediction_anomaly_finding")

    assert {:ok, [anomaly_rule]} = Ash.read(anomaly_query, actor: actor)
    assert anomaly_rule.enabled
    assert anomaly_rule.signal == :event
    assert anomaly_rule.match["subject_prefix"] == "signals.causal.predictions"
    assert anomaly_rule.match["resource_attribute_equals"]["event_type"] == "anomaly"
    assert anomaly_rule.match["attribute_not_equals"] == %{"anomaly.state" => "pending_anomaly"}
    assert anomaly_rule.match["reset_when"]
    assert anomaly_rule.group_by == ["finding_info.uid"]
    assert anomaly_rule.threshold == 1
    assert anomaly_rule.event["log_name"] == "alert.health.anomaly_detection"
    refute Map.has_key?(anomaly_rule.alert, "severity")

    capacity_query =
      StatefulAlertRule
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(name == "causal_prediction_capacity_exhaustion")

    assert {:ok, [capacity_rule]} = Ash.read(capacity_query, actor: actor)
    assert capacity_rule.enabled
    assert capacity_rule.signal == :event
    assert capacity_rule.match["resource_attribute_equals"]["event_type"] == "capacity_forecast"
    assert capacity_rule.match["attribute_equals"] == %{"status" => "projected"}
    assert capacity_rule.match["reset_when"]
    assert capacity_rule.group_by == ["finding_info.uid"]
    assert capacity_rule.event["log_name"] == "alert.health.capacity_forecast"
    refute Map.has_key?(capacity_rule.alert, "severity")
  end
end
