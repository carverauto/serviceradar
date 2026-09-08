defmodule ServiceRadarWebNGWeb.Api.PluginPackagePublishScopeTest do
  @moduledoc """
  The two plugin write routes the CLI calls now sit behind
  `:require_plugin_publish_scope`. These are the regression tests for what that
  pipeline must and must not change:

    * an API key whose user holds `plugins.stage` still authorizes, because
      `RequireOauthScope` falls back to the RBAC permission when no OAuth scope
      assign is present;
    * a CLI token granted `plugin.publish` authorizes;
    * a CLI token granted only `dashboard.publish` is refused -- the gap this
      change closes.

  The plug-level behaviour is covered without a database in
  `plugs/confine_narrow_scope_test.exs`; these exercise the wired router.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, api_token_fixture: 2, user_fixture: 0]

  alias ServiceRadarWebNG.Auth.Guardian

  @manifest %{
    "id" => "scope-probe",
    "name" => "Scope Probe",
    "version" => "0.1.0",
    "entrypoint" => "run_check",
    "outputs" => "serviceradar.plugin_result.v1",
    "capabilities" => ["get_config", "submit_result"],
    "resources" => %{"requested_cpu_ms" => 1000, "requested_memory_mb" => 64}
  }

  defp create_params do
    %{
      "plugin_id" => @manifest["id"],
      "name" => @manifest["name"],
      "version" => @manifest["version"],
      "entrypoint" => @manifest["entrypoint"],
      "outputs" => @manifest["outputs"],
      "manifest" => @manifest,
      "content_hash" => String.duplicate("a", 64),
      "source_type" => "upload"
    }
  end

  defp cli_token(user, scope) do
    {:ok, token, _claims} =
      Guardian.encode_and_sign(user, %{"typ" => "api", "scopes" => String.split(scope, " ")}, token_type: "api")

    token
  end

  describe "POST /api/admin/plugin-packages" do
    test "an API key with plugins.stage still authorizes", %{conn: conn} do
      admin = admin_user_fixture()
      token = api_token_fixture(admin, %{})

      conn =
        conn
        |> put_req_header("x-api-key", token.token)
        |> post(~p"/api/admin/plugin-packages", create_params())

      # The assertion is about authorization, not about the package body: any
      # status other than 401/403 means the pipeline let the caller reach the
      # controller, which is what this pipeline must not have broken.
      refute conn.status in [401, 403]
    end

    test "a CLI token scoped plugin.publish authorizes", %{conn: conn} do
      admin = admin_user_fixture()

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> cli_token(admin, "plugin.publish"))
        |> post(~p"/api/admin/plugin-packages", create_params())

      refute conn.status in [401, 403]
    end

    test "a CLI token scoped only dashboard.publish is refused", %{conn: conn} do
      admin = admin_user_fixture()

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> cli_token(admin, "dashboard.publish"))
        |> post(~p"/api/admin/plugin-packages", create_params())

      assert conn.status == 403
      assert %{"error" => "insufficient_scope"} = json_response(conn, 403)
    end

    test "a user without plugins.stage is refused" do
      viewer = user_fixture()

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> cli_token(viewer, "plugin.publish"))
        |> post(~p"/api/admin/plugin-packages", create_params())

      assert conn.status in [401, 403]
    end
  end

  describe "GET /api/admin/plugin-packages/:id" do
    test "stays reachable for a viewer, which the publish pipeline would have blocked", %{conn: conn} do
      viewer = user_fixture()

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> cli_token(viewer, "plugin.publish"))
        |> get(~p"/api/admin/plugin-packages/#{Ecto.UUID.generate()}")

      # A viewer holds plugins.view but not plugins.stage. Mounting the publish
      # pipeline on this read route would 403 them, which is why it was left on
      # the general pipeline.
      refute conn.status == 403
    end
  end
end
