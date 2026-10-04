defmodule ServiceRadar.Plugins.RunOverridesDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PluginRunOverride
  alias ServiceRadar.Plugins.RunOverrides
  alias ServiceRadar.ProcessRegistry

  require Ash.Query

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    unique_id = :erlang.unique_integer([:positive])
    admin = %{id: Ash.UUID.generate(), email: "test@serviceradar.local", role: :admin}
    system = SystemActor.system(:run_overrides_db_test)

    agent_uid = "agent-run-overrides-#{unique_id}"
    partition_id = "partition-#{unique_id}"
    register_control_session!(agent_uid, partition_id)

    on_exit(fn ->
      ProcessRegistry.unregister({:agent_control, partition_id, agent_uid, node()})
    end)

    {:ok, package} = create_approved_package(admin, "run-overrides-#{unique_id}")

    {:ok, assignment} =
      PluginAssignment
      |> Ash.Changeset.for_create(
        :create,
        %{
          agent_uid: agent_uid,
          plugin_package_id: package.id,
          source: :manual,
          enabled: true,
          interval_seconds: 60,
          timeout_seconds: 10,
          params: %{}
        },
        actor: admin
      )
      |> Ash.create()

    {:ok, system: system, assignment_id: to_string(assignment.id)}
  end

  test "a set operation is clamped to the descriptor maximum and delivered", %{
    system: system,
    assignment_id: assignment_id
  } do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    payload = %{
      "status" => "succeeded",
      "run_overrides" => [
        %{
          "op" => "set",
          "id" => "fault-jam-7",
          "kind" => "conveyor_jam",
          "target" => "conveyor-7",
          "params" => %{"severity" => "critical"},
          "duration_seconds" => 3600
        }
      ]
    }

    assert {:ok, 1} =
             RunOverrides.apply_action_result(payload, %{"plugin_assignment_id" => assignment_id},
               actor: system,
               max_override_duration_seconds: 300,
               now: now
             )

    assert %{^assignment_id => [delivered]} =
             RunOverrides.deliverable_by_assignment([assignment_id], actor: system)

    assert delivered["id"] == "fault-jam-7"
    assert delivered["target"] == "conveyor-7"
    assert delivered["params"] == %{"severity" => "critical"}
    assert {:ok, expires_at, 0} = DateTime.from_iso8601(delivered["expires_at"])
    assert DateTime.diff(expires_at, now) == 300
  end

  test "ending an override stops delivery until the same id is set again", %{
    system: system,
    assignment_id: assignment_id
  } do
    context = %{plugin_assignment_id: assignment_id}
    set = %{"op" => "set", "id" => "fault-1", "kind" => "jam", "duration_seconds" => 60}

    assert {:ok, 1} =
             RunOverrides.apply_action_result(%{"run_overrides" => [set]}, context,
               actor: system,
               max_override_duration_seconds: 600
             )

    assert {:ok, 1} =
             RunOverrides.apply_action_result(
               %{"run_overrides" => [%{"op" => "end", "id" => "fault-1"}]},
               context,
               actor: system,
               max_override_duration_seconds: 600
             )

    assert RunOverrides.deliverable_by_assignment([assignment_id], actor: system) == %{}

    assert {:ok, 1} =
             RunOverrides.apply_action_result(%{"run_overrides" => [set]}, context,
               actor: system,
               max_override_duration_seconds: 600
             )

    assert %{^assignment_id => [%{"id" => "fault-1"}]} =
             RunOverrides.deliverable_by_assignment([assignment_id], actor: system)
  end

  test "setting an acknowledged override id again delivers it again", %{
    system: system,
    assignment_id: assignment_id
  } do
    context = %{plugin_assignment_id: assignment_id}
    set = %{"op" => "set", "id" => "fault-1", "kind" => "jam", "duration_seconds" => 60}
    now = DateTime.utc_now()

    assert {:ok, _} =
             PluginRunOverride.record(
               %{
                 plugin_assignment_id: assignment_id,
                 override_id: "fault-1",
                 kind: "jam",
                 starts_at: DateTime.add(now, -600),
                 expires_at: DateTime.add(now, -60)
               },
               actor: system
             )

    assert :ok = RunOverrides.acknowledge(assignment_id, ["fault-1"], actor: system)
    assert RunOverrides.deliverable_by_assignment([assignment_id], actor: system) == %{}

    assert {:ok, 1} =
             RunOverrides.apply_action_result(%{"run_overrides" => [set]}, context,
               actor: system,
               max_override_duration_seconds: 600
             )

    assert %{^assignment_id => [%{"id" => "fault-1"}]} =
             RunOverrides.deliverable_by_assignment([assignment_id], actor: system)
  end

  test "only expired overrides are acknowledged", %{
    system: system,
    assignment_id: assignment_id
  } do
    now = DateTime.utc_now()

    for {id, starts_at, expires_at} <- [
          {"expired", DateTime.add(now, -600), DateTime.add(now, -60)},
          {"active", DateTime.add(now, -60), DateTime.add(now, 600)}
        ] do
      assert {:ok, _} =
               PluginRunOverride.record(
                 %{
                   plugin_assignment_id: assignment_id,
                   override_id: id,
                   kind: "jam",
                   starts_at: starts_at,
                   expires_at: expires_at
                 },
                 actor: system
               )
    end

    assert :ok = RunOverrides.acknowledge(assignment_id, ["expired", "active"], actor: system)

    assert %{^assignment_id => [remaining]} =
             RunOverrides.deliverable_by_assignment([assignment_id], actor: system)

    assert remaining["id"] == "active"
  end

  defp register_control_session!(agent_uid, partition_id) do
    assert {:ok, _pid} =
             ProcessRegistry.register(
               {:agent_control, partition_id, agent_uid, node()},
               %{
                 agent_id: agent_uid,
                 partition_id: partition_id,
                 gateway_node: node(),
                 capabilities: ["wasm"]
               }
             )

    assert_control_partition(agent_uid, partition_id, 40)
  end

  defp assert_control_partition(_agent_uid, _partition_id, 0),
    do: flunk("control-session partition did not converge")

  defp assert_control_partition(agent_uid, partition_id, attempts) do
    case AgentCommandBus.resolve_control_session_evidence(partition_id, agent_uid, nil) do
      {:ok, %{agent_id: ^agent_uid, partition_id: ^partition_id}} ->
        :ok

      _other ->
        Process.sleep(10)
        assert_control_partition(agent_uid, partition_id, attempts - 1)
    end
  end

  defp create_approved_package(actor, plugin_id) do
    {:ok, _plugin} =
      Plugin
      |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: "Run Overrides"},
        actor: actor
      )
      |> Ash.create()

    manifest = %{
      "id" => plugin_id,
      "name" => "Run Overrides",
      "version" => "1.0.0",
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "capabilities" => ["submit_result"],
      "outputs" => "serviceradar.plugin_result.v1",
      "resources" => %{
        "requested_memory_mb" => 32,
        "requested_cpu_ms" => 100,
        "max_open_connections" => 1
      }
    }

    {:ok, package} =
      PluginPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: plugin_id,
          name: "Run Overrides",
          version: "1.0.0",
          entrypoint: "run_check",
          runtime: "wasi-preview1",
          outputs: "serviceradar.plugin_result.v1",
          manifest: manifest,
          config_schema: %{},
          display_contract: %{},
          content_hash: "sha256:#{plugin_id}:1.0.0",
          signature: %{},
          source_type: :upload
        },
        actor: actor
      )
      |> Ash.create()

    package
    |> Ash.Changeset.for_update(:approve, %{approved_by: "test"}, actor: actor)
    |> Ash.update()
  end
end
