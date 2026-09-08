defmodule ServiceRadar.Plugins.PluginAssignmentTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PolicyAssignmentReconciler
  alias ServiceRadar.ProcessRegistry

  require Ash.Query

  @moduletag :integration

  defmodule SingleRowResolver do
    @moduledoc false

    def resolve(_input_defs, opts) do
      agent_uid = Keyword.fetch!(opts, :target_agent_uid)

      {:ok,
       [
         %{
           name: "devices",
           entity: "devices",
           query: "in:devices",
           rows: [%{"uid" => "sr:test-device", "agent_id" => agent_uid}]
         }
       ]}
    end
  end

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    unique_id = :erlang.unique_integer([:positive])

    actor = %{
      id: Ash.UUID.generate(),
      email: "test@serviceradar.local",
      role: :admin
    }

    {:ok, actor: actor, unique_id: unique_id}
  end

  test "manual assignments cannot shadow enabled policy assignments", %{
    actor: actor,
    unique_id: unique_id
  } do
    plugin_id = "duplicate-guard-#{unique_id}"
    agent_uid = "agent-duplicate-guard-#{unique_id}"
    register_control_session!(agent_uid, "farm01")
    {:ok, package} = create_approved_package(actor, plugin_id)

    assert {:ok, _policy_assignment} =
             PluginAssignment
             |> Ash.Changeset.for_create(
               :create,
               %{
                 agent_uid: agent_uid,
                 plugin_package_id: package.id,
                 source: :policy,
                 source_key: "policy:#{unique_id}",
                 policy_id: "policy-#{unique_id}",
                 enabled: true,
                 interval_seconds: 300,
                 timeout_seconds: 30,
                 params: %{}
               },
               actor: actor
             )
             |> Ash.create()

    assert {:error, error} =
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
               actor: actor
             )
             |> Ash.create()

    assert Exception.message(error) =~ "plugin is already assigned to this agent by policy"
  end

  test "manual create names the agent when no live control session exists", %{
    actor: actor,
    unique_id: unique_id
  } do
    plugin_id = "offline-assignment-#{unique_id}"
    agent_uid = "agent-offline-assignment-#{unique_id}"
    {:ok, package} = create_approved_package(actor, plugin_id)

    assert {:error, error} =
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
               actor: actor
             )
             |> Ash.create()

    message = Exception.message(error)
    assert message =~ agent_uid
    assert message =~ "no live authenticated control session"
  end

  test "agents cannot have two enabled assignments for one plugin", %{
    actor: actor,
    unique_id: unique_id
  } do
    plugin_id = "single-enabled-assignment-#{unique_id}"
    agent_uid = "agent-single-enabled-assignment-#{unique_id}"
    register_control_session!(agent_uid, "farm01")
    {:ok, package} = create_approved_package(actor, plugin_id)

    assert {:ok, assignment} =
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
               actor: actor
             )
             |> Ash.create()

    assert assignment.plugin_id == plugin_id

    assert {:error, error} =
             PluginAssignment
             |> Ash.Changeset.for_create(
               :create,
               %{
                 agent_uid: agent_uid,
                 plugin_package_id: package.id,
                 source: :policy,
                 source_key: "single-enabled-assignment:#{unique_id}",
                 policy_id: "single-enabled-assignment-#{unique_id}",
                 enabled: true,
                 interval_seconds: 300,
                 timeout_seconds: 30,
                 params: %{}
               },
               actor: actor
             )
             |> Ash.create()

    assert Exception.message(error) =~ "plugin is already enabled for this agent"
  end

  test "disabled duplicate assignments are allowed but not active", %{
    actor: actor,
    unique_id: unique_id
  } do
    plugin_id = "disabled-duplicate-assignment-#{unique_id}"
    agent_uid = "agent-disabled-duplicate-assignment-#{unique_id}"
    register_control_session!(agent_uid, "farm01")
    {:ok, package} = create_approved_package(actor, plugin_id)

    assert {:ok, _active} =
             PluginAssignment
             |> Ash.Changeset.for_create(
               :create,
               %{
                 agent_uid: agent_uid,
                 plugin_package_id: package.id,
                 enabled: true,
                 interval_seconds: 60,
                 timeout_seconds: 10,
                 params: %{}
               },
               actor: actor
             )
             |> Ash.create()

    assert {:ok, disabled} =
             PluginAssignment
             |> Ash.Changeset.for_create(
               :create,
               %{
                 agent_uid: agent_uid,
                 plugin_package_id: package.id,
                 source: :policy,
                 source_key: "disabled-duplicate-assignment:#{unique_id}",
                 policy_id: "disabled-duplicate-assignment-#{unique_id}",
                 enabled: false,
                 interval_seconds: 300,
                 timeout_seconds: 30,
                 params: %{}
               },
               actor: actor
             )
             |> Ash.create()

    assert disabled.plugin_id == plugin_id
    assert disabled.enabled == false
  end

  test "policy assignments can move to a newer approved package", %{
    actor: actor,
    unique_id: unique_id
  } do
    plugin_id = "policy-package-update-#{unique_id}"
    agent_uid = "agent-policy-package-update-#{unique_id}"
    register_control_session!(agent_uid, "farm01")
    {:ok, old_package} = create_approved_package(actor, plugin_id)
    {:ok, new_package} = create_package_version(actor, plugin_id, "1.0.1")

    {:ok, assignment} =
      PluginAssignment
      |> Ash.Changeset.for_create(
        :create,
        %{
          agent_uid: agent_uid,
          plugin_package_id: old_package.id,
          source: :policy,
          source_key: "policy-package-update:#{unique_id}",
          policy_id: "policy-package-update-#{unique_id}",
          enabled: true,
          interval_seconds: 300,
          timeout_seconds: 30,
          params: %{}
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, _revoked_old} =
      old_package
      |> Ash.Changeset.for_update(
        :revoke,
        %{denied_reason: "superseded by package update test"},
        actor: actor
      )
      |> Ash.update()

    {:ok, new_package} = approve_package(actor, new_package)

    assert {:ok, updated} =
             assignment
             |> Ash.Changeset.for_update(
               :update,
               %{plugin_package_id: new_package.id},
               actor: actor
             )
             |> Ash.update()

    assert updated.plugin_package_id == new_package.id
  end

  test "policy reconciler adopts manual assignment from older package version", %{
    actor: actor,
    unique_id: unique_id
  } do
    plugin_id = "policy-adopts-manual-#{unique_id}"
    agent_uid = "agent-policy-adopts-manual-#{unique_id}"
    register_control_session!(agent_uid, "farm01")
    {:ok, old_package} = create_approved_package(actor, plugin_id)
    {:ok, new_package} = create_package_version(actor, plugin_id, "1.0.1")

    {:ok, manual_assignment} =
      PluginAssignment
      |> Ash.Changeset.for_create(
        :create,
        %{
          agent_uid: agent_uid,
          plugin_package_id: old_package.id,
          source: :manual,
          enabled: true,
          interval_seconds: 60,
          timeout_seconds: 10,
          params: %{"legacy" => true}
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, _revoked_old} =
      old_package
      |> Ash.Changeset.for_update(
        :revoke,
        %{denied_reason: "superseded by policy adoption test"},
        actor: actor
      )
      |> Ash.update()

    {:ok, new_package} = approve_package(actor, new_package)

    policy = %{
      policy_id: "policy-adopts-manual-#{unique_id}",
      policy_version: 1,
      plugin_package_id: new_package.id,
      params_template: %{"collect" => true},
      interval_seconds: 300,
      timeout_seconds: 30,
      enabled: true
    }

    assert {:ok, stats} =
             PolicyAssignmentReconciler.reconcile(policy, [],
               actor: actor,
               resolver: SingleRowResolver,
               target_agent_uid: agent_uid,
               generated_at: "2026-07-05T00:00:00Z"
             )

    assert stats.upserted == 1

    assert {:ok, [assignment]} =
             PluginAssignment
             |> Ash.Query.for_read(
               :by_agent,
               %{agent_uid: agent_uid, partition_id: manual_assignment.partition_id},
               actor: actor
             )
             |> Ash.Query.filter(plugin_id == ^plugin_id and enabled == true)
             |> Ash.read(actor: actor)

    assert assignment.id == manual_assignment.id
    assert assignment.source == :policy
    assert assignment.policy_id == policy.policy_id
    assert assignment.plugin_package_id == new_package.id
    refute assignment.params["legacy"]
  end

  test "same UID and source key resolve only inside the authenticated partition", %{
    actor: actor,
    unique_id: unique_id
  } do
    plugin_id = "partition-source-key-#{unique_id}"
    agent_uid = "agent-partition-source-key-#{unique_id}"
    source_key = "shared-source-key:#{unique_id}"
    {:ok, package} = create_approved_package(actor, plugin_id)

    register_control_session!(agent_uid, "farm01")
    assert {:ok, farm} = create_policy_assignment(actor, package, agent_uid, source_key)
    unregister_control_session!("farm01", agent_uid)
    register_control_session!(agent_uid, "tonka01")
    assert {:ok, tonka} = create_policy_assignment(actor, package, agent_uid, source_key)

    assert farm.id != tonka.id
    assert farm.partition_id == "farm01"
    assert tonka.partition_id == "tonka01"

    assert {:ok, %PluginAssignment{id: farm_id}} =
             read_by_partition_source_key(actor, "farm01", source_key)

    assert farm_id == farm.id

    assert {:ok, %PluginAssignment{id: tonka_id}} =
             read_by_partition_source_key(actor, "tonka01", source_key)

    assert tonka_id == tonka.id
    assert {:ok, nil} = read_by_partition_source_key(actor, "other", source_key)
  end

  defp create_policy_assignment(actor, package, agent_uid, source_key) do
    PluginAssignment
    |> Ash.Changeset.for_create(
      :create,
      %{
        agent_uid: agent_uid,
        plugin_package_id: package.id,
        source: :policy,
        source_key: source_key,
        policy_id: "policy-#{source_key}",
        enabled: true,
        interval_seconds: 300,
        timeout_seconds: 30,
        params: %{}
      },
      actor: actor
    )
    |> Ash.create()
  end

  defp read_by_partition_source_key(actor, partition_id, source_key) do
    PluginAssignment
    |> Ash.Query.for_read(
      :by_partition_source_key,
      %{partition_id: partition_id, source: :policy, source_key: source_key},
      actor: actor
    )
    |> Ash.read_one(actor: actor)
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

  defp unregister_control_session!(partition_id, agent_uid) do
    :ok = ProcessRegistry.unregister({:agent_control, partition_id, agent_uid, node()})
    assert_control_session_absent(agent_uid, 40)
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

  defp assert_control_session_absent(_agent_uid, 0),
    do: flunk("control-session removal did not converge")

  defp assert_control_session_absent(agent_uid, attempts) do
    case AgentCommandBus.resolve_control_session_evidence(agent_uid) do
      {:error, _reason} ->
        :ok

      _other ->
        Process.sleep(10)
        assert_control_session_absent(agent_uid, attempts - 1)
    end
  end

  defp create_approved_package(actor, plugin_id) do
    {:ok, _plugin} =
      Plugin
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: plugin_id,
          name: "Duplicate Guard"
        },
        actor: actor
      )
      |> Ash.create()

    with {:ok, package} <- create_package_version(actor, plugin_id, "1.0.0") do
      approve_package(actor, package)
    end
  end

  defp create_package_version(actor, plugin_id, version) do
    manifest = %{
      "id" => plugin_id,
      "name" => "Duplicate Guard",
      "version" => version,
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

    PluginPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: plugin_id,
        name: "Duplicate Guard",
        version: version,
        entrypoint: "run_check",
        runtime: "wasi-preview1",
        outputs: "serviceradar.plugin_result.v1",
        manifest: manifest,
        config_schema: %{},
        display_contract: %{},
        content_hash: "sha256:#{plugin_id}:#{version}",
        signature: %{},
        source_type: :upload
      },
      actor: actor
    )
    |> Ash.create()
  end

  defp approve_package(actor, package) do
    package
    |> Ash.Changeset.for_update(:approve, %{approved_by: "test"}, actor: actor)
    |> Ash.update()
  end
end
