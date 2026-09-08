defmodule ServiceRadar.Observability.ServiceStateRegistryConsistencyTest do
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Observability.ServiceState
  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Observability.ServiceStatus
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage

  require Ash.Query

  test "assignment deactivation finds runtime service names through plugin_id" do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: unique_id("agent")})
    package = approved_package_fixture()
    assignment = assignment_fixture(agent.uid, package.id)
    observed_at = DateTime.truncate(DateTime.utc_now(), :microsecond)
    runtime_name = "Runtime #{package.name}"

    target_states = [
      insert_state!(%{
        agent_id: agent.uid,
        gateway_id: agent.gateway_id,
        partition: "default",
        service_type: "plugin",
        service_name: runtime_name,
        available: true,
        message: "runtime result",
        details: Jason.encode!(%{"labels" => %{"plugin_id" => package.plugin_id}}),
        last_observed_at: observed_at,
        state: "active"
      }),
      insert_state!(%{
        agent_id: agent.uid,
        gateway_id: "gateway-runtime-alternate",
        partition: "default",
        service_type: "plugin",
        service_name: runtime_name,
        available: true,
        message: "legacy runtime result",
        details:
          Jason.encode!(%{
            "reported_result" => %{"labels" => %{"plugin_id" => package.plugin_id}}
          }),
        last_observed_at: observed_at,
        state: "active"
      }),
      insert_state!(%{
        agent_id: agent.uid,
        gateway_id: agent.gateway_id,
        partition: "default",
        service_type: "plugin",
        service_name: package.name,
        available: false,
        message: "plugin assignment pending result",
        last_observed_at: observed_at,
        state: "active"
      })
    ]

    unrelated =
      insert_state!(%{
        agent_id: agent.uid,
        gateway_id: agent.gateway_id,
        partition: "default",
        service_type: "plugin",
        service_name: "Unrelated runtime plugin",
        available: true,
        message: "unrelated result",
        details: Jason.encode!(%{"labels" => %{"plugin_id" => unique_id("other-plugin")}}),
        last_observed_at: observed_at,
        state: "active"
      })

    assert :ok = ServiceStateRegistry.deactivate_for_assignment(assignment)
    assert Enum.all?(target_states, &(reload_state!(&1).state == "inactive"))
    assert reload_state!(unrelated).state == "active"
  end

  test "bulk cleanup applies the same semantic winner order as live ingestion" do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: unique_id("agent")})
    package = approved_package_fixture()
    _assignment = assignment_fixture(agent.uid, package.id)
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    real_result =
      insert_state!(%{
        agent_id: agent.uid,
        gateway_id: "gateway-real",
        partition: "default",
        service_type: "plugin",
        service_name: package.name,
        available: true,
        message: "real result",
        last_observed_at: DateTime.add(now, -60, :second),
        state: "active"
      })

    placeholder =
      insert_state!(%{
        agent_id: agent.uid,
        gateway_id: "gateway-placeholder",
        partition: "default",
        service_type: "plugin",
        service_name: package.name,
        available: false,
        message: "plugin assignment pending result",
        last_observed_at: now,
        state: "active"
      })

    runtime_name = "Equal-time #{package.name}"
    plugin_details = Jason.encode!(%{"labels" => %{"plugin_id" => package.plugin_id}})

    healthy =
      insert_state!(%{
        agent_id: agent.uid,
        gateway_id: "gateway-z-healthy",
        partition: "default",
        service_type: "plugin",
        service_name: runtime_name,
        available: true,
        message: "healthy result",
        details: plugin_details,
        last_observed_at: now,
        state: "active"
      })

    unavailable =
      insert_state!(%{
        agent_id: agent.uid,
        gateway_id: "gateway-a-unavailable",
        partition: "default",
        service_type: "plugin",
        service_name: runtime_name,
        available: false,
        message: "critical result",
        details: plugin_details,
        last_observed_at: now,
        state: "inactive"
      })

    assert {:ok, _count} = ServiceStateRegistry.reconcile_plugin_assignments()

    assert reload_state!(real_result).state == "active"
    assert reload_state!(placeholder).state == "inactive"
    assert reload_state!(healthy).state == "inactive"
    assert reload_state!(unavailable).state == "active"
  end

  test "cold history rebuild chooses unavailable equal-time rows in either insertion order" do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: unique_id("agent")})
    package = approved_package_fixture()
    _assignment = assignment_fixture(agent.uid, package.id)
    observed_at = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:microsecond)

    for {runtime_name, availability_order} <- [
          {"History A #{package.name}", [true, false]},
          {"History B #{package.name}", [false, true]}
        ] do
      Enum.each(availability_order, fn available ->
        insert_history!(%{
          timestamp: observed_at,
          gateway_id: if(available, do: "gateway-healthy", else: "gateway-unavailable"),
          agent_id: agent.uid,
          service_name: runtime_name,
          service_type: "plugin",
          available: available,
          message: if(available, do: "healthy history", else: "critical history"),
          details:
            Jason.encode!(%{
              "labels" => %{"plugin_id" => package.plugin_id},
              "status" => if(available, do: "OK", else: "CRITICAL")
            }),
          partition: "default",
          created_at: observed_at
        })
      end)
    end

    assert {:ok, _count} =
             ServiceStateRegistry.repair_plugin_states_from_history(
               interval: "1 hour",
               batch_size: 1
             )

    for runtime_name <- ["History A #{package.name}", "History B #{package.name}"] do
      assert [%ServiceState{} = winner] = active_states(agent.uid, runtime_name)
      assert winner.available == false
      assert winner.gateway_id == "gateway-unavailable"
      assert winner.message == "critical history"
    end
  end

  test "bulk cleanup leaves revoked-package states inactive without rewrite churn" do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: unique_id("agent")})
    package = approved_package_fixture()
    _assignment = assignment_fixture(agent.uid, package.id)
    observed_at = DateTime.truncate(DateTime.utc_now(), :microsecond)

    state =
      insert_state!(%{
        agent_id: agent.uid,
        gateway_id: agent.gateway_id,
        partition: "default",
        service_type: "plugin",
        service_name: package.name,
        available: true,
        message: "approved runtime result",
        details: Jason.encode!(%{"labels" => %{"plugin_id" => package.plugin_id}}),
        last_observed_at: observed_at,
        state: "active"
      })

    package
    |> Ash.Changeset.for_update(:revoke, %{denied_reason: "test revoke"}, actor: system_actor())
    |> Ash.update!()

    assert {:ok, _count} = ServiceStateRegistry.reconcile_plugin_assignments()

    first_cleanup = reload_state!(state)
    assert first_cleanup.state == "inactive"

    assert {:ok, _count} = ServiceStateRegistry.reconcile_plugin_assignments()

    second_cleanup = reload_state!(state)
    assert second_cleanup.state == "inactive"
    assert second_cleanup.updated_at == first_cleanup.updated_at
  end

  defp active_states(agent_uid, service_name) do
    ServiceState
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      agent_id == ^agent_uid and service_type == "plugin" and service_name == ^service_name and
        state == "active"
    )
    |> Ash.read!(actor: system_actor(), domain: ServiceRadar.Observability)
  end

  defp insert_state!(attrs) do
    ServiceState
    |> Ash.Changeset.for_create(:upsert, attrs, actor: system_actor())
    |> Ash.create!(domain: ServiceRadar.Observability)
  end

  defp insert_history!(attrs) do
    ServiceStatus
    |> Ash.Changeset.for_create(:create, attrs, actor: system_actor())
    |> Ash.create!(domain: ServiceRadar.Observability)
  end

  defp reload_state!(%ServiceState{id: id}) do
    ServiceState
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(actor: system_actor(), domain: ServiceRadar.Observability)
  end

  defp approved_package_fixture do
    plugin_id = unique_id("service-state-contract-plugin")
    name = "Service State Contract #{System.unique_integer([:positive])}"

    Plugin
    |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: name}, actor: system_actor())
    |> Ash.create!()

    manifest = %{
      "id" => plugin_id,
      "name" => name,
      "version" => "1.0.0",
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "outputs" => "serviceradar.plugin_result.v1",
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
        outputs: "serviceradar.plugin_result.v1",
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
