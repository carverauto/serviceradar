defmodule ServiceRadarWebNGWeb.Admin.PluginPackageLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.AshTestHelpers, only: [actor_for_user: 1, admin_user_fixture: 0]

  alias ServiceRadarWebNG.Plugins.Packages
  alias ServiceRadarWebNG.Plugins.Storage
  alias ServiceRadarWebNG.Plugins.UploadSignature

  @repo_url "https://code.carverauto.dev/carverauto/serviceradar"
  @manifest_yaml """
  id: live-first-party-plugin
  name: Live First-party Plugin
  version: 2.0.0
  entrypoint: run_check
  runtime: wasi-preview1
  outputs: serviceradar.plugin_result.v1
  capabilities:
    - get_config
  resources:
    requested_cpu_ms: 1000
    requested_memory_mb: 64
  """
  @manifest %{
    "id" => "live-first-party-plugin",
    "name" => "Live First-party Plugin",
    "version" => "2.0.0",
    "entrypoint" => "run_check",
    "runtime" => "wasi-preview1",
    "outputs" => "serviceradar.plugin_result.v1",
    "capabilities" => ["get_config"],
    "resources" => %{"requested_cpu_ms" => 1000, "requested_memory_mb" => 64}
  }
  @wasm "live first-party wasm payload"

  defmodule ForgejoClient do
    @moduledoc false

    alias ServiceRadarWebNGWeb.Admin.PluginPackageLiveTest

    def get(url, _opts) do
      cond do
        String.contains?(url, "/api/v1/repos/carverauto/serviceradar/releases?per_page=") ->
          {:ok, %Req.Response{status: 200, body: [PluginPackageLiveTest.release()]}}

        String.contains?(url, "/api/v1/repos/carverauto/serviceradar/releases/tags/v2.0.0") ->
          {:ok, %Req.Response{status: 200, body: PluginPackageLiveTest.release()}}

        String.ends_with?(url, "/serviceradar-wasm-plugin-index.json") ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(PluginPackageLiveTest.index())}}

        String.ends_with?(url, "/live-first-party-plugin.zip") ->
          {:ok, %Req.Response{status: 200, body: PluginPackageLiveTest.bundle()}}

        String.ends_with?(url, "/live-first-party-plugin.upload-signature.json") ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(PluginPackageLiveTest.upload_signature())}}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
    end
  end

  setup %{conn: conn} do
    original_policy = Application.get_env(:serviceradar_web_ng, :plugin_verification)
    original_client = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import_http_client)
    original_import_config = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import)
    original_storage = Application.get_env(:serviceradar_web_ng, :plugin_storage)
    original_bundle = Application.get_env(:serviceradar_web_ng, :plugin_live_test_bundle)
    original_signature = Application.get_env(:serviceradar_web_ng, :plugin_live_test_signature)
    tmp = Path.join(System.tmp_dir!(), "sr-plugin-live-test-#{System.unique_integer([:positive])}")
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    Application.put_env(:serviceradar_web_ng, :plugin_verification,
      require_gpg_for_github: false,
      allow_unsigned_uploads: false,
      trusted_upload_signing_keys: %{"live-test" => Base.encode64(public_key)}
    )

    Application.put_env(:serviceradar_web_ng, :first_party_plugin_import_http_client, ForgejoClient)

    Application.put_env(:serviceradar_web_ng, :first_party_plugin_import,
      repo_url: @repo_url,
      index_asset_name: "serviceradar-wasm-plugin-index.json",
      auto_sync_enabled: false,
      sync_release_limit: 10
    )

    Application.put_env(:serviceradar_web_ng, :plugin_storage,
      backend: :filesystem,
      base_path: tmp,
      signing_secret: "test-secret"
    )

    Process.put(:live_first_party_private_key, private_key)
    Process.put(:live_first_party_bundle, nil)
    Process.put(:live_first_party_signature, nil)
    Application.put_env(:serviceradar_web_ng, :plugin_live_test_bundle, bundle())
    Application.put_env(:serviceradar_web_ng, :plugin_live_test_signature, upload_signature())

    user = admin_user_fixture()

    on_exit(fn ->
      File.rm_rf(tmp)
      restore_env(:plugin_verification, original_policy)
      restore_env(:first_party_plugin_import_http_client, original_client)
      restore_env(:first_party_plugin_import, original_import_config)
      restore_env(:plugin_storage, original_storage)
      restore_env(:plugin_live_test_bundle, original_bundle)
      restore_env(:plugin_live_test_signature, original_signature)
    end)

    %{conn: log_in_user(conn, user), actor: actor_for_user(user)}
  end

  test "syncs the first-party plugin catalog", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/admin/plugins")

    assert html =~ "First-party Repository Plugins"
    refute html =~ "Live First-party Plugin"

    html =
      lv
      |> element("button[phx-click='sync_first_party_catalog']")
      |> render_click()

    assert html =~ "Live First-party Plugin"
    assert html =~ "live-first-party-plugin"
    assert html =~ "import-ready"
  end

  test "imports a first-party plugin from the catalog", %{conn: conn, actor: actor} do
    {:ok, lv, _html} = live(conn, ~p"/admin/plugins")

    lv
    |> element("button[phx-click='sync_first_party_catalog']")
    |> render_click()

    lv
    |> element("button[phx-click='import_first_party_plugin'][phx-value-plugin-id='live-first-party-plugin']")
    |> render_click()

    assert [package] = Packages.list(%{"plugin_id" => "live-first-party-plugin"}, actor: actor)
    assert package.source_type == :first_party
    assert package.source_release_tag == "v2.0.0"
    assert package.source_bundle_digest == Storage.sha256(bundle())
    assert Storage.blob_exists?(package.wasm_object_key)
  end

  test "shows first-party package provenance", %{conn: conn, actor: actor} do
    assert {:ok, %{failed: []}} = Packages.sync_first_party_plugins(actor: actor, repo_url: @repo_url, limit: 10)
    assert [package] = Packages.list(%{"plugin_id" => "live-first-party-plugin"}, actor: actor)

    {:ok, _lv, html} = live(conn, ~p"/admin/plugins/#{package.id}")

    assert html =~ "First-party Provenance"
    assert html =~ "v2.0.0"
    assert html =~ "registry.carverauto.dev/serviceradar/wasm-plugin-live-first-party-plugin:v2.0.0"
  end

  def release do
    %{
      "tag_name" => "v2.0.0",
      "name" => "ServiceRadar v2.0.0",
      "html_url" => "https://code.carverauto.dev/carverauto/serviceradar/releases/tag/v2.0.0",
      "assets" => [
        %{
          "name" => "serviceradar-wasm-plugin-index.json",
          "browser_download_url" =>
            "https://code.carverauto.dev/carverauto/serviceradar/releases/download/v2.0.0/serviceradar-wasm-plugin-index.json"
        }
      ]
    }
  end

  def index do
    %{
      "schema_version" => 1,
      "plugins" => [
        %{
          "plugin_id" => "live-first-party-plugin",
          "name" => "Live First-party Plugin",
          "version" => "2.0.0",
          "bundle_url" =>
            "https://code.carverauto.dev/carverauto/serviceradar/releases/download/v2.0.0/live-first-party-plugin.zip",
          "upload_signature_url" =>
            "https://code.carverauto.dev/carverauto/serviceradar/releases/download/v2.0.0/live-first-party-plugin.upload-signature.json",
          "bundle_digest" => Storage.sha256(bundle()),
          "oci_ref" => "registry.carverauto.dev/serviceradar/wasm-plugin-live-first-party-plugin:v2.0.0"
        }
      ]
    }
  end

  def bundle do
    case Application.get_env(:serviceradar_web_ng, :plugin_live_test_bundle) ||
           Process.get(:live_first_party_bundle) do
      nil ->
        path = Path.join(System.tmp_dir!(), "live-first-party-plugin-#{System.unique_integer([:positive])}.zip")

        try do
          {:ok, _zip} =
            :zip.create(String.to_charlist(path), [
              {~c"plugin.yaml", @manifest_yaml},
              {~c"plugin.wasm", @wasm}
            ])

          payload = File.read!(path)
          Process.put(:live_first_party_bundle, payload)
          payload
        after
          File.rm(path)
        end

      payload ->
        payload
    end
  end

  def upload_signature do
    case Application.get_env(:serviceradar_web_ng, :plugin_live_test_signature) ||
           Process.get(:live_first_party_signature) do
      nil ->
        signature =
          @manifest
          |> UploadSignature.verification_payload(Storage.sha256(@wasm))
          |> then(&:crypto.sign(:eddsa, :none, &1, [Process.get(:live_first_party_private_key), :ed25519]))
          |> Base.encode64()

        payload = %{
          "algorithm" => "ed25519",
          "key_id" => "live-test",
          "signature" => signature
        }

        Process.put(:live_first_party_signature, payload)
        payload

      payload ->
        payload
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
