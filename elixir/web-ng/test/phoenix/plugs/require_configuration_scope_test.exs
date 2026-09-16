defmodule ServiceRadarWebNGWeb.Plugs.RequireConfigurationScopeTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest, only: [build_conn: 3]
  import Plug.Conn

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Plugs.ConfineNarrowScope
  alias ServiceRadarWebNGWeb.Plugs.RequireConfigurationScope

  @moduletag :db_free

  test "an administrator's read-only API key cannot mutate configuration" do
    for method <- ["POST", "PATCH", "PUT", "DELETE"], scope <- [:read, "read"] do
      conn = run(method, %{api_token_scope: scope})
      assert conn.halted
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] == "insufficient_scope"
    end

    refute run("GET", %{api_token_scope: :read}).halted
    refute run("GET", %{api_token_scope: "read"}).halted
  end

  test "OAuth read scope grants reads without granting writes" do
    refute run("GET", %{oauth_token_scope: "read"}).halted
    assert run("POST", %{oauth_token_scope: "read"}).status == 403
  end

  test "write and admin capabilities pass to operation-specific RBAC" do
    for scope <- [:write, :admin, "write", "admin"] do
      refute run("POST", %{api_token_scope: scope}).halted
      refute run("DELETE", %{oauth_token_scope: to_string(scope)}).halted
    end
  end

  test "missing and malformed API capabilities do not become user access tokens" do
    for scope <- [nil, "", "mcp", "unknown.scope"] do
      assert run("POST", %{oauth_token_scope: scope}).status == 403
    end

    for scope <- [nil, "", "ADMIN", "unknown", :unknown, ["admin"]] do
      assert run("POST", %{api_token_scope: scope}).status == 403
    end
  end

  test "narrow grants retain their exact route boundary" do
    refute run("POST", %{oauth_token_scope: "plugins.manage"}).halted

    assert run("POST", %{oauth_token_scope: "plugins.manage"}, "/api/admin/ansible-repositories").status ==
             403

    assert run("DELETE", %{oauth_token_scope: "plugins.manage"}).status == 403
    assert run("POST", %{oauth_token_scope: "read plugin.publish"}).status == 403
  end

  test "inactive and unaccountable credentials are rejected before controller dispatch" do
    for user <- [nil, %{status: :inactive, role: :admin}] do
      conn = run("POST", %{api_token_scope: :admin, current_scope: %Scope{user: user}})
      assert conn.status == 401
      assert conn.halted
    end
  end

  test "authenticated user access tokens retain user RBAC and legacy static keys cannot provision" do
    refute run("POST", %{}).halted
    assert run("POST", %{api_key_auth: true}).status == 403
  end

  test "all credential and Ansible configuration routes mount the capability gate" do
    routes = Phoenix.Router.routes(ServiceRadarWebNGWeb.Router)

    configuration_routes =
      Enum.filter(routes, fn route ->
        String.starts_with?(route.path, "/api/admin/ansible-") or
          String.starts_with?(route.path, "/api/admin/network-credential-")
      end)

    assert length(configuration_routes) >= 20

    for route <- configuration_routes do
      info =
        Phoenix.Router.route_info(
          ServiceRadarWebNGWeb.Router,
          route.verb |> Atom.to_string() |> String.upcase(),
          route.path,
          "api.example.com"
        )

      assert :api_key_auth in info.pipe_through
      assert :configuration_api in info.pipe_through
    end
  end

  defp run(method, assigns, path \\ "/api/admin/ansible-controllers") do
    conn =
      method
      |> build_conn(path, nil)
      |> assign(:current_scope, %Scope{user: %{status: :active, role: :admin}})

    conn = Enum.reduce(assigns, conn, fn {key, value}, conn -> assign(conn, key, value) end)
    conn = ConfineNarrowScope.call(conn, [])
    if conn.halted, do: conn, else: RequireConfigurationScope.call(conn, [])
  end
end
