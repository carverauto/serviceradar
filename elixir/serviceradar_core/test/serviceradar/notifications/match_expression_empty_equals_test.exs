defmodule ServiceRadar.Notifications.MatchExpressionEmptyEqualsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.MatchExpression
  alias ServiceRadar.Notifications.MatchExpression.Evaluator
  alias ServiceRadar.Notifications.NotificationRoute
  alias ServiceRadar.Notifications.NotificationSilence
  alias ServiceRadar.Notifications.Router

  @now ~U[2026-09-05 12:00:00.000000Z]

  test "rejects equals empty string with an actionable message" do
    expr = %{"all" => [%{"field" => "alert.title", "equals" => ""}]}

    changeset =
      Ash.Changeset.force_change_attribute(
        Ash.Changeset.new(NotificationRoute),
        :match_expression,
        expr
      )

    assert {:error, field: :match_expression, message: message} =
             MatchExpression.validate(
               changeset,
               [attribute: :match_expression, reject_empty_equals?: true],
               %{}
             )

    assert {:error, field: :match_expression, message: ^message} =
             MatchExpression.atomic(
               changeset,
               [attribute: :match_expression, reject_empty_equals?: true],
               %{}
             )

    assert message =~ ~s("equals" cannot be an empty string)
    assert message =~ "{}"
  end

  test "silence saves still accept empty equality" do
    expr = %{"all" => [%{"field" => "alert.metadata.optional", "equals" => ""}]}

    changeset =
      Ash.Changeset.force_change_attribute(
        Ash.Changeset.new(NotificationSilence),
        :matchers,
        expr
      )

    assert :ok = MatchExpression.validate(changeset, [attribute: :matchers], %{})
    assert :ok = MatchExpression.atomic(changeset, [attribute: :matchers], %{})
  end

  test "legacy empty equality remains evaluable inside a disjunction" do
    expr = %{
      "any" => [
        %{"field" => "alert.title", "equals" => ""},
        %{"field" => "alert.severity", "equals" => "critical"}
      ]
    }

    assert {:ok, true} =
             Evaluator.evaluate(expr, %{alert: %{title: "Node down", severity: "critical"}})

    assert {:ok, false} =
             Evaluator.evaluate(expr, %{alert: %{title: "Node up", severity: "info"}})

    assert {:ok, true} = Evaluator.evaluate(expr, %{alert: %{title: "", severity: "info"}})
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
