defmodule ServiceRadarWebNG.Dashboards.PackagesTest do
  use ServiceRadarWebNG.DataCase, async: false

  import ServiceRadarWebNG.AshTestHelpers, only: [system_actor: 0]

  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.Dashboards.PackagesTest
  alias ServiceRadarWebNG.Plugins.Storage

  @repo_url "https://github.com/acme/dashboard-demo"
  @renderer "export function mountDashboard(element, host) { element.dataset.dashboard = host.package.name; }"

  def renderer, do: @renderer

  def manifest_json do
    Jason.encode!(%{
      "id" => "com.test.imported-github-dashboard",
      "name" => "Imported GitHub Dashboard",
      "version" => "1.0.0",
      "renderer" => %{
        "kind" => "browser_module",
        "interface_version" => "dashboard-browser-module-v1",
        "artifact" => "dashboards/imported-dashboard.js",
        "sha256" => Storage.sha256(@renderer),
        "trust" => "trusted",
        "exports" => ["mountDashboard"]
      },
      "data_frames" => [
        %{
          "id" => "sites",
          "query" => "in:wifi_sites limit:1",
          "encoding" => "json_rows"
        }
      ],
      "capabilities" => ["srql.execute", "map.deck.render", "navigation.open"],
      "settings_schema" => %{},
      "source" => %{"homepage" => "https://github.com/acme/dashboard-demo"}
    })
  end

  defmodule DashboardGitHubClient do
    @moduledoc false

    def get(url, _opts) do
      cond do
        String.contains?(url, "api.github.com/repos/acme/dashboard-demo/commits/") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "sha" => String.duplicate("b", 40),
               "commit" => %{
                 "verification" => %{
                   "verified" => true,
                   "reason" => "valid",
                   "signer" => %{"login" => "octo"}
                 }
               }
             }
           }}

        String.contains?(url, "api.github.com/repos/acme/dashboard-demo") ->
          {:ok, %Req.Response{status: 200, body: %{"default_branch" => "main"}}}

        String.contains?(url, "raw.githubusercontent.com/acme/dashboard-demo/#{String.duplicate("b", 40)}/dashboard.json") ->
          {:ok, %Req.Response{status: 200, body: PackagesTest.manifest_json()}}

        String.contains?(
          url,
          "raw.githubusercontent.com/acme/dashboard-demo/#{String.duplicate("b", 40)}/dashboards/imported-dashboard.js"
        ) ->
          {:ok, %Req.Response{status: 200, body: PackagesTest.renderer()}}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
    end
  end

  setup do
    original_storage = Application.get_env(:serviceradar_web_ng, :plugin_storage)
    original_client = Application.get_env(:serviceradar_web_ng, :github_http_client)
    original_policy = Application.get_env(:serviceradar_web_ng, :plugin_verification)
    original_token = Application.get_env(:serviceradar_web_ng, :github_token)
    tmp = Path.join(System.tmp_dir!(), "sr-dashboard-storage-#{System.unique_integer([:positive])}")

    Application.put_env(:serviceradar_web_ng, :plugin_storage,
      backend: :filesystem,
      base_path: tmp,
      signing_secret: "test-secret"
    )

    Application.put_env(:serviceradar_web_ng, :github_http_client, DashboardGitHubClient)

    Application.put_env(:serviceradar_web_ng, :plugin_verification,
      require_gpg_for_github: false,
      allow_unsigned_uploads: true
    )

    on_exit(fn ->
      File.rm_rf(tmp)
      restore_env(:plugin_storage, original_storage)
      restore_env(:github_http_client, original_client)
      restore_env(:plugin_verification, original_policy)
      restore_env(:github_token, original_token)
    end)

    :ok
  end

  test "import_github persists dashboard package metadata and renderer artifact" do
    assert {:ok, %DashboardPackage{} = package} =
             Dashboards.import_package_github(
               %{
                 source_repo_url: @repo_url,
                 source_commit: "main"
               },
               actor: system_actor()
             )

    assert package.dashboard_id == "com.test.imported-github-dashboard"
    assert package.source_type == :git
    assert package.source_repo_url == @repo_url
    assert package.source_ref == "main"
    assert package.source_manifest_path == "dashboard.json"
    assert package.source_commit == String.duplicate("b", 40)
    assert package.source_metadata["source"] == "github"
    assert package.source_metadata["renderer_path"] == "dashboards/imported-dashboard.js"
    assert package.content_hash == Storage.sha256(@renderer)
    assert package.wasm_object_key == Storage.object_key_for(package)
    assert Storage.blob_exists?(package.wasm_object_key)
    assert {:ok, {:file, path}} = Storage.fetch_blob(package.wasm_object_key)
    assert File.read!(path) == @renderer
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
