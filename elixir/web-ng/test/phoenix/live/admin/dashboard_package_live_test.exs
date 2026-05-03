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
