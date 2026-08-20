defmodule ServiceRadar.Notifications.RouterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.MatchExpression.Fields
  alias ServiceRadar.Notifications.Router

  @now ~U[2026-08-09 12:00:00.000000Z]

  defp alert(overrides) do
    Map.merge(
      %{
        title: "Interface flapping",
        description: "eth0 flapped 12 times",
        severity: :critical,
        status: :pending,
        source_type: :device,
        source_id: "dev-1",
        service_check_id: "chk-1",
        event_id: "evt-1",
        device_uid: "device-abc",
        agent_uid: "agent-1",
        metric_name: "interface.errors",
        metric_value: 90.0,
        threshold_value: 10.0,
        comparison: :greater_than,
        escalation_level: 2,
        tags: ["prod", "network"],
        metadata: %{
          "incident_rule_id" => "rule-1",
          "incident_group_key" => "device_id=abc|severity=high"
        }
      },
      overrides
    )
  end

  defp alert, do: alert(%{})

  defp route(id, overrides) do
    Map.merge(
      %{
        id: id,
        name: "route-#{id}",
        enabled: true,
        priority: 100,
        continue: false,
        match_expression: %{},
        escalation_policy_id: "policy-#{id}",
        schedule_id: nil,
        dedupe_key_template: nil
      },
      overrides
    )
  end

  defp matched_ids(decision), do: Enum.map(decision.matched, & &1.route_id)

  describe "evaluation order" do
    test "sorts by ascending priority" do
      routes = [
        route("c", %{priority: 30}),
        route("a", %{priority: 10}),
        route("b", %{priority: 20})
      ]

      assert Enum.map(Router.evaluation_order(routes), & &1.id) == ["a", "b", "c"]
    end

    test "breaks a priority tie by ascending id" do
      routes = [
        route("zz", %{priority: 10}),
        route("aa", %{priority: 10}),
        route("mm", %{priority: 10})
      ]

      assert Enum.map(Router.evaluation_order(routes), & &1.id) == ["aa", "mm", "zz"]
    end

    test "keeps input order when priority and id are both equal" do
      first = route(nil, %{priority: 10, name: "first"})
      second = route(nil, %{priority: 10, name: "second"})

      assert Enum.map(Router.evaluation_order([first, second]), & &1.name) == ["first", "second"]
    end

    test "treats a route with no priority as the resource default of 100" do
      routes = [
        route("no-priority", %{priority: nil}),
        route("lower", %{priority: 99}),
        route("higher", %{priority: 101})
      ]

      assert Enum.map(Router.evaluation_order(routes), & &1.id) == [
               "lower",
               "no-priority",
               "higher"
             ]
    end

    test "excludes disabled routes from the order" do
      routes = [route("on", %{}), route("off", %{enabled: false})]
      assert Enum.map(Router.evaluation_order(routes), & &1.id) == ["on"]
    end

    test "evaluation follows the order regardless of input order" do
      routes = [
        route("third", %{priority: 30, continue: true}),
        route("first", %{priority: 10, continue: true}),
        route("second", %{priority: 20, continue: true})
      ]

      assert matched_ids(Router.match(alert(), routes, @now)) == ["first", "second", "third"]
    end
  end

  describe "continue semantics" do
    test "the first matching route wins when continue is false" do
      routes = [
        route("a", %{priority: 10, continue: false}),
        route("b", %{priority: 20, continue: false})
      ]

      decision = Router.match(alert(), routes, @now)

      assert decision.outcome == :routed
      assert matched_ids(decision) == ["a"]
      assert decision.halted_by == "a"
      assert decision.considered == 1
    end

    test "continue fans routing to later routes" do
      routes = [
        route("a", %{priority: 10, continue: true}),
        route("b", %{priority: 20, continue: false}),
        route("c", %{priority: 30, continue: true})
      ]

      decision = Router.match(alert(), routes, @now)

      assert matched_ids(decision) == ["a", "b"]
      assert decision.halted_by == "b"
      assert decision.considered == 2
    end

    test "continue true on the last route leaves nothing halted" do
      routes = [route("a", %{priority: 10, continue: true})]
      decision = Router.match(alert(), routes, @now)

      assert matched_ids(decision) == ["a"]
      assert decision.halted_by == nil
      assert decision.considered == 1
    end

    test "a non-matching route never halts, whatever its continue" do
      routes = [
        route("skip", %{
          priority: 10,
          continue: false,
          match_expression: %{"field" => "alert.severity", "equals" => "info"}
        }),
        route("take", %{priority: 20, continue: false})
      ]

      assert matched_ids(Router.match(alert(), routes, @now)) == ["take"]
    end

    test "each matched route carries its own policy and dedupe override" do
      routes = [
        route("a", %{priority: 10, continue: true, dedupe_key_template: "{{ alert.id }}"}),
        route("b", %{priority: 20, escalation_policy_id: "ladder-b", schedule_id: "sched-b"})
      ]

      assert [first, second] = Router.match(alert(), routes, @now).matched

      assert first.escalation_policy_id == "policy-a"
      assert first.dedupe_key_template == "{{ alert.id }}"
      assert first.order == 0
      assert first.continue == true

      assert second.escalation_policy_id == "ladder-b"
      assert second.schedule_id == "sched-b"
      assert second.dedupe_key_template == nil
      assert second.order == 1
    end
  end

  describe "disabled routes" do
    test "do not participate and are reported" do
      routes = [
        route("off", %{priority: 10, enabled: false}),
        route("on", %{priority: 20})
      ]

      decision = Router.match(alert(), routes, @now)

      assert matched_ids(decision) == ["on"]
      assert decision.disabled == ["off"]
      assert decision.considered == 1
    end

    test "a disabled route with continue false stops nothing" do
      routes = [
        route("off", %{priority: 10, enabled: false, continue: false}),
        route("on", %{priority: 20, continue: false})
      ]

      assert matched_ids(Router.match(alert(), routes, @now)) == ["on"]
    end

    test "only an explicit false disables a route" do
      assert Router.enabled?(route("a", %{enabled: true}))
      assert Router.enabled?(Map.delete(route("a", %{}), :enabled))
      assert Router.enabled?(route("a", %{enabled: nil}))
      refute Router.enabled?(route("a", %{enabled: false}))
    end

    test "every route disabled yields an unrouted decision" do
      routes = [route("off", %{enabled: false})]
      decision = Router.match(alert(), routes, @now)

      assert decision.outcome == :unrouted
      assert Router.suppression_reason(decision) == :no_matching_route
      assert decision.considered == 0
    end
  end

  describe "unrouted outcome" do
    test "no routes at all is unrouted, not an error" do
      decision = Router.match(alert(), [], @now)

      assert decision.outcome == :unrouted
      assert decision.matched == []
      assert decision.errors == []
      assert Router.unrouted?(decision)
      assert Router.suppression_reason(decision) == :no_matching_route
    end

    test "routes that all fail to match is unrouted" do
      routes = [
        route("a", %{match_expression: %{"field" => "alert.severity", "equals" => "info"}}),
        route("b", %{match_expression: %{"field" => "alert.tags", "equals" => "staging"}})
      ]

      decision = Router.match(alert(), routes, @now)

      assert decision.outcome == :unrouted
      assert Router.suppression_reason(decision) == :no_matching_route
      assert decision.considered == 2
    end

    test "a routed decision reports no suppression reason" do
      decision = Router.match(alert(), [route("a", %{})], @now)

      assert decision.outcome == :routed
      refute Router.unrouted?(decision)
      assert Router.suppression_reason(decision) == nil
    end
  end

  describe "malformed predicates never crash the pipeline" do
    test "an unknown operator is recorded and evaluation continues" do
      routes = [
        route("broken", %{
          priority: 10,
          continue: false,
          match_expression: %{"field" => "alert.severity", "equalz" => "critical"}
        }),
        route("good", %{priority: 20})
      ]

      decision = Router.match(alert(), routes, @now)

      assert matched_ids(decision) == ["good"]
      assert [%{route_id: "broken", reason: reason}] = decision.errors
      assert reason =~ "unknown operator"
    end

    test "a broken predicate does not halt evaluation through continue false" do
      routes = [
        route("broken", %{priority: 10, continue: false, match_expression: "not an object"}),
        route("good", %{priority: 20, continue: false})
      ]

      decision = Router.match(alert(), routes, @now)

      assert matched_ids(decision) == ["good"]
      assert decision.halted_by == "good"
      assert length(decision.errors) == 1
    end

    test "an unrouted decision can still carry errors" do
      routes = [
        route("broken", %{match_expression: %{"field" => "alert.severity", "in" => "critical"}})
      ]

      decision = Router.match(alert(), routes, @now)

      assert decision.outcome == :unrouted
      assert Router.suppression_reason(decision) == :no_matching_route
      assert [%{route_id: "broken"}] = decision.errors
    end

    test "a route missing match_expression entirely is treated as a catch-all" do
      routes = [Map.delete(route("bare", %{}), :match_expression)]
      assert matched_ids(Router.match(alert(), routes, @now)) == ["bare"]
    end

    test "an unparsable regex is an error, not a match" do
      routes = [
        route("bad", %{match_expression: %{"field" => "alert.title", "matches" => "("}})
      ]

      decision = Router.match(alert(), routes, @now)

      assert decision.outcome == :unrouted
      assert [%{reason: reason}] = decision.errors
      assert reason =~ "invalid pattern"
    end
  end

  describe "predicate evaluation over the matchable surface" do
    test "the empty document is a catch-all" do
      assert matched_ids(Router.match(alert(), [route("catch-all", %{})], @now)) == ["catch-all"]
    end

    test "matches an atom attribute by its text" do
      routes = [
        route("crit", %{match_expression: %{"field" => "alert.severity", "equals" => "critical"}})
      ]

      assert matched_ids(Router.match(alert(), routes, @now)) == ["crit"]
      assert Router.match(alert(%{severity: :warning}), routes, @now).outcome == :unrouted
    end

    test "matches an array attribute existentially" do
      routes = [route("prod", %{match_expression: %{"field" => "alert.tags", "in" => ["prod"]}})]

      assert matched_ids(Router.match(alert(), routes, @now)) == ["prod"]
      assert Router.match(alert(%{tags: ["staging"]}), routes, @now).outcome == :unrouted
    end

    test "matches an incident metadata path under the allow-listed prefix" do
      routes = [
        route("incident", %{
          match_expression: %{"field" => "alert.metadata.incident_rule_id", "equals" => "rule-1"}
        })
      ]

      assert matched_ids(Router.match(alert(), routes, @now)) == ["incident"]
    end

    test "matches through nested combinators" do
      routes = [
        route("ladder", %{
          match_expression: %{
            "all" => [
              %{"field" => "alert.source_type", "equals" => "device"},
              %{
                "any" => [
                  %{"field" => "alert.severity", "equals" => "emergency"},
                  %{"field" => "alert.metric_value", "equals" => 90}
                ]
              },
              %{"not" => %{"field" => "alert.tags", "equals" => "staging"}}
            ]
          }
        })
      ]

      assert matched_ids(Router.match(alert(), routes, @now)) == ["ladder"]
      assert Router.match(alert(%{tags: ["staging"]}), routes, @now).outcome == :unrouted
    end

    test "a missing alert field simply does not match" do
      routes = [
        route("needs-device", %{
          match_expression: %{"field" => "alert.device_uid", "exists" => true}
        })
      ]

      assert matched_ids(Router.match(alert(), routes, @now)) == ["needs-device"]

      assert Router.match(alert(%{device_uid: nil}), routes, @now).outcome == :unrouted
      assert Router.match(%{severity: :critical}, routes, @now).outcome == :unrouted
    end
  end

  describe "route map shapes" do
    test "string-keyed route maps are read the same as atom-keyed ones" do
      routes = [
        %{
          "id" => "string-keyed",
          "enabled" => true,
          "priority" => 10,
          "continue" => false,
          "match_expression" => %{"field" => "alert.severity", "equals" => "critical"},
          "escalation_policy_id" => "policy-x"
        }
      ]

      assert [match] = Router.match(alert(), routes, @now).matched
      assert match.route_id == "string-keyed"
      assert match.priority == 10
      assert match.escalation_policy_id == "policy-x"
    end
  end

  describe "evaluate_route/2" do
    test "answers the predicate without consulting enabled" do
      route = route("off", %{enabled: false, match_expression: %{"alert.severity" => "critical"}})

      assert Router.evaluate_route(route, alert()) == {:ok, true}
      assert Router.evaluate_route(route, alert(%{severity: :info})) == {:ok, false}
    end

    test "reports a malformed predicate" do
      route = route("bad", %{match_expression: %{"any" => []}})
      assert {:error, message} = Router.evaluate_route(route, alert())
      assert message =~ "at least one expression"
    end
  end

  describe "purity" do
    test "stamps the supplied instant and never reads the clock" do
      decision = Router.match(alert(), [route("a", %{})], @now)
      assert decision.evaluated_at == @now
    end

    test "the same inputs always produce the same decision" do
      routes = [
        route("a", %{priority: 10, continue: true}),
        route("b", %{priority: 10, match_expression: %{"alert.severity" => "critical"}}),
        route("c", %{priority: 5, enabled: false})
      ]

      decisions = for _repeat <- 1..25, do: Router.match(alert(), routes, @now)
      assert Enum.uniq(decisions) == [Router.match(alert(), routes, @now)]
    end
  end

  describe "convenience accessors" do
    test "matched_routes returns the route maps in evaluation order" do
      routes = [
        route("b", %{priority: 20, continue: true}),
        route("a", %{priority: 10, continue: true})
      ]

      assert Enum.map(Router.matched_routes(Router.match(alert(), routes, @now)), & &1.id) ==
               ["a", "b"]
    end

    test "publishes the same matchable surface the resource validates against" do
      assert Router.matchable_fields() == Fields.route_fields()
      assert Router.matchable_field_prefixes() == Fields.route_field_prefixes()
    end

    test "subject namespaces the alert under alert" do
      assert Router.subject(alert()) == %{"alert" => alert()}
    end
  end
end
