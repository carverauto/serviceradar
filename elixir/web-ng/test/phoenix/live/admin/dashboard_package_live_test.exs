defmodule ServiceRadarWebNGWeb.Admin.DashboardPackageLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0]

  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.Plugins.Storage

  @renderer "export default function mountDashboard() {}"
  @dashboard_id "com.test.live-upload-dashboard"
  @github_dashboard_id "com.test.live-github-dashboard"
  @github_repo_url "https://github.com/acme/dashboard-demo"

  defmodule DashboardGitHubClient do
    @moduledoc false

    alias ServiceRadarWebNGWeb.Admin.DashboardPackageLiveTest

    def get(url, _opts) do
      cond do
        String.contains?(url, "api.github.com/repos/acme/dashboard-demo/commits/") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "sha" => String.duplicate("c", 40),
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

        String.contains?(url, "raw.githubusercontent.com/acme/dashboard-demo/#{String.duplicate("c", 40)}/dashboard.json") ->
          {:ok, %Req.Response{status: 200, body: DashboardPackageLiveTest.github_manifest_json()}}

        String.contains?(url, "raw.githubusercontent.com/acme/dashboard-demo/#{String.duplicate("c", 40)}/renderer.js") ->
          {:ok, %Req.Response{status: 200, body: DashboardPackageLiveTest.renderer()}}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
    end
  end

  def renderer, do: @renderer

  setup %{conn: conn} do
    original_storage = Application.get_env(:serviceradar_web_ng, :plugin_storage)
    original_client = Application.get_env(:serviceradar_web_ng, :github_http_client)
    original_policy = Application.get_env(:serviceradar_web_ng, :plugin_verification)
    original_token = Application.get_env(:serviceradar_web_ng, :github_token)
    tmp = Path.join(System.tmp_dir!(), "sr-dashboard-live-test-#{System.unique_integer([:positive])}")
    user = admin_user_fixture()

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

    %{conn: log_in_user(conn, user)}
  end

  test "failed partial upload submit does not consume completed manifest", %{conn: conn} do
    manifest = manifest_json()
    {:ok, lv, _html} = live(conn, ~p"/settings/dashboards/packages")

    lv
    |> element("button[phx-click='open_import_modal']")
    |> render_click()

    form_selector = "form[phx-submit='import_package']"

    manifest_upload =
      file_input(lv, form_selector, :manifest, [
        %{name: "manifest.json", content: manifest, type: "application/json"}
      ])

    assert render_upload(manifest_upload, "manifest.json") =~ "Import Dashboard Package"

    assert lv
           |> form(form_selector, %{"import" => %{"enable" => "true", "create_instance" => "true"}})
           |> render_submit() =~ "Upload renderer artifact before importing"

    renderer_upload =
      file_input(lv, form_selector, :wasm, [
        %{name: "renderer.js", content: @renderer, type: "application/javascript"}
      ])

    assert render_upload(renderer_upload, "renderer.js") =~ "Import Dashboard Package"

    lv
    |> form(form_selector, %{"import" => %{"enable" => "true", "create_instance" => "true"}})
    |> render_submit()

    assert [package] = Dashboards.list_packages(%{"dashboard_id" => @dashboard_id}, scope: nil)
    assert package.content_hash == Storage.sha256(@renderer)
    assert package.status == :enabled
  end

  test "admin can import a dashboard package from GitHub without upload artifacts", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/dashboards/packages")

    lv
    |> element("button[phx-click='open_import_modal']")
    |> render_click()

    form_selector = "form[phx-submit='import_package']"

    html =
      lv
      |> form(form_selector, %{"import" => %{"source_type" => "github"}})
      |> render_change()

    assert html =~ "GitHub repo URL"

    lv
    |> form(form_selector, %{
      "import" => %{
        "source_type" => "github",
        "source_repo_url" => @github_repo_url,
        "source_ref" => "main",
        "source_manifest_path" => "dashboard.json",
        "enable" => "true",
        "create_instance" => "true"
      }
    })
    |> render_submit()

    assert [package] = Dashboards.list_packages(%{"dashboard_id" => @github_dashboard_id}, scope: nil)
    assert package.source_type == :git
    assert package.source_repo_url == @github_repo_url
    assert package.source_ref == "main"
    assert package.source_manifest_path == "dashboard.json"
    assert package.source_commit == String.duplicate("c", 40)
    assert package.content_hash == Storage.sha256(@renderer)
    assert package.status == :enabled
    assert Storage.blob_exists?(package.wasm_object_key)
  end

  test "admin can choose a default route and edit instance settings", %{conn: conn} do
    suffix = System.unique_integer([:positive])
    route_one = "live-route-one-#{suffix}"
    route_two = "live-route-two-#{suffix}"

    {:ok, package} =
      Dashboards.import_package_json(manifest_json(), @renderer,
        source_type: :upload,
        signature: %{"kind" => "test"}
      )

    {:ok, package} = Dashboards.enable_package(package.id)

    {:ok, first} =
      Dashboards.create_instance(package, %{
        name: "First Route",
        route_slug: route_one,
        placement: :map,
        enabled: true,
        settings: %{"title" => "First"}
      })

    {:ok, second} =
      Dashboards.create_instance(package, %{
        name: "Second Route",
        route_slug: route_two,
        placement: :map,
        enabled: true,
        settings: %{"title" => "Second"}
      })

    {:ok, _first} = Dashboards.set_default_instance(first.id)

    {:ok, lv, html} = live(conn, ~p"/settings/dashboards/packages/#{package.id}")
    assert html =~ "First Route"
    assert html =~ "Default"

    lv
    |> element("button[phx-click='set_default_instance'][phx-value-id='#{second.id}']")
    |> render_click()

    {:ok, first} = Dashboards.get_instance(first.id)
    {:ok, second} = Dashboards.get_instance(second.id)

    refute first.is_default
    assert second.is_default

    lv
    |> element("button[phx-click='edit_instance'][phx-value-id='#{second.id}']")
    |> render_click()

    assert render(lv) =~ "Edit Dashboard Route"

    lv
    |> form("form[phx-submit='update_instance']", %{
      "instance" => %{
        "id" => second.id,
        "name" => "Second Route Updated",
        "route_slug" => route_two,
        "placement" => "map",
        "enabled" => "true",
        "settings_json" => ~s({"title":"Updated","defaultZoom":4})
      }
    })
    |> render_submit()

    {:ok, second} = Dashboards.get_instance(second.id)
    assert second.name == "Second Route Updated"
    assert second.settings == %{"title" => "Updated", "defaultZoom" => 4}
  end

  defp manifest_json do
    Jason.encode!(%{
      "id" => @dashboard_id,
      "name" => "Live Upload Dashboard",
      "version" => "1.0.0",
      "renderer" => %{
        "kind" => "browser_module",
        "interface_version" => "dashboard-browser-module-v1",
        "artifact" => "renderer.js",
        "sha256" => Storage.sha256(@renderer),
        "trust" => "trusted",
        "exports" => ["default"]
      },
      "data_frames" => [
        %{
          "id" => "sites",
          "query" => "in:wifi_sites",
          "encoding" => "json_rows"
        }
      ],
      "capabilities" => ["srql.execute", "navigation.open"],
      "settings_schema" => %{}
    })
  end

  def github_manifest_json do
    Jason.encode!(%{
      "id" => @github_dashboard_id,
      "name" => "Live GitHub Dashboard",
      "version" => "1.0.0",
      "renderer" => %{
        "kind" => "browser_module",
        "interface_version" => "dashboard-browser-module-v1",
        "artifact" => "renderer.js",
        "sha256" => Storage.sha256(@renderer),
        "trust" => "trusted",
        "exports" => ["default"]
      },
      "data_frames" => [
        %{
          "id" => "sites",
          "query" => "in:wifi_sites",
          "encoding" => "json_rows"
        }
      ],
      "capabilities" => ["srql.execute", "navigation.open"],
      "settings_schema" => %{}
    })
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
