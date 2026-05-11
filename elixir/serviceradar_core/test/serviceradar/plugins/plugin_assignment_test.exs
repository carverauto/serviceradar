defmodule ServiceRadar.Plugins.PluginAssignmentTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage

  @moduletag :integration

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

  defp create_approved_package(actor, plugin_id) do
    manifest = %{
      "id" => plugin_id,
      "name" => "Duplicate Guard",
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

    {:ok, package} =
      PluginPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: plugin_id,
          name: "Duplicate Guard",
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
        actor: actor
      )
      |> Ash.create()

    package
    |> Ash.Changeset.for_update(:approve, %{approved_by: "test"}, actor: actor)
    |> Ash.update()
  end
end
