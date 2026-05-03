defmodule ServiceRadarWebNGWeb.DashboardPackageAssetControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0]

  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.Plugins.Storage

  @renderer "export function mountDashboard() {}"

  setup %{conn: conn} do
    original_storage = Application.get_env(:serviceradar_web_ng, :plugin_storage)
    tmp = Path.join(System.tmp_dir!(), "sr-dashboard-asset-test-#{System.unique_integer([:positive])}")
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

  test "serves enabled verified browser module renderer artifacts", %{conn: conn} do
    {:ok, package} = import_package("com.test.asset-controller.verified")
    {:ok, package} = Dashboards.enable_package(package.id, scope: nil)

    conn = get(conn, ~p"/dashboard-packages/#{package.id}/renderer")

    assert response(conn, 200) == @renderer
    assert ["text/javascript" <> _] = get_resp_header(conn, "content-type")
    assert get_resp_header(conn, "etag") == [~s("#{Storage.sha256(@renderer)}")]
    assert ["private, max-age=31536000, immutable"] = get_resp_header(conn, "cache-control")
  end

  test "does not serve disabled renderer artifacts", %{conn: conn} do
    {:ok, package} = import_package("com.test.asset-controller.disabled")

    conn = get(conn, ~p"/dashboard-packages/#{package.id}/renderer")

    assert response(conn, 404) == "dashboard renderer not found"
  end

  test "does not serve unverified renderer artifacts even when blob exists", %{conn: conn} do
    {:ok, package} =
      import_package("com.test.asset-controller.pending",
        verification_status: "pending",
        verification_error: "signature is pending review"
      )

    {:ok, _package} =
      package
      |> Ash.Changeset.for_update(:enable, %{})
      |> Ash.update()

    conn = get(conn, ~p"/dashboard-packages/#{package.id}/renderer")

    assert response(conn, 404) == "dashboard renderer not found"
  end

  defp import_package(dashboard_id, opts \\ []) do
    Dashboards.import_package_json(manifest_json(dashboard_id), @renderer, Keyword.put(opts, :scope, nil))
  end

  defp manifest_json(dashboard_id) do
    Jason.encode!(%{
      "id" => dashboard_id,
      "name" => "Asset Controller Dashboard",
      "version" => "1.0.0",
      "renderer" => %{
        "kind" => "browser_module",
        "interface_version" => "dashboard-browser-module-v1",
        "artifact" => "renderer.js",
        "sha256" => Storage.sha256(@renderer),
        "trust" => "trusted",
        "exports" => ["mountDashboard"]
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
