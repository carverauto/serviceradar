defmodule ServiceRadarWebNGWeb.Api.PluginPackageControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers, only: [system_actor: 0]

  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadarWebNG.Plugins.Storage

  @manifest %{
    "id" => "unifi-protect-camera",
    "name" => "UniFi Protect Camera",
    "version" => "0.1.0",
    "entrypoint" => "run_check",
    "outputs" => "serviceradar.plugin_result.v1",
    "capabilities" => ["get_config", "submit_result"],
    "resources" => %{
      "requested_cpu_ms" => 1000,
      "requested_memory_mb" => 64
    },
    "permissions" => %{"allowed_domains" => ["192.168.1.1"]}
  }

  setup do
    original = Application.get_env(:serviceradar_web_ng, :plugin_storage)
    tmp = Path.join(System.tmp_dir!(), "sr-plugin-storage-#{System.unique_integer([:positive])}")

    Application.put_env(:serviceradar_web_ng, :plugin_storage,
      backend: :filesystem,
      base_path: tmp,
      signing_secret: "test-secret"
    )

    on_exit(fn ->
      File.rm_rf(tmp)

      if is_nil(original) do
        Application.delete_env(:serviceradar_web_ng, :plugin_storage)
      else
        Application.put_env(:serviceradar_web_ng, :plugin_storage, original)
      end
    end)

    :ok
  end

  test "PUT /api/plugin-packages/:id/blob updates the package content hash", %{conn: _conn} do
    _plugin = create_plugin()
    package = create_package()
    object_key = Storage.object_key_for(package)
    payload = "updated-wasm-binary"
    {token, _expires_at} = Storage.sign_token(:upload, package.id, object_key, 300)

    package =
      package
      |> Ash.Changeset.for_update(:update, %{wasm_object_key: object_key}, actor: system_actor())
      |> Ash.update!(actor: system_actor())

    conn =
      "PUT"
      |> Plug.Test.conn("/api/plugin-packages/#{package.id}/blob?token=#{token}", payload)
      |> Plug.Conn.put_req_header("content-type", "application/wasm")
      |> ServiceRadarWebNGWeb.Endpoint.call([])

    assert conn.status == 201

    updated = reload_package(package.id)
    assert updated.content_hash == Storage.sha256(payload)
    assert updated.wasm_object_key == object_key
    assert Storage.blob_exists?(object_key)
  end

  defp reload_package(id) do
    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(actor: system_actor())
  end

  defp create_plugin do
    Plugin
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: "unifi-protect-camera",
        name: "UniFi Protect Camera",
        description: "Test plugin"
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end

  defp create_package do
    PluginPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: "unifi-protect-camera",
        name: "UniFi Protect Camera",
        version: "0.1.0",
        entrypoint: "run_check",
        outputs: "serviceradar.plugin_result.v1",
        manifest: @manifest,
        config_schema: %{},
        signature: %{}
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end
end
