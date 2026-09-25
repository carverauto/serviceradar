defmodule ServiceRadarWebNGWeb.DashboardPackageReadControllerTest do
  @moduledoc """
  DB-backed integration tests for the dashboard-package read API.

  Covers proposal `add-dashboard-package-version-visibility`:
  index + show endpoints, permission gating, manifest-id addressing, and
  the explicit exclusion of signing material from the response.

  Run via the srql-fixtures CNPG instance per
  `.agents/skills/srql-fixtures-db-tests/SKILL.md`:

      SERVICERADAR_TEST_DATABASE_URL="postgres://..." \\
      SERVICERADAR_TEST_DATABASE_POOL_SIZE=1 \\
      SERVICERADAR_TEST_SANDBOX_MODE=shared \\
      MIX_ENV=test mix test test/phoenix/controllers/dashboard_package_read_controller_test.exs
  """
  use ServiceRadarWebNGWeb.ConnCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.Dashboards.Packages
  alias ServiceRadarWebNG.Plugins.Storage
  alias ServiceRadarWebNG.PluginStorageTestClient

  @moduletag :web_ng_shared_fixture_db

  @renderer "export default {mount(){},destroy(){}}"

  setup do
    ensure_admin_has_view_all!()

    original_storage = Application.get_env(:serviceradar_web_ng, :plugin_storage)
    # Package blobs always go to the JetStream object store, and this lane has
    # no NATS, so publish writes to the in-memory test client instead.
    store_name = :"sr_dashboard_read_test_#{System.unique_integer([:positive])}"
    {:ok, _store} = PluginStorageTestClient.start_link(store_name)

    Application.put_env(:serviceradar_web_ng, :plugin_storage,
      backend: :jetstream,
      jetstream_client: PluginStorageTestClient,
      test_store: store_name,
      signing_secret: "test-secret"
    )

    on_exit(fn ->
      if original_storage do
        Application.put_env(:serviceradar_web_ng, :plugin_storage, original_storage)
      else
        Application.delete_env(:serviceradar_web_ng, :plugin_storage)
      end
    end)

    :ok
  end

  describe "GET /api/v1/dashboard-packages — index" do
    test "returns installed packages with manifest id, version and instance state",
         %{conn: conn} do
      dashboard_id = "com.test.read.index.#{System.unique_integer([:positive])}"
      route = "test-read-idx-#{System.unique_integer([:positive])}"
      {:ok, package} = publish_package!(dashboard_id, route)

      conn = conn |> auth_read(:admin) |> get(~p"/api/v1/dashboard-packages")
      body = json_response(conn, 200)

      assert is_list(body["packages"])

      pkg = Enum.find(body["packages"], &(&1["dashboard_id"] == dashboard_id))
      assert pkg, "expected #{dashboard_id} in index response"
      assert pkg["id"] == to_string(package.id)
      assert pkg["version"] == "0.1.0"
      assert pkg["content_hash"]
      assert is_list(pkg["instances"])
      instance = List.first(pkg["instances"])
      assert instance
      assert instance["route_slug"] == route
    end

    test "caller without dashboards.packages.view_all is refused with 403", %{conn: conn} do
      conn = conn |> auth_read(:viewer) |> get(~p"/api/v1/dashboard-packages")
      body = json_response(conn, 403)
      assert body["error"] == "forbidden"
      assert body["permission"] == "dashboards.packages.view_all"
    end

    test "no Authorization header is refused with 401", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/dashboard-packages")
      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "response omits signature, settings_schema and wasm_object_key", %{conn: conn} do
      dashboard_id = "com.test.read.security.#{System.unique_integer([:positive])}"
      {:ok, _} = publish_package!(dashboard_id, nil)

      conn = conn |> auth_read(:admin) |> get(~p"/api/v1/dashboard-packages")
      body = json_response(conn, 200)

      pkg = Enum.find(body["packages"], &(&1["dashboard_id"] == dashboard_id))
      assert pkg
      refute Map.has_key?(pkg, "signature"), "signature must not appear in read API response"
      refute Map.has_key?(pkg, "settings_schema"), "settings_schema must not appear"
      refute Map.has_key?(pkg, "wasm_object_key"), "wasm_object_key must not appear"
    end
  end

  describe "GET /api/v1/dashboard-packages/:id — show" do
    test "resolves by manifest id (dashboard_id)", %{conn: conn} do
      dashboard_id = "com.test.read.show.mid.#{System.unique_integer([:positive])}"
      {:ok, package} = publish_package!(dashboard_id, nil)

      conn = conn |> auth_read(:admin) |> get(~p"/api/v1/dashboard-packages/#{dashboard_id}")
      body = json_response(conn, 200)

      assert body["package"]["id"] == to_string(package.id)
      assert body["package"]["dashboard_id"] == dashboard_id
      assert body["package"]["version"] == "0.1.0"
    end

    test "resolves by internal UUID", %{conn: conn} do
      dashboard_id = "com.test.read.show.uuid.#{System.unique_integer([:positive])}"
      {:ok, package} = publish_package!(dashboard_id, nil)

      conn =
        conn
        |> auth_read(:admin)
        |> get(~p"/api/v1/dashboard-packages/#{package.id}")

      body = json_response(conn, 200)
      assert body["package"]["dashboard_id"] == dashboard_id
    end

    test "an uninstalled id returns the structured not-installed body, not a bare 404",
         %{conn: conn} do
      conn =
        conn
        |> auth_read(:admin)
        |> get(~p"/api/v1/dashboard-packages/com.test.read.notinstalled")

      body = json_response(conn, 404)
      assert body["error"] == "not_installed"
      assert is_binary(body["id"])
    end

    test "caller without view_all is refused with 403", %{conn: conn} do
      conn =
        conn
        |> auth_read(:viewer)
        |> get(~p"/api/v1/dashboard-packages/com.test.read.forbidden")

      body = json_response(conn, 403)
      assert body["error"] == "forbidden"
    end

    test "show response also omits signature, settings_schema and wasm_object_key",
         %{conn: conn} do
      dashboard_id = "com.test.read.show.sec.#{System.unique_integer([:positive])}"
      {:ok, _} = publish_package!(dashboard_id, nil)

      conn =
        conn
        |> auth_read(:admin)
        |> get(~p"/api/v1/dashboard-packages/#{dashboard_id}")

      body = json_response(conn, 200)
      pkg = body["package"]
      refute Map.has_key?(pkg, "signature")
      refute Map.has_key?(pkg, "settings_schema")
      refute Map.has_key?(pkg, "wasm_object_key")
    end
  end

  ## Helpers

  defp auth_read(conn, :admin) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    {:ok, token, _claims} = Guardian.create_api_token(user, scopes: [:read])
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp auth_read(conn, :viewer) do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    {:ok, token, _claims} = Guardian.create_api_token(user, scopes: [:read])
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp publish_package!(dashboard_id, route_slug) do
    manifest = Jason.encode!(manifest_for(dashboard_id, @renderer))
    opts = [actor: SystemActor.system(:test)]
    opts = if route_slug, do: Keyword.put(opts, :route_slug, route_slug), else: opts

    case Packages.publish(manifest, @renderer, opts) do
      {:ok, %{package: package}} -> {:ok, package}
      {:error, reason} -> raise "publish_package! failed: #{inspect(reason)}"
    end
  end

  defp manifest_for(dashboard_id, renderer_bytes) do
    %{
      "schema_version" => 1,
      "id" => dashboard_id,
      "name" => "Test Read Dashboard",
      "version" => "0.1.0",
      "renderer" => %{
        "kind" => "browser_module",
        "interface_version" => "dashboard-browser-module-v1",
        "artifact" => "renderer.js",
        "sha256" => Storage.sha256(renderer_bytes),
        "trust" => "trusted"
      },
      "data_frames" => [
        %{"id" => "f1", "query" => "in:wifi_sites limit:1", "encoding" => "json_rows"}
      ],
      "capabilities" => ["srql.execute"]
    }
  end

  defp ensure_admin_has_view_all! do
    actor = SystemActor.system(:test)

    case RoleProfile.get_by_system_name("admin", actor: actor) do
      {:ok, %RoleProfile{} = profile} ->
        required = MapSet.new(["dashboards.packages.view_all"])
        existing = MapSet.new(profile.permissions)

        if not MapSet.subset?(required, existing) do
          new_perms =
            existing
            |> MapSet.union(required)
            |> MapSet.to_list()

          {:ok, _} =
            RoleProfile.update_system_profile(
              profile,
              %{permissions: new_perms},
              actor: actor
            )

          if function_exported?(RBAC, :clear_process_cache, 0), do: RBAC.clear_process_cache()
        end

      _ ->
        :ok
    end
  end
end
