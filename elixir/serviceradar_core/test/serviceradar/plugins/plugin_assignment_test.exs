defmodule ServiceRadar.Plugins.PluginAssignmentTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PolicyAssignmentReconciler

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

  test "agents cannot have two enabled assignments for one plugin", %{
    actor: actor,
    unique_id: unique_id
  } do
    plugin_id = "single-enabled-assignment-#{unique_id}"
    agent_uid = "agent-single-enabled-assignment-#{unique_id}"
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
             |> Ash.Query.for_read(:by_agent, %{agent_uid: agent_uid}, actor: actor)
             |> Ash.Query.filter(plugin_id == ^plugin_id and enabled == true)
             |> Ash.read(actor: actor)

    assert assignment.id == manual_assignment.id
    assert assignment.source == :policy
    assert assignment.policy_id == policy.policy_id
    assert assignment.plugin_package_id == new_package.id
    refute assignment.params["legacy"]
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
