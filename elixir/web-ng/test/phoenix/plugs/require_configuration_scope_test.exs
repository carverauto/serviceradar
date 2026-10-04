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

  test "read-only POST exceptions allow only the exact decoded route and method" do
    opts = [read_only_post_paths: [["api", "query"], ["api", "admin", "topology", "route-analysis"]]]

    for path <- ["/api/query", "/api/%71uery", "/api/admin/topology/route-analysis"] do
      refute run("POST", %{oauth_token_scope: "read"}, path, opts).halted

      for method <- ["PATCH", "PUT", "DELETE"] do
        assert run(method, %{oauth_token_scope: "read"}, path, opts).status == 403
      end

      assert run("POST", %{oauth_token_scope: "read"}, path).status == 403
    end

    for path <- [
          "/api/query/extra",
          "/api/query%2Fextra",
          "/api/admin/topology/route-analysis/extra",
          "/api/admin/topology/rebuild",
          "/api/v2/event-rules"
        ] do
      assert run("POST", %{oauth_token_scope: "read"}, path, opts).status == 403
    end
  end

  test "write and admin capabilities pass to operation-specific RBAC" do
    for scope <- [:write, :admin, "write", "admin"] do
      refute run("POST", %{api_token_scope: scope}).halted
      refute run("DELETE", %{oauth_token_scope: to_string(scope)}).halted
    end
  end

  test "API path confinement prevents every coarse grant from authorizing browser flows" do
    opts = [path_prefixes: [["api"], ["topology"], ["v1", "stream"]]]

    for scope <- ["read", "write", "admin", "mcp"] do
      assert run("GET", %{oauth_token_scope: scope}, "/oauth/authorize", opts).status == 403
    end

    refute run("GET", %{oauth_token_scope: "read"}, "/api/v2/event-rules", opts).halted
    refute run("GET", %{oauth_token_scope: "read"}, "/%61pi/v2/event-rules", opts).halted
    assert run("GET", %{oauth_token_scope: "read"}, "/api%2Fv2/event-rules", opts).status == 403

    for path <- ["/topology/snapshot/latest", "/topology/tiles/search", "/v1/stream/synthetic-session"] do
      refute run("GET", %{oauth_token_scope: "read"}, path, opts).halted
    end

    assert run("POST", %{oauth_token_scope: "read"}, "/topology/tiles/relayout", opts).status == 403
    refute run("POST", %{oauth_token_scope: "write"}, "/topology/tiles/relayout", opts).halted

    for path <- ["/topology-admin", "/v1/streaming", "/v1/stream%2Fsynthetic-session"] do
      assert run("GET", %{oauth_token_scope: "admin"}, path, opts).status == 403
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

  test "api_key_auth boundary gates coarse reads while keeping legacy reach" do
    opts = [
      read_only_post_paths: [["api", "v1", "identity", "resolve"]],
      allow_api_key_auth: true
    ]

    assert run("POST", %{oauth_token_scope: "read"}, "/api/v1/scans", opts).status == 403
    assert run("POST", %{oauth_token_scope: "read"}, "/api/admin/edge-packages", opts).status == 403
    assert run("POST", %{oauth_token_scope: "read"}, "/api/admin/collectors", opts).status == 403
    assert run("POST", %{api_token_scope: "read"}, "/api/v1/scans", opts).status == 403
    refute run("GET", %{oauth_token_scope: "read"}, "/api/v1/scans/synthetic-id", opts).halted
    refute run("GET", %{oauth_token_scope: "read"}, "/api/admin/edge-packages", opts).halted
    refute run("GET", %{oauth_token_scope: "read"}, "/v1/field-survey/auth-check", opts).halted
    refute run("POST", %{oauth_token_scope: "read"}, "/api/v1/identity/resolve", opts).halted
    assert run("POST", %{oauth_token_scope: "read"}, "/api/v1/identity/resolve/extra", opts).status == 403
    refute run("POST", %{oauth_token_scope: "write"}, "/api/v1/scans", opts).halted
    refute run("POST", %{oauth_token_scope: "admin"}, "/api/admin/collectors", opts).halted
    refute run("POST", %{oauth_token_scope: "plugins.manage"}, "/api/admin/plugin-assignments", opts).halted
    assert run("POST", %{oauth_token_scope: "plugins.manage"}, "/api/v1/scans", opts).status == 403
    assert run("POST", %{oauth_token_scope: ""}, "/api/v1/scans", opts).status == 403
    assert run("POST", %{oauth_token_scope: "unknown.scope"}, "/api/v1/scans", opts).status == 403
    refute run("POST", %{}, "/api/v1/scans", opts).halted
    refute run("POST", %{api_key_auth: true}, "/api/v1/scans", opts).halted
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

  defp run(method, assigns, path \\ "/api/admin/ansible-controllers", opts \\ []) do
    conn =
      method
      |> build_conn(path, nil)
      |> assign(:current_scope, %Scope{user: %{status: :active, role: :admin}})

    conn = Enum.reduce(assigns, conn, fn {key, value}, conn -> assign(conn, key, value) end)
    conn = ConfineNarrowScope.call(conn, [])
    if conn.halted, do: conn, else: RequireConfigurationScope.call(conn, opts)
  end
end
