defmodule ServiceRadarWebNG.Plugins.PackagesTest do
  use ServiceRadarWebNG.DataCase, async: false

  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0, system_actor: 0]

  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Plugins.Packages
  alias ServiceRadarWebNG.Plugins.Storage
  alias ServiceRadarWebNG.Plugins.UploadSignature

  @repo_url "https://code.carverauto.dev/carverauto/serviceradar"
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
  @first_party_manifest_yaml """
  id: first-party-dedupe
  name: First-party Dedupe
  version: 1.0.1
  entrypoint: run_check
  runtime: wasi-preview1
  outputs: serviceradar.plugin_result.v1
  capabilities:
    - get_config
  resources:
    requested_cpu_ms: 1000
    requested_memory_mb: 64
  """
  @first_party_manifest %{
    "id" => "first-party-dedupe",
    "name" => "First-party Dedupe",
    "version" => "1.0.1",
    "entrypoint" => "run_check",
    "runtime" => "wasi-preview1",
    "outputs" => "serviceradar.plugin_result.v1",
    "capabilities" => ["get_config"],
    "resources" => %{"requested_cpu_ms" => 1000, "requested_memory_mb" => 64}
  }
  @first_party_wasm "first-party wasm payload"

  defmodule FirstPartyPackagesClient do
    @moduledoc false

    alias ServiceRadarWebNG.Plugins.PackagesTest

    def get(url, _opts) do
      cond do
        String.contains?(url, "/api/v1/repos/carverauto/serviceradar/releases?per_page=") ->
          {:ok, %Req.Response{status: 200, body: [PackagesTest.first_party_release()]}}

        String.contains?(url, "/api/v1/repos/carverauto/serviceradar/releases/tags/v1.0.1") ->
          {:ok, %Req.Response{status: 200, body: PackagesTest.first_party_release()}}

        String.ends_with?(url, "/serviceradar-wasm-plugin-index.json") ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(PackagesTest.first_party_index())}}

        String.ends_with?(url, "/first-party-dedupe.zip") ->
          {:ok, %Req.Response{status: 200, body: PackagesTest.first_party_bundle()}}

        String.ends_with?(url, "/first-party-dedupe.upload-signature.json") ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(PackagesTest.first_party_upload_signature())}}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
    end
  end

  setup do
    original = Application.get_env(:serviceradar_web_ng, :plugin_storage)
    original_policy = Application.get_env(:serviceradar_web_ng, :plugin_verification)
    original_import_client = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import_http_client)
    tmp = Path.join(System.tmp_dir!(), "sr-plugin-storage-#{System.unique_integer([:positive])}")
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    Application.put_env(:serviceradar_web_ng, :plugin_storage,
      backend: :filesystem,
      base_path: tmp,
      signing_secret: "test-secret"
    )

    Application.put_env(:serviceradar_web_ng, :plugin_verification,
      require_gpg_for_github: false,
      allow_unsigned_uploads: false,
      trusted_upload_signing_keys: %{"packages-test" => Base.encode64(public_key)}
    )

    Application.put_env(:serviceradar_web_ng, :first_party_plugin_import_http_client, FirstPartyPackagesClient)

    Process.put(:first_party_private_key, private_key)
    Process.put(:first_party_package_bundle, nil)
    Process.put(:first_party_package_signature, nil)

    on_exit(fn ->
      File.rm_rf(tmp)

      if is_nil(original) do
        Application.delete_env(:serviceradar_web_ng, :plugin_storage)
      else
        Application.put_env(:serviceradar_web_ng, :plugin_storage, original)
      end

      if is_nil(original_policy) do
        Application.delete_env(:serviceradar_web_ng, :plugin_verification)
      else
        Application.put_env(:serviceradar_web_ng, :plugin_verification, original_policy)
      end

      if is_nil(original_import_client) do
        Application.delete_env(:serviceradar_web_ng, :first_party_plugin_import_http_client)
      else
        Application.put_env(:serviceradar_web_ng, :first_party_plugin_import_http_client, original_import_client)
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

  test "sync_first_party_plugins deduplicates an already imported plugin/version/digest" do
    opts = [actor: system_actor(), repo_url: @repo_url, limit: 10]

    assert {:ok, %{imported: 1, failed: []}} = Packages.sync_first_party_plugins(opts)
    assert {:ok, %{imported: 1, failed: []}} = Packages.sync_first_party_plugins(opts)

    packages = Packages.list(%{"plugin_id" => "first-party-dedupe"}, actor: system_actor())
    assert [%PluginPackage{} = package] = packages
    assert package.source_type == :first_party
    assert package.source_release_tag == "v1.0.1"
    assert package.source_bundle_digest == Storage.sha256(first_party_bundle())
    assert Storage.blob_exists?(package.wasm_object_key)
  end

  def first_party_release do
    %{
      "tag_name" => "v1.0.1",
      "name" => "ServiceRadar v1.0.1",
      "html_url" => "https://code.carverauto.dev/carverauto/serviceradar/releases/tag/v1.0.1",
      "assets" => [
        %{
          "name" => "serviceradar-wasm-plugin-index.json",
          "browser_download_url" =>
            "https://code.carverauto.dev/carverauto/serviceradar/releases/download/v1.0.1/serviceradar-wasm-plugin-index.json"
        }
      ]
    }
  end

  def first_party_index do
    %{
      "schema_version" => 1,
      "plugins" => [
        %{
          "plugin_id" => "first-party-dedupe",
          "name" => "First-party Dedupe",
          "version" => "1.0.1",
          "bundle_url" =>
            "https://code.carverauto.dev/carverauto/serviceradar/releases/download/v1.0.1/first-party-dedupe.zip",
          "upload_signature_url" =>
            "https://code.carverauto.dev/carverauto/serviceradar/releases/download/v1.0.1/first-party-dedupe.upload-signature.json",
          "bundle_digest" => Storage.sha256(first_party_bundle()),
          "oci_ref" => "registry.carverauto.dev/serviceradar/wasm-plugin-first-party-dedupe:v1.0.1"
        }
      ]
    }
  end

  def first_party_bundle do
    case Process.get(:first_party_package_bundle) do
      nil ->
        path = Path.join(System.tmp_dir!(), "first-party-dedupe-#{System.unique_integer([:positive])}.zip")

        try do
          {:ok, _zip} =
            :zip.create(String.to_charlist(path), [
              {~c"plugin.yaml", @first_party_manifest_yaml},
              {~c"plugin.wasm", @first_party_wasm}
            ])

          payload = File.read!(path)
          Process.put(:first_party_package_bundle, payload)
          payload
        after
          File.rm(path)
        end

      payload ->
        payload
    end
  end

  def first_party_upload_signature do
    case Process.get(:first_party_package_signature) do
      nil ->
        signature =
          @first_party_manifest
          |> UploadSignature.verification_payload(Storage.sha256(@first_party_wasm))
          |> then(&:crypto.sign(:eddsa, :none, &1, [Process.get(:first_party_private_key), :ed25519]))
          |> Base.encode64()

        payload = %{
          "algorithm" => "ed25519",
          "key_id" => "packages-test",
          "signature" => signature
        }

        Process.put(:first_party_package_signature, payload)
        payload

      payload ->
        payload
    end
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
