defmodule ServiceRadarWebNG.Plugins.StorageTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gnat.Jetstream.API.Object
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadarWebNG.Plugins.Storage

  @gib 1_073_741_824

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

  describe "reconcile_bucket/1" do
    # Database-free: runs in the Bazel `:db_free` unit tier.
    @describetag :db_free

    setup do
      bucket = "plugins_test_#{System.unique_integer([:positive])}"
      {:ok, bucket: bucket, stream: "OBJ_#{bucket}"}
    end

    test "creates an absent bucket with the 2 GiB default cap and configured replicas",
         %{bucket: bucket, stream: stream} do
      put_storage_config(jetstream_bucket: bucket, jetstream_replicas: 3)

      assert {:ok, :create} = Storage.reconcile_bucket(fake_jetstream(:absent))

      create_subject = "$JS.API.STREAM.CREATE.#{stream}"
      assert_received {:js, ^create_subject, payload}
      created = Jason.decode!(payload)
      assert created["max_bytes"] == 2 * @gib
      assert created["discard"] == "new"
      assert created["num_replicas"] == 3
    end

    test "caps an existing unlimited bucket whose data fits", %{bucket: bucket, stream: stream} do
      put_storage_config(jetstream_bucket: bucket)

      assert {:ok, {:update, max_bytes}} = Storage.reconcile_bucket(fake_jetstream({-1, @gib}))
      assert max_bytes == 2 * @gib

      update_subject = "$JS.API.STREAM.UPDATE.#{stream}"
      assert_received {:js, ^update_subject, payload}
      assert Jason.decode!(payload)["max_bytes"] == 2 * @gib
    end

    test "leaves a bucket holding more than the configured cap unchanged and logs it",
         %{bucket: bucket} do
      put_storage_config(jetstream_bucket: bucket, jetstream_max_bucket_size: @gib)

      log =
        capture_log(fn ->
          assert {:ok, {:hold, :stored_exceeds_cap}} =
                   Storage.reconcile_bucket(fake_jetstream({4 * @gib, 3 * @gib}))
        end)

      assert log =~ "configured=#{@gib} stored=#{3 * @gib} current=#{4 * @gib}"
      refute_received {:js, "$JS.API.STREAM.UPDATE." <> _, _}
    end
  end

  defp put_storage_config(opts) do
    Application.put_env(
      :serviceradar_web_ng,
      :plugin_storage,
      Keyword.merge([backend: :jetstream, signing_secret: "test-secret"], opts)
    )
  end

  defp fake_jetstream(bucket_state) do
    test = self()

    fn subject, payload ->
      send(test, {:js, subject, payload})

      case {String.starts_with?(subject, "$JS.API.STREAM.INFO."), bucket_state} do
        {true, :absent} ->
          {:error, %{"code" => 404, "err_code" => 10_059, "description" => "stream not found"}}

        {true, {max_bytes, stored}} ->
          stream = String.replace_prefix(subject, "$JS.API.STREAM.INFO.", "")
          config = %{"name" => stream, "discard" => "new", "max_bytes" => max_bytes}
          {:ok, %{"config" => config, "state" => %{"bytes" => stored}}}

        {false, _state} ->
          {:ok, %{"did_create" => true}}
      end
    end
  end
end
