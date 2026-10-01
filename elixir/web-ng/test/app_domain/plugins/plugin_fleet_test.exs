defmodule ServiceRadarWebNG.Plugins.PluginFleetTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
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
          {state(last_observed_at: DateTime.add(@now, -181)), %{"category" => "unavailable", "stale" => true}},
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

  test "known assignment drift and wrapped results preserve safe runtime evidence" do
    package = package()
    assignment = assignment(package)
    old_id = Ecto.UUID.generate()

    result = %{
      "plugin_id" => package.plugin_id,
      "status" => "OK",
      "labels" => %{"assignment_id" => old_id, "package_version" => "1.0.0", "token" => "synthetic-secret"}
    }

    state = state(details: Jason.encode!(%{"reported_result" => result}))

    assert [
             %{
               "assignment_drift" => true,
               "observed_assignment_id" => ^old_id,
               "version_drift" => false,
               "result_status" => "OK",
               "category" => "action_required"
             } = row
           ] =
             PluginFleet.build_rows([assignment], [package], [state], @now)

    refute Jason.encode!(row) =~ "synthetic-secret"
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

  test "duplicate assignments prefer the enabled newest desired state across month boundaries" do
    package = package()
    older = assignment(package)
    newer = %{older | id: Ecto.UUID.generate(), updated_at: ~U[2026-02-01 12:00:00Z]}
    disabled = %{older | id: Ecto.UUID.generate(), enabled: false, updated_at: ~U[2026-03-01 12:00:00Z]}

    assert [%{"assignment_id" => id}] = PluginFleet.build_rows([older, newer, disabled], [package], [], @now)
    assert id == newer.id
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
                 %{"agent_uid" => "agent-b", "reported_at" => DateTime.add(end_at, -10), "evidence_age_seconds" => 10},
                 %{"agent_uid" => "agent-c", "reported_at" => DateTime.add(end_at, -7200)}
               ],
               plan
             )
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
