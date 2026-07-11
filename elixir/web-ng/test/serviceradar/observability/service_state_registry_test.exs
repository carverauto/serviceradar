defmodule ServiceRadar.Observability.ServiceStateRegistryTest do
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Observability.PluginResultIngestor
  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Observability.ServiceStatus
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Repo

  require Ash.Query

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

  test "assignment state reconciliation waits for the shared logical plugin lock" do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: unique_id("agent")})
    package = approved_package_fixture("serviceradar.plugin_result.v1")
    assignment = assignment_fixture(agent.uid, package.id)
    parent = self()

    identity = %{
      agent_id: agent.uid,
      partition: "default",
      service_type: "plugin",
      service_name: package.name
    }

    lock_holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          assert :ok = ServiceStateRegistry.acquire_plugin_state_lock(identity)
          send(parent, :assignment_plugin_state_lock_held)

          receive do
            :release_assignment_plugin_state_lock -> :ok
          after
            5_000 -> raise "timed out waiting to release assignment plugin state lock"
          end
        end)
      end)

    assert_receive :assignment_plugin_state_lock_held

    upsert_task =
      Task.async(fn ->
        result = ServiceStateRegistry.upsert_for_assignment(assignment)
        send(parent, :assignment_state_upsert_done)
        result
      end)

    refute_receive :assignment_state_upsert_done, 250
    send(lock_holder.pid, :release_assignment_plugin_state_lock)
    assert {:ok, :ok} = Task.await(lock_holder, 5_000)
    assert :ok = Task.await(upsert_task, 5_000)
    assert service_state_for(agent, package.name).state == "active"
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

  test "reconcile_plugin_assignments deactivates plugin service rows without enabled assignments" do
    gateway = gateway_fixture()
    current_agent = agent_fixture(gateway, %{uid: unique_id("agent")})
    stale_agent = agent_fixture(gateway, %{uid: unique_id("agent")})
    package = approved_package_fixture("serviceradar.plugin_result.v1")
    _assignment = assignment_fixture(current_agent.uid, package.id)

    stale_state =
      insert_service_state!(%{
        agent_id: stale_agent.uid,
        gateway_id: stale_agent.gateway_id,
        partition: "default",
        service_type: "plugin",
        service_name: package.name,
        available: false,
        message: "old plugin result",
        last_observed_at: DateTime.utc_now(),
        state: "active"
      })

    assert {:ok, count} = ServiceStateRegistry.reconcile_plugin_assignments()
    assert count >= 2

    assert service_state_for(current_agent, package.name).state == "active"
    assert reloaded_state(stale_state).state == "inactive"
  end

  test "reconcile_plugin_assignments preserves active plugin rows matched by emitted plugin_id" do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: unique_id("agent")})
    package = approved_package_fixture("serviceradar.plugin_result.v1")
    _assignment = assignment_fixture(agent.uid, package.id)

    reported_state =
      insert_service_state!(%{
        agent_id: agent.uid,
        gateway_id: agent.gateway_id,
        partition: "default",
        service_type: "plugin",
        service_name: "Runtime Display Name #{System.unique_integer([:positive])}",
        available: true,
        message: "runtime plugin ok",
        details: Jason.encode!(%{"labels" => %{"plugin_id" => package.plugin_id}}),
        last_observed_at: DateTime.utc_now(),
        state: "active"
      })

    assert {:ok, count} = ServiceStateRegistry.reconcile_plugin_assignments()
    assert count >= 1

    assert reloaded_state(reported_state).state == "active"
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

  test "assignment reconciliation preserves agent-reported plugin status from transient gateway ids" do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: unique_id("agent")})
    package = approved_package_fixture("serviceradar.plugin_result.v1")
    assignment = assignment_fixture(agent.uid, package.id)

    assert :ok =
             ServiceStateRegistry.upsert_from_status(%{
               agent_id: agent.uid,
               gateway_id: "serviceradar_agent_gateway@10.42.0.12",
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
    assert state.gateway_id == agent.gateway_id
    assert state.message == "cached plugin result"
    assert [^state] = active_logical_states_for(agent, package.name)
  end

  test "history repair collapses stale active plugin rows without fresh results" do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: unique_id("agent")})
    package = approved_package_fixture("serviceradar.plugin_result.v1")
    _assignment = assignment_fixture(agent.uid, package.id)
    service_name = package.name
    now = DateTime.utc_now()

    insert_service_state!(%{
      agent_id: agent.uid,
      gateway_id: "serviceradar_agent_gateway@10.42.0.10",
      partition: "default",
      service_type: "plugin",
      service_name: service_name,
      available: false,
      message: "old gateway result",
      last_observed_at: DateTime.add(now, -3_600, :second),
      state: "active"
    })

    insert_service_state!(%{
      agent_id: agent.uid,
      gateway_id: "serviceradar_agent_gateway@10.42.0.11",
      partition: "default",
      service_type: "plugin",
      service_name: service_name,
      available: true,
      message: "newer gateway result",
      last_observed_at: now,
      state: "active"
    })

    assert {:ok, count} = ServiceStateRegistry.repair_plugin_states_from_history()
    assert count >= 1

    assert [state] = active_logical_states_for(agent, service_name)
    assert state.gateway_id == "serviceradar_agent_gateway@10.42.0.11"
    assert state.message == "newer gateway result"
  end

  test "history repair preserves the exact gateway from service status history" do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: unique_id("agent")})
    package = approved_package_fixture("serviceradar.plugin_result.v1")
    _assignment = assignment_fixture(agent.uid, package.id)
    historical_gateway_id = "serviceradar_agent_gateway@10.42.0.99"
    observed_at = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:microsecond)

    ServiceStatus
    |> Ash.Changeset.for_create(
      :create,
      %{
        timestamp: observed_at,
        gateway_id: historical_gateway_id,
        agent_id: agent.uid,
        service_name: package.name,
        service_type: "plugin",
        available: true,
        message: "historical plugin result",
        details: Jason.encode!(%{"status" => "OK", "summary" => "historical plugin result"}),
        partition: "default",
        created_at: observed_at
      },
      actor: system_actor()
    )
    |> Ash.create!(domain: ServiceRadar.Observability)

    assert {:ok, count} = ServiceStateRegistry.repair_plugin_states_from_history()
    assert count >= 1

    assert [state] = active_logical_states_for(agent, package.name)
    assert state.gateway_id == historical_gateway_id
    assert state.gateway_id != agent.gateway_id
    assert state.message == "historical plugin result"
  end

  test "history repair reactivates newest inactive exact row and deactivates older gateway" do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: unique_id("agent")})
    package = approved_package_fixture("serviceradar.plugin_result.v1")
    _assignment = assignment_fixture(agent.uid, package.id)
    older_at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)
    newer_at = DateTime.add(older_at, 10, :second)
    newer_gateway_id = "serviceradar_agent_gateway@10.42.0.109"

    older_state =
      insert_service_state!(%{
        agent_id: agent.uid,
        gateway_id: agent.gateway_id,
        partition: "default",
        service_type: "plugin",
        service_name: package.name,
        available: false,
        message: "older critical result",
        last_observed_at: older_at,
        state: "active"
      })

    newer_state =
      insert_service_state!(%{
        agent_id: agent.uid,
        gateway_id: newer_gateway_id,
        partition: "default",
        service_type: "plugin",
        service_name: package.name,
        available: true,
        message: "newest historical result",
        last_observed_at: newer_at,
        state: "inactive"
      })

    ServiceStatus
    |> Ash.Changeset.for_create(
      :create,
      %{
        timestamp: newer_at,
        gateway_id: newer_gateway_id,
        agent_id: agent.uid,
        service_name: package.name,
        service_type: "plugin",
        available: true,
        message: "newest historical result",
        details: Jason.encode!(%{"status" => "OK", "summary" => "newest historical result"}),
        partition: "default",
        created_at: newer_at
      },
      actor: system_actor()
    )
    |> Ash.create!(domain: ServiceRadar.Observability)

    assert {:ok, count} = ServiceStateRegistry.repair_plugin_states_from_history()
    assert count >= 1

    assert reloaded_state(older_state).state == "inactive"

    assert %ServiceState{state: "active", gateway_id: ^newer_gateway_id} =
             reloaded_state(newer_state)
  end

  test "assignment deactivation deactivates every gateway variant" do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: unique_id("agent")})
    package = approved_package_fixture("serviceradar.plugin_result.v1")
    assignment = assignment_fixture(agent.uid, package.id)
    now = DateTime.utc_now()

    states =
      for gateway_id <- [agent.gateway_id, "serviceradar_agent_gateway@10.42.0.88"] do
        insert_service_state!(%{
          agent_id: agent.uid,
          gateway_id: gateway_id,
          partition: "default",
          service_type: "plugin",
          service_name: package.name,
          available: true,
          message: "active plugin result",
          last_observed_at: now,
          state: "active"
        })
      end

    assert :ok = ServiceStateRegistry.deactivate_for_assignment(assignment)
    assert [] = active_logical_states_for(agent, package.name)
    assert Enum.all?(states, &(reloaded_state(&1).state == "inactive"))
  end

  test "package deactivation deactivates every assigned gateway variant" do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: unique_id("agent")})
    package = approved_package_fixture("serviceradar.plugin_result.v1")
    _assignment = assignment_fixture(agent.uid, package.id)
    now = DateTime.utc_now()

    states =
      for gateway_id <- [agent.gateway_id, "serviceradar_agent_gateway@10.42.0.77"] do
        insert_service_state!(%{
          agent_id: agent.uid,
          gateway_id: gateway_id,
          partition: "default",
          service_type: "plugin",
          service_name: package.name,
          available: true,
          message: "active plugin result",
          last_observed_at: now,
          state: "active"
        })
      end

    assert :ok = ServiceStateRegistry.deactivate_for_package(package)
    assert [] = active_logical_states_for(agent, package.name)
    assert Enum.all?(states, &(reloaded_state(&1).state == "inactive"))
  end

  test "package deactivation cleans orphaned gateway variants after assignment deletion" do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: unique_id("agent")})
    package = approved_package_fixture("serviceradar.plugin_result.v1")
    assignment = assignment_fixture(agent.uid, package.id)
    runtime_service_name = "Runtime #{package.name}"
    observed_at = DateTime.utc_now() |> DateTime.add(-5, :second) |> DateTime.truncate(:microsecond)
    previous_handlers = Application.get_env(:serviceradar_core, :plugin_result_handlers)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    on_exit(fn -> restore_env(:plugin_result_handlers, previous_handlers) end)

    payload = %{
      "status" => "OK",
      "summary" => "runtime plugin result",
      "observed_at" => DateTime.to_iso8601(observed_at),
      "labels" => %{"plugin_id" => package.plugin_id},
      "display" => [%{"widget" => "stat_card", "label" => "Objects", "value" => 56}]
    }

    for gateway_id <- [agent.gateway_id, "serviceradar_agent_gateway@10.42.0.66"] do
      assert :ok =
               PluginResultIngestor.ingest(payload, %{
                 source: "plugin-result",
                 agent_id: agent.uid,
                 gateway_id: gateway_id,
                 partition: "default",
                 service_type: "plugin",
                 service_name: runtime_service_name
               })
    end

    states = logical_states_for(agent, runtime_service_name)
    assert length(states) == 2
    assert Enum.count(states, &(&1.state == "active")) == 1

    assert Enum.all?(states, fn state ->
             get_in(Jason.decode!(state.details), ["labels", "plugin_id"]) == package.plugin_id
           end)

    assert :ok = Ash.destroy!(assignment, actor: system_actor(), domain: ServiceRadar.Plugins)
    assert :ok = ServiceStateRegistry.deactivate_for_package(package)
    assert [] = active_logical_states_for(agent, runtime_service_name)
    assert Enum.all?(states, &(reloaded_state(&1).state == "inactive"))
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
    service_state_by_identity(agent, "plugin", service_name)
  end

  defp service_state_by_identity(agent, service_type, service_name) do
    metadata = agent.metadata || %{}

    ServiceState
    |> Ash.Query.for_read(
      :by_identity,
      %{
        agent_id: agent.uid,
        gateway_id: agent.gateway_id,
        partition: metadata["partition"] || "default",
        service_type: service_type,
        service_name: service_name
      },
      actor: system_actor()
    )
    |> Ash.read_one!(domain: ServiceRadar.Observability)
  end

  defp active_logical_states_for(agent, service_name) do
    agent
    |> logical_states_for(service_name)
    |> Enum.filter(&(&1.state == "active"))
  end

  defp logical_states_for(agent, service_name) do
    metadata = agent.metadata || %{}
    partition = metadata["partition"] || "default"

    ServiceState
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      agent_id == ^agent.uid and
        partition == ^partition and
        service_type == "plugin" and
        service_name == ^service_name
    )
    |> Ash.read!(actor: system_actor(), domain: ServiceRadar.Observability)
  end

  defp insert_service_state!(attrs) do
    ServiceState
    |> Ash.Changeset.for_create(:upsert, attrs, actor: system_actor())
    |> Ash.create!(domain: ServiceRadar.Observability)
  end

  defp reloaded_state(%ServiceState{id: id}) do
    ServiceState
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(actor: system_actor(), domain: ServiceRadar.Observability)
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

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
