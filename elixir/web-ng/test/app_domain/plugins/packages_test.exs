defmodule ServiceRadarWebNG.Plugins.PackagesTest do
  use ServiceRadarWebNG.DataCase, async: false

  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0, system_actor: 0]

  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Plugins.Packages
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

  test "upload_blob updates blob metadata when called with an actor" do
    _plugin = create_plugin()
    package = create_package()
    payload = "updated-wasm-binary"

    assert {:ok, updated} =
             Packages.upload_blob(package, payload, actor: system_actor())

    assert updated.wasm_object_key == Storage.object_key_for(package)
    assert updated.content_hash == Storage.sha256(payload)
    assert Storage.blob_exists?(updated.wasm_object_key)
    assert {:ok, {:file, path}} = Storage.fetch_blob(updated.wasm_object_key)
    assert File.read!(path) == payload
  end

  test "create ignores caller-supplied wasm object keys" do
    _plugin = create_plugin()
    scope = Scope.for_user(admin_user_fixture())

    assert {:ok, package} =
             Packages.create(
               %{
                 plugin_id: "unifi-protect-camera",
                 name: "UniFi Protect Camera",
                 version: "0.1.0",
                 entrypoint: "run_check",
                 outputs: "serviceradar.plugin_result.v1",
                 manifest: @manifest,
                 config_schema: %{},
                 signature: %{},
                 wasm_object_key: "../../shared/other-package.wasm"
               },
               scope: scope
             )

    assert package.wasm_object_key in [nil, ""]
  end

  test "upload_blob_file writes to the canonical object key even if the package was poisoned" do
    _plugin = create_plugin()
    package = create_package()
    payload = "updated-wasm-binary"

    upload_path =
      Path.join(System.tmp_dir!(), "sr-plugin-upload-#{System.unique_integer([:positive])}.wasm")

    File.write!(upload_path, payload)

    on_exit(fn -> File.rm(upload_path) end)

    poisoned =
      package
      |> Ash.Changeset.for_update(
        :update,
        %{wasm_object_key: "plugins/other-package/1.0.0/shared.wasm"},
        actor: system_actor()
      )
      |> Ash.update!()

    assert {:ok, updated} =
             Packages.upload_blob_file(poisoned, upload_path, actor: system_actor())

    assert updated.wasm_object_key == Storage.object_key_for(package)
    assert updated.content_hash == Storage.sha256(payload)
    assert Storage.blob_exists?(updated.wasm_object_key)
    refute Storage.blob_exists?("plugins/other-package/1.0.0/shared.wasm")
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
