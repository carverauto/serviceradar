defmodule ServiceRadarWebNG.Plugins.PluginFleetTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.PluginResultReportedMarker
  alias ServiceRadar.Observability.PluginResultSlot
  alias ServiceRadar.Observability.ServiceIdentity
  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PluginTargetPolicy
  alias ServiceRadarWebNG.Plugins.PluginFleet
  alias ServiceRadarWebNG.SRQL.FleetQuery
  alias ServiceRadarWebNG.SRQL.Native

  @moduletag :db_free
  @now ~U[2026-01-15 12:00:00Z]

  test "runtime evidence is fresh, stale, unhealthy, pending, or version drift without leaking payloads" do
    package = package()
    assignment = assignment(package)

    for {state, expected} <- [
          {state(),
           %{
             "category" => "healthy",
             "last_success_at" => @now,
             "stale" => false,
             "assignment_drift" => nil,
             "observed_version" => nil
           }},
          {state(last_observed_at: DateTime.shift(@now, second: -181)), %{"category" => "unavailable", "stale" => true}},
          {state(available: false),
           %{"category" => "action_required", "last_failure_at" => @now, "last_error" => "plugin_result_unavailable"}},
          {state(details: Jason.encode!(%{"plugin_id" => "example-check", "status" => "WARNING"})),
           %{"category" => "action_required", "available" => true, "result_status" => "WARNING"}},
          {state(message: "plugin assignment pending result"),
           %{"observed_state" => "pending", "reported_at" => nil, "available" => nil, "category" => "unavailable"}},
          {state(
             message: "plugin assignment pending result",
             details: Jason.encode!(%{"plugin_id" => package.plugin_id, "labels" => %{"assignment_id" => assignment.id}})
           ), %{"observed_assignment_id" => nil, "assignment_drift" => nil}},
          {state(details: Jason.encode!(%{"plugin_id" => "example-check", "package_version" => "0.9.0"})),
           %{"version_drift" => true, "category" => "action_required", "observed_version" => "0.9.0"}}
        ] do
      assert [row] = PluginFleet.build_rows([assignment], [package], [state], @now)
      assert Map.take(row, Map.keys(expected)) == expected
      refute Map.has_key?(row, "params")
      refute Map.has_key?(row, "details")
      refute Jason.encode!(row) =~ "synthetic-secret"
    end
  end

  test "wrapped results preserve only the matching assignment's safe runtime evidence" do
    package = package()
    assignment = assignment(package)
    old_id = Ecto.UUID.generate()

    result = %{
      "plugin_id" => package.plugin_id,
      "status" => "OK",
      "labels" => %{"assignment_id" => old_id, "package_version" => "1.0.0", "token" => "synthetic-secret"}
    }

    for {reported_id, category, observed_id} <- [
          {old_id, "unavailable", nil},
          {assignment.id, "healthy", assignment.id}
        ] do
      result = put_in(result, ["labels", "assignment_id"], reported_id)
      state = state(details: Jason.encode!(%{"reported_result" => result}))

      assert [row] = PluginFleet.build_rows([assignment], [package], [state], @now)
      assert row["category"] == category
      assert row["observed_assignment_id"] == observed_id
      refute Jason.encode!(row) =~ "synthetic-secret"
    end
  end

  test "an assignment a rollout holds is reported at the candidate it runs, not as version drift" do
    stable = package()
    candidate = %{stable | id: Ecto.UUID.generate(), version: "1.1.0"}
    assignment = %{assignment(stable) | rollout_plugin_package_id: candidate.id}
    state = state(details: Jason.encode!(%{"plugin_id" => "example-check", "package_version" => "1.1.0"}))

    assert [%{"assigned_version" => "1.1.0", "version_drift" => false, "category" => "healthy"}] =
             PluginFleet.build_rows([assignment], [stable, candidate], [state], @now)
  end

  test "same agent and plugin in another partition remains observed-only and cannot satisfy assignment" do
    package = package()
    assignment = assignment(package)
    other_partition = state(partition: "partition-b")
    rows = PluginFleet.build_rows([assignment], [package], [other_partition], @now)

    assert [
             %{"category" => "unavailable", "partition_id" => "partition-a", "reported_at" => nil},
             %{"assigned" => false, "partition_id" => "partition-b", "category" => "observed_only"}
           ] = rows
  end

  test "allocated reported results retain authenticated logical time throughout fleet queries" do
    package = package()
    assignment = assignment(package)
    state = state()
    payload = Jason.decode!(state.details)
    snapshot = Map.put(state, :timestamp, @now)
    physical_at = DateTime.add(PluginResultSlot.block_base(snapshot, 0), -14_000 * 257, :microsecond)

    details =
      Map.put(payload, PluginResultReportedMarker.marker_key(), %{
        "kind" => "reported",
        "observation_timestamp" => DateTime.to_iso8601(@now),
        "payload_digest" => PluginResultReportedMarker.payload_digest(payload),
        "service_id" => ServiceIdentity.service_id(state),
        "slot" => %{
          "base_timestamp" => DateTime.to_iso8601(physical_at),
          "version" => 1,
          "width_microseconds" => PluginResultSlot.block_width_microseconds()
        },
        "version" => 1
      })

    state = %{state | details: Jason.encode!(details), last_observed_at: physical_at}
    now = DateTime.shift(@now, second: 179)

    assert {:ok, json} =
             Native.translate(
               "in:plugin_fleet time:[2026-01-15T12:00:00Z,2026-01-15T12:00:01Z]",
               nil,
               nil,
               nil,
               "legacy"
             )

    %{"read_model" => plan} = Jason.decode!(json)

    for available <- [true, false], assignments <- [[assignment], []] do
      assert [row] = PluginFleet.build_rows(assignments, [package], [%{state | available: available}], now)
      assert row["reported_at"] == @now
      assert row["evidence_age_seconds"] == 179
      assert row["stale"] == false
      assert row["last_success_at"] == if(available, do: @now)
      assert row["last_failure_at"] == if(not available, do: @now)
      assert [^row] = FleetQuery.apply_plan([row], plan)
    end

    for field <- [:agent_id, :gateway_id, :partition, :service_type, :service_name] do
      tampered = Map.put(state, field, "different-example-identity")
      assert [row] = PluginFleet.build_rows([], [package], [tampered], now)
      assert row["reported_at"] == physical_at
      assert row["stale"] == true
      assert [] = FleetQuery.apply_plan([row], plan)
    end

    outside_slot = %{state | last_observed_at: DateTime.add(physical_at, -1, :microsecond)}
    assert [row] = PluginFleet.build_rows([], [package], [outside_slot], now)
    assert row["reported_at"] == outside_slot.last_observed_at
  end

  test "duplicate assignments prefer the enabled newest desired state across month boundaries" do
    package = package()
    older = assignment(package)
    newer = %{older | id: Ecto.UUID.generate(), updated_at: ~U[2026-02-01 12:00:00Z]}
    disabled = %{older | id: Ecto.UUID.generate(), enabled: false, updated_at: ~U[2026-03-01 12:00:00Z]}

    assert [%{"assignment_id" => id}] = PluginFleet.build_rows([older, newer, disabled], [package], [], @now)
    assert id == newer.id
  end

  test "an attributed bare-name result supplies evidence only for its own assignment" do
    package = package()
    rule_a = %{assignment(package) | source: :policy, policy_id: "network-credential-rule:rule-a:inventory"}
    rule_a_older = %{rule_a | id: Ecto.UUID.generate(), updated_at: ~U[2026-01-01 12:00:00Z]}

    rule_b = %{
      rule_a
      | id: Ecto.UUID.generate(),
        policy_id: "network-credential-rule:rule-b:inventory",
        updated_at: ~U[2026-01-02 12:00:00Z]
    }

    assignments = [rule_a_older, rule_b, rule_a]

    shared =
      state(
        details:
          Jason.encode!(%{
            "plugin_id" => package.plugin_id,
            "status" => "OK",
            "assignment_id" => rule_a.id,
            "labels" => %{"assignment_id" => rule_b.id}
          })
      )

    rows = PluginFleet.build_rows(assignments, [package], [shared], @now)

    assert rows |> Enum.map(& &1["assignment_id"]) |> Enum.sort() == Enum.sort([rule_a.id, rule_b.id])
    rows_by_assignment = Map.new(rows, &{&1["assignment_id"], &1})
    assert rows_by_assignment[rule_a.id]["category"] == "unavailable"
    assert rows_by_assignment[rule_a.id]["reported_at"] == nil
    assert rows_by_assignment[rule_b.id]["category"] == "healthy"
    assert rows_by_assignment[rule_b.id]["assignment_drift"] == false

    assert [%{health: %{status: "unavailable"}}] =
             PluginFleet.build_summaries(
               [%{plugin_id: package.plugin_id, name: package.name}],
               [package],
               assignments,
               [],
               rows
             )
  end

  test "each coexisting assignment reads its own state once identities split" do
    package = package()
    rule_a = %{assignment(package) | source: :policy, policy_id: "network-credential-rule:rule-a:inventory"}

    rule_b = %{
      rule_a
      | id: Ecto.UUID.generate(),
        policy_id: "network-credential-rule:rule-b:inventory",
        updated_at: ~U[2026-01-02 12:00:00Z]
    }

    primary_state =
      state(
        details:
          Jason.encode!(%{
            "plugin_id" => package.plugin_id,
            "status" => "OK",
            "labels" => %{"assignment_id" => rule_a.id}
          })
      )

    secondary_state =
      state(
        available: false,
        service_name: "#{package.name}##{rule_b.id}",
        details:
          Jason.encode!(%{
            "plugin_id" => package.plugin_id,
            "status" => "CRITICAL",
            "labels" => %{"assignment_id" => rule_b.id}
          })
      )

    rows =
      PluginFleet.build_rows(
        [rule_a, rule_b],
        [package],
        [secondary_state, primary_state],
        @now
      )

    by_assignment = Map.new(rows, &{&1["assignment_id"], &1})

    assert by_assignment[rule_a.id]["category"] == "healthy"
    assert by_assignment[rule_a.id]["observed_assignment_id"] == rule_a.id
    assert by_assignment[rule_b.id]["category"] == "action_required"
    assert by_assignment[rule_b.id]["observed_assignment_id"] == rule_b.id
    assert by_assignment[rule_b.id]["available"] == false
  end

  test "disabled assignment and ambiguous legacy name evidence never look like current healthy execution" do
    package = package()
    another = %{package | id: Ecto.UUID.generate(), plugin_id: "another-check"}
    legacy = state(details: "{}")

    assert [%{"category" => "unavailable"}] =
             PluginFleet.build_rows([assignment(package)], [package, another], [legacy], @now)

    assert [%{"category" => "expected_inactive", "enabled" => false}] =
             PluginFleet.build_rows([%{assignment(package) | enabled: false}], [package], [state()], @now)
  end

  test "an action-only package that ingests no results expects no runtime evidence" do
    # Evidence left from before the package became action-only: inactive and stale.
    leftover = state(state: "inactive", available: false, last_observed_at: DateTime.shift(@now, day: -30))

    for {capabilities, expected} <- [
          {["submit_result", "action-only:v1"], {"expected_inactive", "runtime_results_not_expected"}},
          {["submit_result", "action-only:v1", "action-result-ingest:v1"], {"unavailable", "runtime_observation_stale"}},
          {["submit_result"], {"unavailable", "runtime_observation_stale"}}
        ] do
      package = %{package() | approved_capabilities: capabilities}

      assert [row] = PluginFleet.build_rows([assignment(package)], [package], [leftover], @now)
      assert {capabilities, {row["category"], row["reason_code"]}} == {capabilities, expected}
    end
  end

  test "compiled filters and ordering apply before paging and do not treat absent evidence as fresh" do
    {:ok, json} =
      Native.translate(
        "in:plugin_fleet category:(healthy,unavailable) stale:false sort:agent_uid:desc limit:1",
        nil,
        nil,
        nil,
        "legacy"
      )

    %{"read_model" => plan} = Jason.decode!(json)

    rows = [
      %{"agent_uid" => "agent-a", "category" => "healthy", "stale" => false},
      %{"agent_uid" => "agent-z", "category" => "unavailable", "stale" => true},
      %{"agent_uid" => "agent-b", "category" => "healthy", "stale" => false}
    ]

    assert [%{"agent_uid" => "agent-b"}] = FleetQuery.apply_plan(rows, plan)

    {:ok, json} = Native.translate("in:addon_fleet time:last_1h sort:evidence_age_seconds:asc", nil, nil, nil, "legacy")
    %{"read_model" => plan} = Jason.decode!(json)
    {:ok, end_at, _offset} = DateTime.from_iso8601(plan["time_range"]["end"])

    assert [%{"agent_uid" => "agent-b"}] =
             FleetQuery.apply_plan(
               [
                 %{"agent_uid" => "agent-a", "reported_at" => nil},
                 %{
                   "agent_uid" => "agent-b",
                   "reported_at" => DateTime.shift(end_at, second: -10),
                   "evidence_age_seconds" => 10
                 },
                 %{"agent_uid" => "agent-c", "reported_at" => DateTime.shift(end_at, hour: -2)}
               ],
               plan
             )
  end

  test "summaries are one per plugin: latest approved, staged, running versions, owners, policy mix and health" do
    [p0, p1, p2, p3] =
      for {version, status} <- [{"0.9.0", :denied}, {"1.0.0", :approved}, {"1.1.0", :approved}, {"1.2.0", :staged}] do
        %{package() | id: Ecto.UUID.generate(), version: version, status: status}
      end

    other = %{package() | id: Ecto.UUID.generate(), plugin_id: "other-check", version: "0.1.0", status: :staged}
    policy = %PluginTargetPolicy{id: Ecto.UUID.generate(), name: "Example policy", update_policy: :pinned}

    owned = fn agent, package, attrs -> Map.merge(%{assignment(package) | agent_uid: agent}, Map.new(attrs)) end

    assignments = [
      owned.("agent-1", p1, update_policy: :track_latest_approved),
      owned.("agent-2", p2, update_policy: :pinned),
      owned.("agent-3", p1, source: :policy, policy_id: policy.id),
      owned.("agent-4", p2, source: :policy, policy_id: "network-credential-rule:rule-1:inventory"),
      owned.("agent-5", p2, source: :policy, policy_id: "network-credential-rule:rule-1:interfaces"),
      owned.("agent-6", p1, enabled: false),
      # Partition-unbound legacy history is not part of the fleet.
      owned.("agent-7", p2, partition_id: nil)
    ]

    packages = [p0, p1, p2, p3, other]
    fleet_rows = PluginFleet.build_rows(assignments, packages, [], @now)

    plugins = [%{plugin_id: "example-check", name: "Example Check"}, %{plugin_id: "other-check", name: "Other Check"}]

    assert [example, staged_only] =
             PluginFleet.build_summaries(plugins, packages, assignments, [policy], fleet_rows)

    assert example.plugin_id == "example-check"
    assert example.latest_approved == %{id: p2.id, version: "1.1.0"}
    assert example.newest_staged == %{id: p3.id, version: "1.2.0"}
    assert example.awaiting_review?
    assert example.primary_package_id == p2.id

    assert example.running_versions == [
             %{package_id: p2.id, version: "1.1.0", assignments: 3},
             %{package_id: p1.id, version: "1.0.0", assignments: 2}
           ]

    assert example.assignments == %{enabled: 5, disabled: 1, behind_latest: 2}

    assert example.owners == %{
             manual: 2,
             target_policies: [%{id: policy.id, name: "Example policy", update_policy: :pinned, assignments: 1}],
             credential_rules: [%{id: "rule-1", href: "/settings/networks/credentials/rule-1/edit", assignments: 2}]
           }

    # Manual rows count one owner each; a credential rule always tracks latest.
    assert example.update_policies == %{track_latest_approved: 2, pinned: 2}
    assert example.health == %{status: "unavailable", counts: %{"unavailable" => 5}}

    assert staged_only.latest_approved == nil
    assert staged_only.awaiting_review?
    assert staged_only.primary_package_id == other.id
    assert staged_only.running_versions == []
    assert staged_only.assignments == %{enabled: 0, disabled: 0, behind_latest: 0}
    assert staged_only.health == %{status: "unassigned", counts: %{}}
  end

  defp package do
    %PluginPackage{
      id: Ecto.UUID.generate(),
      plugin_id: "example-check",
      name: "Example Check",
      version: "1.0.0",
      status: :approved,
      content_hash: "synthetic-digest",
      runtime: "wasm",
      outputs: "serviceradar.plugin_result.v1"
    }
  end

  defp assignment(package) do
    %PluginAssignment{
      id: Ecto.UUID.generate(),
      plugin_id: package.plugin_id,
      agent_uid: "agent-example",
      partition_id: "partition-a",
      plugin_package_id: package.id,
      enabled: true,
      source: :manual,
      interval_seconds: 60,
      timeout_seconds: 10,
      updated_at: @now,
      params: %{"token" => "synthetic-secret"}
    }
  end

  defp state(overrides \\ []) do
    struct!(
      %ServiceState{
        id: Ecto.UUID.generate(),
        agent_id: "agent-example",
        partition: "partition-a",
        gateway_id: "gateway-example",
        service_type: "plugin",
        service_name: "Example Check",
        state: "active",
        available: true,
        message: "synthetic-secret",
        last_observed_at: @now,
        details: Jason.encode!(%{"plugin_id" => "example-check", "params" => %{"token" => "synthetic-secret"}})
      },
      overrides
    )
  end
end
