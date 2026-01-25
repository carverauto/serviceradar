defmodule ServiceRadarWebNG.Plugins.PackagePolicyTest do
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Plugins.{Plugin, PluginAssignment, PluginPackage}
  alias ServiceRadarWebNG.Plugins

  @manifest %{
    "id" => "http-check",
    "name" => "HTTP Check",
    "version" => "1.0.0",
    "entrypoint" => "run_check",
    "outputs" => "serviceradar.plugin_result.v1",
    "capabilities" => ["submit_result"],
    "resources" => %{
      "requested_cpu_ms" => 1000,
      "requested_memory_mb" => 64
    },
    "permissions" => %{"allowed_domains" => []}
  }

  setup do
    original_policy = Application.get_env(:serviceradar_web_ng, :plugin_verification)

    on_exit(fn ->
      if is_nil(original_policy) do
        Application.delete_env(:serviceradar_web_ng, :plugin_verification)
      else
        Application.put_env(:serviceradar_web_ng, :plugin_verification, original_policy)
      end
    end)

    :ok
  end

  test "blocks approval for github packages without gpg verification" do
    Application.put_env(:serviceradar_web_ng, :plugin_verification,
      require_gpg_for_github: true,
      allow_unsigned_uploads: true
    )

    _plugin = create_plugin()
    package = create_package(%{source_type: :github, gpg_verified_at: nil})

    assert {:error, :verification_required} =
             Plugins.approve_package(package.id, %{}, scope: nil, approved_by: "admin")
  end

  test "blocks assignments for non-approved packages" do
    _plugin = create_plugin()
    package = create_package(%{source_type: :upload})

    changeset =
      PluginAssignment
      |> Ash.Changeset.for_create(
        :create,
        %{agent_uid: "agent-1", plugin_package_id: package.id},
        actor: system_actor()
      )

    assert {:error, error} = Ash.create(changeset)
    assert has_error?(error, :plugin_package_id)
  end

  defp create_plugin do
    Plugin
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: "http-check",
        name: "HTTP Check",
        description: "Test plugin"
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end

  defp create_package(attrs) do
    defaults = %{
      plugin_id: "http-check",
      name: "HTTP Check",
      version: "1.0.0",
      entrypoint: "run_check",
      outputs: "serviceradar.plugin_result.v1",
      manifest: @manifest,
      config_schema: %{},
      signature: %{}
    }

    PluginPackage
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs), actor: system_actor())
    |> Ash.create!()
  end

  defp has_error?(%Ash.Error.Invalid{errors: errors}, field) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidAttribute{field: ^field} -> true
      %Ash.Error.Changes.Required{field: ^field} -> true
      _ -> false
    end)
  end

  defp has_error?(_, _), do: false
end
