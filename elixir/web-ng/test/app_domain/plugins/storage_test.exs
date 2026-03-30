defmodule ServiceRadarWebNG.Plugins.StorageTest do
  use ExUnit.Case, async: true

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

  test "filesystem backend stores and fetches blobs" do
    package = %PluginPackage{id: "pkg-1", plugin_id: "http-check", version: "1.0.0"}
    key = Storage.object_key_for(package)
    payload = "wasm-binary"

    assert :ok = Storage.put_blob(key, payload)
    assert Storage.blob_exists?(key)
    assert {:ok, {:file, path}} = Storage.fetch_blob(key)
    assert File.read!(path) == payload
  end

  test "blob_path rejects traversal attempts" do
    assert {:error, :invalid_path} = Storage.blob_path("../escape")
  end
end
