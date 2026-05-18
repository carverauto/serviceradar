defmodule ServiceRadar.Observability.ServiceStateRegistryTest do
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage

  test "scheduled health-result plugin assignments appear as pending service rows" do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: unique_id("agent"), metadata: %{"partition" => "edge"}})
    package = approved_package_fixture("serviceradar.plugin_result.v1")
    assignment = assignment_fixture(agent.uid, package.id)

    assert :ok = ServiceStateRegistry.upsert_for_assignment(assignment)

    state = service_state_for(agent, package.name)
    assert state.available == false
    assert state.message == "plugin assignment pending result"
    assert state.service_type == "plugin"
    assert state.partition == "edge"

    assert %{
             "assignment_id" => assignment_id,
             "plugin_id" => plugin_id,
             "plugin_type" => "scheduled",
             "package_version" => "1.0.0"
           } = Jason.decode!(state.details)

    assert assignment_id == to_string(assignment.id)
    assert plugin_id == package.plugin_id
  end

  test "streaming plugin assignments keep ready service rows" do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: unique_id("agent")})
    package = approved_package_fixture("serviceradar.camera_stream.v1")
    assignment = assignment_fixture(agent.uid, package.id)

    assert :ok = ServiceStateRegistry.upsert_for_assignment(assignment)

    state = service_state_for(agent, package.name)
    assert state.available == true
    assert state.message == "streaming plugin ready"
    assert %{"plugin_type" => "streaming"} = Jason.decode!(state.details)
  end

  test "reconcile_plugin_assignments backfills enabled assignment service rows" do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: unique_id("agent")})
    package = approved_package_fixture("serviceradar.camera_stream.v1")
    _assignment = assignment_fixture(agent.uid, package.id)

    assert {:ok, count} = ServiceStateRegistry.reconcile_plugin_assignments()
    assert count >= 1

    state = service_state_for(agent, package.name)
    assert state.available == true
    assert state.message == "streaming plugin ready"
  end

  test "agent-reported plugin status updates the plugin service row" do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: unique_id("agent")})

    assert :ok =
             ServiceStateRegistry.upsert_from_status(%{
               agent_id: agent.uid,
               gateway_id: agent.gateway_id,
               partition: "default",
               service_type: "plugin",
               service_name: "UniFi",
               available: false,
               message: %{"status" => "CRITICAL", "summary" => "plugin failed"},
               observed_at: DateTime.utc_now()
             })

    state = service_state_for(agent, "UniFi")
    assert state.available == false
    assert state.message == "plugin failed"
  end

  test "assignment reconciliation preserves the last agent-reported plugin status" do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: unique_id("agent")})
    package = approved_package_fixture("serviceradar.plugin_result.v1")
    assignment = assignment_fixture(agent.uid, package.id)

    assert :ok =
             ServiceStateRegistry.upsert_from_status(%{
               agent_id: agent.uid,
               gateway_id: agent.gateway_id,
               partition: "default",
               service_type: "plugin",
               service_name: package.name,
               available: true,
               message: %{"status" => "OK", "summary" => "cached plugin result"},
               observed_at: DateTime.utc_now()
             })

    assert :ok = ServiceStateRegistry.upsert_for_assignment(assignment)

    state = service_state_for(agent, package.name)
    assert state.available == true
    assert state.message == "cached plugin result"
  end

  test "agent-reported plugin status preserves payload details for service cards" do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: unique_id("agent")})

    payload = %{
      "status" => "OK",
      "summary" => "plugin ok",
      "labels" => %{"plugin_id" => "unifi-protect-camera"},
      "display" => [%{"widget" => "stat_card", "label" => "Cameras", "value" => "12"}]
    }

    assert :ok =
             ServiceStateRegistry.upsert_from_status(%{
               agent_id: agent.uid,
               gateway_id: agent.gateway_id,
               partition: "default",
               service_type: "plugin",
               service_name: "UniFi Protect",
               available: true,
               message: Jason.encode!(payload),
               observed_at: DateTime.utc_now()
             })

    state = service_state_for(agent, "UniFi Protect")
    assert state.available == true
    assert state.message == "plugin ok"
    assert Jason.decode!(state.details)["display"] == payload["display"]
  end

  defp service_state_for(agent, service_name) do
    metadata = agent.metadata || %{}

    ServiceState
    |> Ash.Query.for_read(
      :by_identity,
      %{
        agent_id: agent.uid,
        gateway_id: agent.gateway_id,
        partition: metadata["partition"] || "default",
        service_type: "plugin",
        service_name: service_name
      },
      actor: system_actor()
    )
    |> Ash.read_one!(domain: ServiceRadar.Observability)
  end

  defp approved_package_fixture(output) do
    plugin_id = unique_id("service-state-plugin")
    name = "Service State Plugin #{System.unique_integer([:positive])}"

    Plugin
    |> Ash.Changeset.for_create(
      :create,
      %{plugin_id: plugin_id, name: name},
      actor: system_actor()
    )
    |> Ash.create!()

    manifest = %{
      "id" => plugin_id,
      "name" => name,
      "version" => "1.0.0",
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "outputs" => output,
      "capabilities" => ["submit_result"],
      "resources" => %{
        "requested_memory_mb" => 32,
        "requested_cpu_ms" => 100,
        "max_open_connections" => 1
      }
    }

    PluginPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: plugin_id,
        name: name,
        version: "1.0.0",
        entrypoint: "run_check",
        runtime: "wasi-preview1",
        outputs: output,
        manifest: manifest,
        config_schema: %{},
        display_contract: %{},
        content_hash: "sha256:#{plugin_id}",
        signature: %{},
        source_type: :upload
      },
      actor: system_actor()
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:approve, %{approved_by: "test"}, actor: system_actor())
    |> Ash.update!()
  end

  defp assignment_fixture(agent_uid, package_id) do
    PluginAssignment
    |> Ash.Changeset.for_create(
      :create,
      %{
        agent_uid: agent_uid,
        plugin_package_id: package_id,
        source: :manual,
        enabled: true,
        interval_seconds: 60,
        timeout_seconds: 10,
        params: %{}
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
