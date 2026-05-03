defmodule ServiceRadarWebNGWeb.Admin.DashboardPackageLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0]

  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.Plugins.Storage

  @renderer "export default function mountDashboard() {}"
  @dashboard_id "com.test.live-upload-dashboard"

  setup %{conn: conn} do
    original_storage = Application.get_env(:serviceradar_web_ng, :plugin_storage)
    tmp = Path.join(System.tmp_dir!(), "sr-dashboard-live-test-#{System.unique_integer([:positive])}")
    user = admin_user_fixture()

    Application.put_env(:serviceradar_web_ng, :plugin_storage,
      backend: :filesystem,
      base_path: tmp,
      signing_secret: "test-secret"
    )

    on_exit(fn ->
      File.rm_rf(tmp)
      restore_env(:plugin_storage, original_storage)
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

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
