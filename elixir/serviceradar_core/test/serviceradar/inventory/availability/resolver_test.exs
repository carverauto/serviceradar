defmodule ServiceRadar.Inventory.Availability.ResolverTest do
  @moduledoc """
  Owner of the merged availability decision (`Resolver.resolve/3`, design Decisions 3,
  5, 6 and 12). One table over invented ledger rows and evidence records; agent ids and
  source instances are made up.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Availability.Resolver

  @now ~U[2026-01-01 12:00:00.000000Z]
  @fresh_ttl 3_600

  defp at(minutes_ago), do: DateTime.shift(@now, minute: -minutes_ago)

  defp probe(agent_id, available?, opts \\ []) do
    %{
      agent_id: agent_id,
      available?: available?,
      checked_at: at(Keyword.get(opts, :minutes_ago, 1)),
      consecutive_down: Keyword.get(opts, :down, if(available?, do: 0, else: 2)),
      ttl_seconds: @fresh_ttl,
      sweep_group_id: nil,
      reporter_expectation: Keyword.get(opts, :expectation)
    }
  end

  defp evidence(kind, class, state, opts \\ []) do
    observed_at = at(Keyword.get(opts, :minutes_ago, 1))

    %{
      source_kind: kind,
      source_instance: Keyword.get(opts, :instance, "SITE01-src"),
      reporter_agent_id: "",
      authority_class: class,
      state: state,
      observed_at: observed_at,
      expires_at: DateTime.shift(observed_at, second: Keyword.get(opts, :ttl, @fresh_ttl)),
      confirmations: 1,
      reporter_eligible: Keyword.get(opts, :eligible, true)
    }
  end

  defp previous(state, decided_by \\ nil),
    do: %{state: state, decided_by: decided_by, changed_at: at(600)}

  defp agent_decider(agent_id),
    do: %{
      "source_kind" => "agent_probe",
      "source_instance" => "",
      "reporter_agent_id" => agent_id
    }

  # Cases are data; `{:probe, ...}`, `{:evidence, ...}`, `{:previous, ...}` and
  # `{:agent_decider, ...}` are built by the helpers above when the test runs.
  defp build({:probe, agent_id, available?}), do: probe(agent_id, available?)
  defp build({:probe, agent_id, available?, opts}), do: probe(agent_id, available?, opts)
  defp build({:evidence, kind, class, state}), do: evidence(kind, class, state)
  defp build({:evidence, kind, class, state, opts}), do: evidence(kind, class, state, opts)
  defp build({:previous, state}), do: previous(state)
  defp build({:previous, state, decided_by}), do: previous(state, build(decided_by))
  defp build({:agent_decider, agent_id}), do: agent_decider(agent_id)
  defp build(%{} = map), do: Map.new(map, fn {key, value} -> {key, build(value)} end)
  defp build(list) when is_list(list), do: Enum.map(list, &build/1)
  defp build(value), do: value

  # {name, device, inputs, expected}: expected `decided` names the deciding
  # {source_kind, reporter_agent_id or source_instance}; `agents` lists only the counters
  # the case is about.
  @cases [
    {"a controller's up outranks confirmed probe failures and is flagged as a conflict", %{},
     %{
       ledger: [{:probe, "agent-a", false}, {:probe, "agent-b", false}],
       evidence: [{:evidence, "wifi_map", :managing_controller, :up}]
     },
     %{
       state: :available,
       rule: "highest_class",
       decided: {"wifi_map", "SITE01-src"},
       conflict: true,
       agents: %{"down" => 2, "up" => 0, "total" => 2}
     }},
    {"any reachable agent wins within the probe class", %{},
     %{ledger: [{:probe, "agent-a", true}, {:probe, "agent-b", false}]},
     %{
       state: :available,
       decided: {"agent_probe", "agent-a"},
       conflict: false,
       agents: %{"up" => 1, "down" => 1}
     }},
    {"a lower class's up never overrides a higher class's decisive down", %{},
     %{
       ledger: [{:probe, "agent-a", true}],
       evidence: [{:evidence, "hypervisor", :managing_controller, :down}]
     }, %{state: :unavailable, decided: {"hypervisor", "SITE01-src"}, conflict: true}},
    {"the pinned agent decides the probe class and other agents stay counted", %{pin: "agent-a"},
     %{ledger: [{:probe, "agent-a", false}, {:probe, "agent-b", true}]},
     %{
       state: :unavailable,
       decided: {"agent_probe", "agent-a"},
       conflict: true,
       agents: %{"up" => 1, "down" => 1, "total" => 2}
     }},
    {"a per-device pin outranks operator policy, which is flagged as a conflict",
     %{pin: "agent-a"},
     %{
       ledger: [{:probe, "agent-a", true}],
       evidence: [{:evidence, "composite_check", :operator_policy, :down}]
     }, %{state: :available, decided: {"agent_probe", "agent-a"}, conflict: true}},
    {"without a pin, operator policy still outranks a reachable probe", %{},
     %{
       ledger: [{:probe, "agent-a", true}],
       evidence: [{:evidence, "composite_check", :operator_policy, :down}]
     }, %{state: :unavailable, decided: {"composite_check", "SITE01-src"}, conflict: true}},
    {"a blank pin is not a pin, so operator policy still decides", %{pin: "  "},
     %{
       ledger: [{:probe, "agent-a", true}],
       evidence: [{:evidence, "composite_check", :operator_policy, :down}]
     }, %{state: :unavailable, decided: {"composite_check", "SITE01-src"}, conflict: true}},
    {"a pin on a negative control does not outrank operator policy", %{pin: "agent-control"},
     %{
       ledger: [{:probe, "agent-a", true}],
       evidence: [{:evidence, "composite_check", :operator_policy, :down}],
       expectations: %{"agent-control" => :blocked}
     },
     %{
       state: :unavailable,
       decided: {"composite_check", "SITE01-src"},
       invalid_pin: true,
       conflict: true
     }},
    {"a pin does not demote a managing controller", %{pin: "agent-a"},
     %{
       ledger: [{:probe, "agent-a", true}],
       evidence: [{:evidence, "wifi_map", :managing_controller, :down}]
     }, %{state: :unavailable, decided: {"wifi_map", "SITE01-src"}, conflict: true}},
    {"operator policy that agrees with the pinned agent is not a conflict", %{pin: "agent-a"},
     %{
       ledger: [{:probe, "agent-a", true}],
       evidence: [{:evidence, "composite_check", :operator_policy, :up}]
     }, %{state: :available, decided: {"agent_probe", "agent-a"}, conflict: false}},
    {"an unexpected or unknown reporter does not decide", %{},
     %{
       ledger: [
         {:probe, "agent-a", false, expectation: "unexpected"},
         {:probe, "agent-b", false, expectation: "unknown"}
       ]
     }, %{state: :unknown, rule: "no_evidence", conflict: false, agents: %{"down" => 2}}},
    {"the pinned agent stays eligible when unexpected but not when unknown", %{pin: "agent-a"},
     %{ledger: [{:probe, "agent-a", true, expectation: "unexpected"}]},
     %{state: :available, decided: {"agent_probe", "agent-a"}}},
    {"an unknown reporter is ineligible even when pinned", %{pin: "agent-a"},
     %{ledger: [{:probe, "agent-a", true, expectation: "unknown"}]}, %{state: :unknown}},
    {"one failed probe holds the previous state",
     %{previous: {:previous, :available, {:agent_decider, "agent-a"}}},
     %{ledger: [{:probe, "agent-a", false, down: 1}]},
     %{state: :available, rule: "hysteresis_hold", decided: {"agent_probe", "agent-a"}}},
    {"the second consecutive failure decides",
     %{previous: {:previous, :available, {:agent_decider, "agent-a"}}},
     %{ledger: [{:probe, "agent-a", false, down: 2}]},
     %{state: :unavailable, rule: "highest_class", previous: "available"}},
    {"a pending probe failure does not fall through to a lower class",
     %{previous: {:previous, :available}},
     %{
       ledger: [{:probe, "agent-a", false, down: 1}],
       evidence: [{:evidence, "plugin:cmdb", :inventory_declared, :down}]
     }, %{state: :available, rule: "hysteresis_hold", conflict: true}},
    {"recovery is immediate", %{previous: {:previous, :unavailable}},
     %{ledger: [{:probe, "agent-a", true}]}, %{state: :available, previous: "unavailable"}},
    {"with all evidence aged out the state is unknown and the last decision is kept",
     %{previous: {:previous, :available}},
     %{
       ledger: [{:probe, "agent-a", true, minutes_ago: 120}],
       evidence: [{:evidence, "agent_liveness", :self_report, :up, minutes_ago: 10, ttl: 90}]
     },
     %{
       state: :unknown,
       rule: "no_evidence",
       previous: "available",
       agents: %{"stale" => 1, "up" => 0}
     }},
    {"an ineligible evidence record is ignored", %{},
     %{evidence: [{:evidence, "camera", :managing_controller, :down, eligible: false}]},
     %{state: :unknown}},
    {"the previous decider keeps deciding while it still agrees",
     %{previous: {:previous, :available, {:agent_decider, "agent-a"}}},
     %{
       ledger: [
         {:probe, "agent-a", true, minutes_ago: 9},
         {:probe, "agent-b", true, minutes_ago: 1}
       ]
     }, %{state: :available, decided: {"agent_probe", "agent-a"}}},
    {"otherwise the most recent agreeing row decides", %{},
     %{
       ledger: [
         {:probe, "agent-a", true, minutes_ago: 9},
         {:probe, "agent-b", true, minutes_ago: 1}
       ]
     }, %{state: :available, decided: {"agent_probe", "agent-b"}}},
    {"a negative control's block is a verified block, not down", %{},
     %{
       ledger: [{:probe, "agent-witness", true}, {:probe, "agent-control", false}],
       expectations: %{"agent-witness" => :reachable, "agent-control" => :blocked}
     },
     %{
       state: :available,
       conflict: false,
       agents: %{
         "up" => 1,
         "down" => 0,
         "total" => 1,
         "blocked_verified" => 1,
         "policy_violation" => 0
       }
     }},
    {"a negative control that is only blocked leaves the decision to the other classes", %{},
     %{ledger: [{:probe, "agent-control", false}], expectations: %{"agent-control" => :blocked}},
     %{state: :unknown, agents: %{"blocked_verified" => 1, "total" => 0}}},
    {"a negative control that reaches the device is liveness and a policy violation", %{},
     %{ledger: [{:probe, "agent-control", true}], expectations: %{"agent-control" => :blocked}},
     %{
       state: :available,
       decided: {"agent_probe", "agent-control"},
       agents: %{"policy_violation" => 1, "total" => 0}
     }},
    {"a negative control's up against a controller's down is a policy violation, not a conflict",
     %{},
     %{
       ledger: [{:probe, "agent-control", true}],
       evidence: [{:evidence, "wifi_map", :managing_controller, :down}],
       expectations: %{"agent-control" => :blocked}
     },
     %{
       state: :unavailable,
       decided: {"wifi_map", "SITE01-src"},
       conflict: false,
       agents: %{"policy_violation" => 1, "total" => 0}
     }},
    {"a negative control with no fresh result is inconclusive", %{},
     %{
       ledger: [{:probe, "agent-a", true}, {:probe, "agent-control", false, minutes_ago: 120}],
       expectations: %{"agent-control" => :blocked, "agent-idle" => :blocked}
     },
     %{
       state: :available,
       agents: %{"inconclusive_control" => 2, "blocked_verified" => 0, "stale" => 0}
     }},
    {"a pin on a negative control is ignored and reported as invalid", %{pin: "agent-control"},
     %{
       ledger: [{:probe, "agent-control", false}, {:probe, "agent-b", true}],
       expectations: %{"agent-control" => :blocked}
     },
     %{state: :available, decided: {"agent_probe", "agent-b"}, invalid_pin: true, conflict: false}}
  ]

  for {name, device, inputs, expected} <- @cases do
    @device device
    @inputs inputs
    @expected expected

    test name do
      device = Map.merge(%{pin: nil, previous: nil}, build(@device))
      inputs = Map.merge(%{ledger: [], evidence: [], expectations: %{}}, build(@inputs))
      decision = Resolver.resolve(device, inputs, @now)
      expected = Map.put_new(@expected, :invalid_pin, false)

      assert Map.new(expected, fn {key, want} -> {key, observe(key, want, decision)} end) ==
               expected
    end
  end

  defp observe(:state, _want, decision), do: decision.state
  defp observe(:rule, _want, decision), do: decision.decided_by["rule"]
  defp observe(:conflict, _want, decision), do: decision.conflict
  defp observe(:invalid_pin, _want, decision), do: decision.decided_by["invalid_pin"]
  defp observe(:previous, _want, decision), do: get_in(decision.decided_by, ["previous", "state"])
  defp observe(:agents, want, decision), do: Map.take(decision.agents, Map.keys(want))

  # A ledger row is named by its agent, an evidence record by its source instance.
  defp observe(:decided, _want, %{decided_by: decided_by}) do
    reporter = decided_by["reporter_agent_id"]

    {decided_by["source_kind"],
     if(reporter in [nil, ""], do: decided_by["source_instance"], else: reporter)}
  end

  test "a resolution that keeps the state keeps its provenance and change time" do
    device = %{pin: nil, previous: nil}
    inputs = %{ledger: [probe("agent-a", true, minutes_ago: 5)], evidence: [], expectations: %{}}
    first = Resolver.resolve(device, inputs, @now)

    # The same agent renews its result and another agreeing agent appears.
    renewed = %{
      inputs
      | ledger: [probe("agent-a", true, minutes_ago: 1), probe("agent-b", true, minutes_ago: 0)]
    }

    previous = %{state: first.state, decided_by: first.decided_by, changed_at: first.changed_at}
    later = DateTime.shift(@now, minute: 4)
    second = Resolver.resolve(%{device | previous: previous}, renewed, later)

    assert second.decided_by == first.decided_by
    assert second.changed_at == first.changed_at
    assert second.conflict == first.conflict
  end
end
