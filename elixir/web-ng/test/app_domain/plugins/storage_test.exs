defmodule ServiceRadarWebNG.Plugins.StorageTest do
  use ExUnit.Case, async: false

  alias Gnat.Jetstream.API.Object
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadarWebNG.Plugins.Storage

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

    {:ok, base_path: tmp}
  end

  test "sign_token/verify_token round trip" do
    {token, _expires_at} =
      Storage.sign_token(:download, "pkg-1", "plugins/http/1.0.0/pkg-1.wasm", 60)

    assert {:ok, %{id: "pkg-1", key: "plugins/http/1.0.0/pkg-1.wasm"}} =
             Storage.verify_token(:download, token)
  end

  test "verify_token rejects tampered token" do
    {token, _expires_at} =
      Storage.sign_token(:download, "pkg-1", "plugins/http/1.0.0/pkg-1.wasm", 60)

    [payload, sig] = String.split(token, ".", parts: 2)
    tampered = payload <> "." <> sig <> "A"

    assert {:error, :invalid_token} = Storage.verify_token(:download, tampered)
  end

  test "upload_url/download_url return queryless endpoints" do
    assert Storage.upload_url("pkg-1") =~ "/api/plugin-packages/pkg-1/blob"
    refute Storage.upload_url("pkg-1") =~ "?token="

    assert Storage.download_url("pkg-1") =~ "/api/plugin-packages/pkg-1/blob/download"
    refute Storage.download_url("pkg-1") =~ "?token="
  end

  test "filesystem backend configuration is normalized to JetStream" do
    package = %PluginPackage{id: "pkg-1", plugin_id: "http-check", version: "1.0.0"}
    key = Storage.object_key_for(package)

    assert Storage.backend() == :jetstream
    assert {:error, :unsupported_backend} = Storage.blob_path(key)
  end

  @tag :jetstream_retirement
  test "loads the integrated Gnat JetStream object-store API" do
    assert Code.ensure_loaded?(Object)
    assert Code.ensure_loaded?(Gnat.Jetstream.API.Stream)
    assert function_exported?(Object, :put, 4)
    assert function_exported?(Object, :get, 4)
    assert function_exported?(Gnat.Jetstream.API.Stream, :info, 2)
  end

  test "JetStream client stores and fetches plugin blobs without filesystem paths" do
    store_name = :"sr_plugin_storage_test_#{System.unique_integer([:positive])}"
    {:ok, _store} = ServiceRadarWebNG.PluginStorageTestClient.start_link(store_name)

    Application.put_env(:serviceradar_web_ng, :plugin_storage,
      backend: :jetstream,
      jetstream_client: ServiceRadarWebNG.PluginStorageTestClient,
      test_store: store_name,
      signing_secret: "test-secret"
    )

    package = %PluginPackage{id: "pkg-1", plugin_id: "http-check", version: "1.0.0"}
    key = Storage.object_key_for(package)

    assert :ok = Storage.put_blob(key, "wasm payload")
    assert Storage.blob_exists?(key)
    assert {:ok, {:binary, "wasm payload"}} = Storage.fetch_blob(key)
    assert {:error, :unsupported_backend} = Storage.blob_path(key)
  end

  test "blob_path does not expose filesystem paths" do
    assert {:error, :unsupported_backend} = Storage.blob_path("../escape")
  end
end
