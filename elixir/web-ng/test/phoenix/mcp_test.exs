defmodule ServiceRadarWebNGWeb.McpTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.OAuthClient.Credentials
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Security.Events
  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadar.Security.SecurityEvent
  alias ServiceRadarWebNG.Mcp
  alias ServiceRadarWebNGWeb.FeatureFlags

  @ip "127.0.0.1"

  setup do
    RateLimiter.clear(:oauth_client_credentials, @ip)
    previous_flag = Application.get_env(:serviceradar_web_ng, :mcp_enabled, false)
    Application.put_env(:serviceradar_web_ng, :mcp_enabled, true)

    on_exit(fn ->
      Application.put_env(:serviceradar_web_ng, :mcp_enabled, previous_flag)
      RateLimiter.clear(:oauth_client_credentials, @ip)
    end)

    owner = admin_user_fixture()

    {:ok, client, secret} =
      Credentials.create_client(owner.id,
        name: "MCP Test #{System.unique_integer([:positive])}",
        scopes: ["read", "mcp"],
        actor: owner
      )

    %{owner: owner, client: client, secret: secret}
  end

  test "unauthenticated /mcp is 401" do
    conn = post(mcp_conn(), "/mcp", initialize_body())
    assert conn.status == 401
    header = List.keyfind(conn.resp_headers, "www-authenticate", 0)
    assert header
    assert elem(header, 1) =~ "resource_metadata="
    assert elem(header, 1) =~ "/.well-known/oauth-protected-resource"
  end

  test "disabled flag returns 404", %{client: client, secret: secret} do
    Application.put_env(:serviceradar_web_ng, :mcp_enabled, false)
    refute FeatureFlags.mcp_enabled?()

    conn = post(authed(client, secret), "/mcp", initialize_body())
    assert conn.status == 404
  end

  test "legacy static API key is rejected" do
    previous = Application.get_env(:serviceradar_web_ng, :api_auth, [])
    Application.put_env(:serviceradar_web_ng, :api_auth, api_keys: ["legacy-mcp-key"])

    on_exit(fn ->
      Application.put_env(:serviceradar_web_ng, :api_auth, previous)
    end)

    conn =
      mcp_conn()
      |> put_req_header("x-api-key", "legacy-mcp-key")
      |> post("/mcp", initialize_body())

    assert conn.status == 401
  end

  test "bearer without mcp scope is 403", %{owner: owner} do
    {:ok, client, secret} =
      Credentials.create_client(owner.id,
        name: "MCP No Scope #{System.unique_integer([:positive])}",
        scopes: ["read"],
        actor: owner
      )

    conn = post(authed(client, secret), "/mcp", initialize_body())
    assert conn.status == 403
    assert json_response(conn, 403)["error"] == "insufficient_scope"
  end

  test "a live token is 403 after settings.mcp.manage is revoked", %{owner: owner} do
    {:ok, client, secret} =
      Credentials.create_client(owner.id,
        name: "MCP Revoked #{System.unique_integer([:positive])}",
        scopes: ["read", "mcp"],
        actor: owner
      )

    token = mint_token(client, secret)

    _restricted = restrict_user(owner, ["devices.view"])

    conn =
      mcp_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/mcp", initialize_body())

    assert conn.status == 403
    assert json_response(conn, 403)["error"] == "forbidden"
  end

  test "mcp+read token can initialize and list the v1 tools", %{client: client, secret: secret} do
    conn = post(authed(client, secret), "/mcp", initialize_body())
    body = json_response(conn, 200)
    assert body["result"]["serverInfo"]["name"] == "serviceradar"
    assert body["result"]["instructions"] =~ "serviceradar://srql/grammar"
    assert body["result"]["capabilities"]["resources"]

    conn = post(authed(client, secret), "/mcp", rpc("tools/list"))
    names = json_response(conn, 200)["result"]["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()
    assert names == Mcp.v1_tools() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
  end

  test "resources/list and resources/read serve SRQL teaching documents", %{
    client: client,
    secret: secret
  } do
    conn = post(authed(client, secret), "/mcp", initialize_body())
    assert json_response(conn, 200)["result"]["serverInfo"]

    conn = post(authed(client, secret), "/mcp", rpc("resources/list"))
    resources = json_response(conn, 200)["result"]["resources"]
    uris = resources |> Enum.map(& &1["uri"]) |> Enum.sort()

    assert uris == [
             "serviceradar://srql/cookbook",
             "serviceradar://srql/entities",
             "serviceradar://srql/grammar"
           ]

    conn =
      post(
        authed(client, secret),
        "/mcp",
        rpc("resources/read", %{"uri" => "serviceradar://srql/grammar"})
      )

    contents = json_response(conn, 200)["result"]["contents"]
    text = contents |> List.wrap() |> Enum.map_join(& &1["text"])
    assert text =~ "in:<entity>"
    assert text =~ "not SQL"
  end

  test "exposed tools equal the v1 allowlist" do
    names =
      Mcp
      |> AshAi.Info.tools()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert names == Enum.sort(Mcp.v1_tools())
  end

  test "execute_srql is forbidden without devices.view", %{owner: owner} do
    user =
      restrict_user(viewer_user_fixture(), ["observability.logs.view", "settings.mcp.manage"])

    {:ok, client, secret} =
      Credentials.create_client(user.id,
        name: "MCP Restricted #{System.unique_integer([:positive])}",
        scopes: ["read", "mcp"],
        actor: owner
      )

    conn =
      post(
        authed(client, secret),
        "/mcp",
        tool_call("execute_srql", %{"query" => "in:devices"})
      )

    body = json_response(conn, 200)
    assert body["result"]["isError"]
    assert Enum.any?(body["result"]["content"], &String.contains?(&1["text"] || "", "forbidden"))
  end

  test "execute_srql goes through Access/query_request", %{client: client, secret: secret} do
    previous = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.QueryProbe)
    on_exit(fn -> restore_srql(previous) end)

    conn =
      post(
        authed(client, secret),
        "/mcp",
        tool_call("execute_srql", %{"query" => "in:devices"})
      )

    body = json_response(conn, 200)
    refute body["result"]["isError"]
    assert body["result"]["content"]
  end

  test "get_device rejects injection payloads as invalid uid", %{client: client, secret: secret} do
    conn =
      post(
        authed(client, secret),
        "/mcp",
        tool_call("get_device", %{"uid" => "device' OR '1'='1"})
      )

    body = json_response(conn, 200)
    assert body["result"]["isError"]
    assert Enum.any?(body["result"]["content"], &String.contains?(&1["text"], "invalid uid"))
  end

  test "viewer with mcp can list devices HTTP allows", %{secret: _secret} do
    viewer = viewer_user_fixture()

    {:ok, client, secret} =
      Credentials.create_client(viewer.id,
        name: "MCP Viewer #{System.unique_integer([:positive])}",
        scopes: ["read", "mcp"],
        actor: viewer
      )

    device =
      device_fixture(%{
        uid: "mcp-viewer-#{System.unique_integer([:positive])}",
        hostname: "mcp-host.local"
      })

    conn =
      post(authed(client, secret), "/mcp", tool_call("get_device", %{"uid" => device.uid}))

    body = json_response(conn, 200)
    refute body["result"]["isError"]
    text = hd(body["result"]["content"])["text"]
    assert text =~ device.uid
  end

  test "successful tool call and denial persist SecurityEvents", %{
    client: client,
    secret: secret,
    owner: owner
  } do
    post(authed(client, secret), "/mcp", initialize_body())

    post(authed(client, secret), "/mcp", tool_call("get_srql_catalog", %{}))

    {:ok, no_scope_client, no_scope_secret} =
      Credentials.create_client(owner.id,
        name: "MCP Deny #{System.unique_integer([:positive])}",
        scopes: ["read"],
        actor: owner
      )

    post(authed(no_scope_client, no_scope_secret), "/mcp", initialize_body())
    Events.flush()

    kinds =
      SecurityEvent
      |> Ash.read!(actor: SystemActor.system(:mcp_test), authorize?: false)
      |> Enum.map(& &1.kind)

    assert :mcp_session_initialized in kinds
    assert :mcp_tool_called in kinds
    assert :mcp_auth_failed in kinds
  end

  test "exceeding the mcp bucket returns 429", %{client: client, secret: secret, owner: owner} do
    previous = Application.get_env(:serviceradar_core, RateLimiter)

    Application.put_env(
      :serviceradar_core,
      RateLimiter,
      Keyword.put(
        previous || [],
        :buckets,
        Map.put(Keyword.get(previous || [], :buckets, %{}), :mcp, limit: 1, window_seconds: 60)
      )
    )

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_core, RateLimiter)
      else
        Application.put_env(:serviceradar_core, RateLimiter, previous)
      end
    end)

    RateLimiter.clear(:mcp, {@ip, owner.id})

    token_conn = authed(client, secret)
    _first = post(token_conn, "/mcp", initialize_body())
    second = post(authed(client, secret), "/mcp", initialize_body())
    assert second.status == 429
  end

  defmodule QueryProbe do
    @moduledoc false
    import ExUnit.Assertions

    def query_request(params) do
      assert Map.has_key?(params, "scope")
      assert params["query"] == "in:devices"
      {:ok, %{"results" => [], "pagination" => %{}, "error" => nil}}
    end
  end

  defp restore_srql(nil), do: Application.delete_env(:serviceradar_web_ng, :srql_module)
  defp restore_srql(mod), do: Application.put_env(:serviceradar_web_ng, :srql_module, mod)

  defp restrict_user(user, permissions) do
    actor = SystemActor.system(:srql_rbac_test)

    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "mcp-rbac-#{System.unique_integer([:positive])}",
          description: "catalog-gate fixture",
          permissions: permissions
        },
        actor: actor,
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!()

    {:ok, assigned} = User.update_role_profile(user, %{role_profile_id: profile.id}, actor: actor)
    RBAC.invalidate_user_cache(assigned.id)
    RBAC.clear_process_cache()
    assigned
  end

  defp mint_token(client, secret) do
    conn =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post("/oauth/token", %{
        "grant_type" => "client_credentials",
        "client_id" => client.id,
        "client_secret" => secret
      })

    json_response(conn, 200)["access_token"]
  end

  defp mcp_conn do
    build_conn()
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

  defp authed(client, secret) do
    put_req_header(mcp_conn(), "authorization", "Bearer #{mint_token(client, secret)}")
  end

  defp initialize_body do
    rpc("initialize", %{
      "protocolVersion" => "2025-03-26",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "mcp-test", "version" => "0.0.1"}
    })
  end

  defp tool_call(name, args) do
    rpc("tools/call", %{"name" => name, "arguments" => %{"input" => args}})
  end

  defp rpc(method, params \\ %{}) do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
  end
end
