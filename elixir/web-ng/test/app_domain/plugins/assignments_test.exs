defmodule ServiceRadarWebNG.Plugins.AssignmentsTest do
  use ServiceRadarWebNG.DataCase, async: false

  import ServiceRadarWebNG.AshTestHelpers, only: [system_actor: 0]

  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadarWebNG.Plugins.Assignments
  alias ServiceRadarWebNG.Plugins.Packages

  @manifest %{
    "id" => "assignment-upgrade-test",
    "name" => "Assignment Upgrade Test",
    "version" => "1.0.0",
    "entrypoint" => "run_check",
    "outputs" => "serviceradar.plugin_result.v1",
    "capabilities" => ["get_config"],
    "resources" => %{
      "requested_cpu_ms" => 1000,
      "requested_memory_mb" => 64
    }
  }

  test "delete normalizes bare Ash destroy success into ok tuple" do
    plugin_id = unique_plugin_id("delete")
    _plugin = create_plugin(plugin_id)
    package = plugin_id |> create_package("1.0.0") |> approve_package!()
    assignment = create_assignment!("agent-delete", package.id, enabled: false)

    assert {:ok, deleted} = Assignments.delete(assignment.id, actor: system_actor())
    assert deleted.id == assignment.id
  end

  test "manual assignments can upgrade to a newer approved package in place" do
    plugin_id = unique_plugin_id("upgrade")
    agent_uid = "agent-upgrade-#{System.unique_integer([:positive])}"
    _plugin = create_plugin(plugin_id)

    old_package = plugin_id |> create_package("1.0.0") |> approve_package!()
    assignment = create_assignment!(agent_uid, old_package.id, params: %{"url" => "https://pve.local"})

    new_package = plugin_id |> create_package("1.0.1") |> approve_package!()

    assert {:ok, upgraded} = Assignments.upgrade(assignment.id, new_package.id, actor: system_actor())
    assert upgraded.id == assignment.id
    assert upgraded.plugin_package_id == new_package.id
    assert upgraded.params == %{"url" => "https://pve.local"}
  end

  test "policy-owned assignments cannot be manually upgraded" do
    plugin_id = unique_plugin_id("policy")
    _plugin = create_plugin(plugin_id)

    old_package = plugin_id |> create_package("1.0.0") |> approve_package!()
    assignment = create_assignment!("agent-policy", old_package.id, source: :policy)

    new_package = plugin_id |> create_package("1.0.1") |> approve_package!()

    assert {:error, :policy_owned_assignment} =
             Assignments.upgrade(assignment.id, new_package.id, actor: system_actor())
  end

  test "upgrade clamps numeric params to target schema bounds without resetting assignment state" do
    plugin_id = unique_plugin_id("bounded-upgrade")
    _plugin = create_plugin(plugin_id)

    old_package = plugin_id |> create_package("0.3.1") |> approve_package!()

    target_schema = %{
      "type" => "object",
      "properties" => %{
        "api_key_secret_ref" => %{"type" => "string", "secretRef" => true},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 1_000},
        "max_pages" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
        "max_retries" => %{"type" => "integer", "minimum" => 0, "maximum" => 7},
        "page" => %{"type" => "integer", "minimum" => 1}
      }
    }

    secret_ref = "credentialref:network-credential-secret:#{Ecto.UUID.generate()}"

    params =
      SecretRefs.prepare_params_for_storage(target_schema, %{
        "api_key_secret_ref" => secret_ref,
        "cursor_complete" => false,
        "cursor_next" => "https://otx.alienvault.com/api/v1/indicators/export?limit=125&page=178",
        "limit" => 125,
        "max_pages" => 5_000,
        "max_retries" => -1,
        "page" => 177,
        "unrelated" => %{"max_pages" => 5_000}
      })

    assignment = create_assignment!("agent-otx", old_package.id, params: params)

    new_package =
      plugin_id
      |> create_package("0.3.2", config_schema: target_schema)
      |> approve_package!()

    assert {:ok, upgraded} =
             Assignments.upgrade(assignment.id, new_package.id, actor: system_actor())

    assert upgraded.params == %{
             "api_key_secret_ref" => secret_ref,
             "cursor_complete" => false,
             "cursor_next" => "https://otx.alienvault.com/api/v1/indicators/export?limit=125&page=178",
             "limit" => 125,
             "max_pages" => 100,
             "max_retries" => 0,
             "page" => 177,
             "unrelated" => %{"max_pages" => 5_000}
           }
  end

  defp unique_plugin_id(prefix), do: "assignment-#{prefix}-#{System.unique_integer([:positive])}"

  defp create_plugin(plugin_id) do
    Plugin
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: plugin_id,
        name: "Assignment Upgrade Test",
        description: "Test plugin"
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end

  defp create_package(plugin_id, version, opts \\ []) do
    manifest = %{@manifest | "id" => plugin_id, "version" => version}

    PluginPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: plugin_id,
        name: "Assignment Upgrade Test",
        version: version,
        entrypoint: "run_check",
        outputs: "serviceradar.plugin_result.v1",
        manifest: manifest,
        config_schema: Keyword.get(opts, :config_schema, %{}),
        signature: %{},
        source_type: :github,
        source_commit: "test-#{plugin_id}-#{version}"
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end

  defp approve_package!(%PluginPackage{} = package) do
    {:ok, approved} = Packages.approve(package.id, %{}, actor: system_actor())
    approved
  end

  defp create_assignment!(agent_uid, package_id, opts) do
    source = Keyword.get(opts, :source, :manual)

    attrs = %{
      agent_uid: "#{agent_uid}-#{System.unique_integer([:positive])}",
      plugin_package_id: package_id,
      source: source,
      source_key: source_key(source),
      policy_id: policy_id(source),
      enabled: Keyword.get(opts, :enabled, true),
      interval_seconds: 60,
      timeout_seconds: 10,
      params: Keyword.get(opts, :params, %{})
    }

    PluginAssignment
    |> Ash.Changeset.for_create(:create, attrs, actor: system_actor())
    |> Ash.create!()
  end

  defp source_key(:policy), do: "policy:#{System.unique_integer([:positive])}"
  defp source_key(_source), do: nil

  defp policy_id(:policy), do: "policy-#{System.unique_integer([:positive])}"
  defp policy_id(_source), do: nil
end
