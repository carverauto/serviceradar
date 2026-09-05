defmodule ServiceRadar.Notifications.MatchExpressionEmptyEqualsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.MatchExpression
  alias ServiceRadar.Notifications.Router

  @now ~U[2026-09-05 12:00:00.000000Z]

  test "rejects equals empty string with an actionable message" do
    expr = %{"all" => [%{"field" => "alert.title", "equals" => ""}]}

    assert {:error, message} = MatchExpression.validate_expression(expr)
    assert message =~ ~s("equals" cannot be an empty string)
    assert message =~ "{}"
  end

  test "empty object still matches every alert" do
    assert :ok = MatchExpression.validate_expression(%{})

    alert = %{
      title: "Anomaly Finding",
      metadata: %{"incident_rule_name" => "causal_prediction_health_finding"}
    }

    route = %{
      id: "all",
      name: "all",
      enabled: true,
      priority: 100,
      continue: false,
      match_expression: %{},
      escalation_policy_id: "policy",
      schedule_id: nil,
      dedupe_key_template: nil
    }

    decision = Router.match(alert, [route], @now)
    assert Enum.map(decision.matched, & &1.route_id) == ["all"]
  end

  test "incident_rule_name predicate matches k8s node alerts only" do
    expr = %{
      "field" => "alert.metadata.incident_rule_name",
      "equals" => "k8s_node_not_ready"
    }

    assert :ok = MatchExpression.validate_expression(expr)

    route = %{
      id: "k8s",
      name: "k8s-nodes",
      enabled: true,
      priority: 10,
      continue: false,
      match_expression: expr,
      escalation_policy_id: "policy",
      schedule_id: nil,
      dedupe_key_template: nil
    }

    node_alert = %{
      title: "Kubernetes worker node node-worker-1.example.com is NotReady",
      metadata: %{"incident_rule_name" => "k8s_node_not_ready"}
    }

    anomaly = %{
      title: "Anomaly Finding",
      metadata: %{"incident_rule_name" => "causal_prediction_health_finding"}
    }

    assert Enum.map(Router.match(node_alert, [route], @now).matched, & &1.route_id) == ["k8s"]
    assert Router.match(anomaly, [route], @now).matched == []
  end
end
