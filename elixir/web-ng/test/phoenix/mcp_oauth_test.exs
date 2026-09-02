defmodule ServiceRadarWebNGWeb.McpOAuthTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.McpOAuthGrant
  alias ServiceRadar.Identity.OAuthClient.Credentials
  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNG.Mcp
  alias ServiceRadarWebNG.Mcp.OAuth
  alias ServiceRadarWebNG.Mcp.OAuth.Pkce
  alias ServiceRadarWebNG.Mcp.OAuth.Server
  alias ServiceRadarWebNGWeb.FeatureFlags

  @ip "127.0.0.1"
  @redirect "http://127.0.0.1:43721/callback"
  @client_id "serviceradar-mcp"

  setup do
    RateLimiter.clear(:oauth_authorize, @ip)
    RateLimiter.clear(:oauth_authorization_code, @ip)
    RateLimiter.clear(:oauth_client_credentials, @ip)

    previous_flag = Application.get_env(:serviceradar_web_ng, :mcp_enabled, false)
    previous_cc = Application.get_env(:serviceradar_web_ng, :mcp_client_credentials_enabled, true)
    previous_checker = Application.get_env(:serviceradar_web_ng, :mcp_idp_session_checker)
    previous_logout = Application.get_env(:serviceradar_web_ng, :mcp_logout_token_verifier)

    Application.put_env(:serviceradar_web_ng, :mcp_enabled, true)
    Application.put_env(:serviceradar_web_ng, :mcp_client_credentials_enabled, true)

    on_exit(fn ->
      Application.put_env(:serviceradar_web_ng, :mcp_enabled, previous_flag)
      Application.put_env(:serviceradar_web_ng, :mcp_client_credentials_enabled, previous_cc)
      restore_env(:mcp_idp_session_checker, previous_checker)
      restore_env(:mcp_logout_token_verifier, previous_logout)
      RateLimiter.clear(:oauth_authorize, @ip)
      RateLimiter.clear(:oauth_authorization_code, @ip)
      RateLimiter.clear(:oauth_client_credentials, @ip)
    end)

    user = admin_user_fixture()
    %{user: user}
  end

  test "protected resource and authorization server metadata" do
    conn = get(build_conn(), "/.well-known/oauth-protected-resource")
    body = json_response(conn, 200)
    assert body["resource"] =~ "/mcp"
    assert body["bearer_methods_supported"] == ["header"]
    assert "mcp" in body["scopes_supported"]
    assert "read" in body["scopes_supported"]

    conn = get(build_conn(), "/.well-known/oauth-authorization-server")
    body = json_response(conn, 200)
    assert body["authorization_endpoint"] =~ "/oauth/authorize"
    assert body["token_endpoint"] =~ "/oauth/token"
    assert "authorization_code" in body["grant_types_supported"]
    assert "refresh_token" in body["grant_types_supported"]
    assert body["code_challenge_methods_supported"] == ["S256"]
  end

  test "metadata is 404 when MCP is off" do
    Application.put_env(:serviceradar_web_ng, :mcp_enabled, false)

    conn = get(build_conn(), "/.well-known/oauth-protected-resource")
    assert conn.status == 404

    conn = get(build_conn(), "/.well-known/oauth-authorization-server")
    assert conn.status == 404
  end

  test "disabled MCP 404 does not require WWW-Authenticate" do
    Application.put_env(:serviceradar_web_ng, :mcp_enabled, false)
    conn = post(mcp_conn(), "/mcp", initialize_body())
    assert conn.status == 404
    refute List.keyfind(conn.resp_headers, "www-authenticate", 0)
  end

  test "authorize without login stores the request and sends the browser to sign-in" do
    {challenge, _verifier} = pkce()

    conn = build_conn() |> Map.put(:remote_ip, {127, 0, 0, 1}) |> get("/oauth/authorize", authorize_params(challenge))

    assert redirected_to(conn) == "/users/log-in"
    assert get_session(conn, :user_return_to) == "/oauth/consent"
    assert get_session(conn, "mcp_oauth_request")["client_id"] == @client_id
  end

  test "authorize rejects missing PKCE by redirecting to the loopback URI" do
    params = "challenge" |> authorize_params() |> Map.delete("code_challenge_method")

    conn = build_conn() |> Map.put(:remote_ip, {127, 0, 0, 1}) |> get("/oauth/authorize", params)
    location = redirected_to(conn, 302)
    assert location =~ @redirect
    assert location =~ "error=invalid_request"
  end

  test "authorize rejects a non-loopback redirect" do
    {challenge, _verifier} = pkce()

    conn =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> get(
        "/oauth/authorize",
        challenge |> authorize_params() |> Map.put("redirect_uri", "https://evil.example/cb")
      )

    assert json_response(conn, 400)["error"] == "invalid_request"
  end

  test "logged-in user is sent to consent on first grant", %{user: user} do
    {challenge, _verifier} = pkce()

    conn =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> log_in_user(user)
      |> get("/oauth/authorize", authorize_params(challenge))

    assert redirected_to(conn) == "/oauth/consent"
  end

  test "consent approve issues a code that exchanges for an MCP token", %{user: user} do
    {challenge, verifier} = pkce()
    request = request_map(challenge)

    conn =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> log_in_user(user)
      |> Plug.Conn.put_session("mcp_oauth_request", request)

    {:ok, view, html} = live(conn, ~p"/oauth/consent")
    assert html =~ "Authorize MCP access"
    assert html =~ @client_id

    result = render_click(view, "approve", %{})
    url = redirect_url(result)
    code = URI.decode_query(URI.parse(url).query)["code"]
    assert is_binary(code)

    tokens = exchange_code(code, verifier)
    assert tokens["token_type"] == "Bearer"
    assert tokens["expires_in"] == 3600
    assert tokens["scope"] =~ "mcp"
    assert is_binary(tokens["refresh_token"])

    mcp =
      mcp_conn() |> put_req_header("authorization", "Bearer #{tokens["access_token"]}") |> post("/mcp", initialize_body())

    assert json_response(mcp, 200)["result"]["serverInfo"]["name"] == "serviceradar"

    tools =
      mcp_conn() |> put_req_header("authorization", "Bearer #{tokens["access_token"]}") |> post("/mcp", rpc("tools/list"))

    names = Enum.map(json_response(tools, 200)["result"]["tools"], & &1["name"])
    assert Enum.sort(names) == Mcp.v1_tools() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
  end

  test "authorization code is single-use", %{user: user} do
    {challenge, verifier} = pkce()
    {_grant, code} = issue_code!(user, challenge, %{auth_method: :password})

    assert exchange_code(code, verifier)["access_token"]

    conn =
      token_conn(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => @redirect,
        "client_id" => @client_id,
        "code_verifier" => verifier
      })

    assert json_response(conn, 400)["error"] == "invalid_grant"
  end

  test "OIDC grant without IdP refresh omits refresh_token", %{user: user} do
    {challenge, verifier} = pkce()

    {_grant, code} =
      issue_code!(user, challenge, %{
        auth_method: :oidc,
        idp_iss: "https://idp.example",
        idp_sid: "sid-1"
      })

    tokens = exchange_code(code, verifier)
    refute Map.has_key?(tokens, "refresh_token")
  end

  test "refresh succeeds while the IdP session checker returns true", %{user: user} do
    Application.put_env(:serviceradar_web_ng, :mcp_idp_session_checker, fn _ -> true end)

    {challenge, verifier} = pkce()

    {_grant, code} =
      issue_code!(user, challenge, %{
        auth_method: :oidc,
        idp_iss: "https://idp.example",
        idp_sid: "sid-live",
        idp_refresh_token: "idp-rt"
      })

    tokens = exchange_code(code, verifier)
    refreshed = refresh(tokens["refresh_token"])
    assert refreshed["access_token"] != tokens["access_token"]
    assert is_binary(refreshed["refresh_token"])
  end

  test "refresh fails and revokes the family after a simulated IdP logout", %{user: user} do
    Application.put_env(:serviceradar_web_ng, :mcp_idp_session_checker, fn _ -> false end)

    {challenge, verifier} = pkce()

    {_grant, code} =
      issue_code!(user, challenge, %{
        auth_method: :oidc,
        idp_iss: "https://idp.example",
        idp_sid: "sid-dead",
        idp_refresh_token: "idp-rt"
      })

    tokens = exchange_code(code, verifier)
    conn = token_conn(%{"grant_type" => "refresh_token", "refresh_token" => tokens["refresh_token"]})
    assert json_response(conn, 400)["error"] == "invalid_grant"
  end

  test "presenting a rotated refresh token revokes the family", %{user: user} do
    Application.put_env(:serviceradar_web_ng, :mcp_idp_session_checker, fn _ -> true end)

    {challenge, verifier} = pkce()

    {_grant, code} =
      issue_code!(user, challenge, %{
        auth_method: :oidc,
        idp_iss: "https://idp.example",
        idp_sid: "sid-reuse",
        idp_refresh_token: "idp-rt"
      })

    tokens = exchange_code(code, verifier)
    _rotated = refresh(tokens["refresh_token"])
    conn = token_conn(%{"grant_type" => "refresh_token", "refresh_token" => tokens["refresh_token"]})
    assert json_response(conn, 400)["error"] == "invalid_grant"
  end

  test "back-channel logout revokes grants for the IdP session", %{user: user} do
    Application.put_env(:serviceradar_web_ng, :mcp_idp_session_checker, fn _ -> true end)

    Application.put_env(:serviceradar_web_ng, :mcp_logout_token_verifier, fn _ ->
      {:ok, %{"iss" => "https://idp.example", "sid" => "sid-slo"}}
    end)

    {challenge, verifier} = pkce()

    {grant, code} =
      issue_code!(user, challenge, %{
        auth_method: :oidc,
        idp_iss: "https://idp.example",
        idp_sid: "sid-slo",
        idp_refresh_token: "idp-rt"
      })

    tokens = exchange_code(code, verifier)

    conn =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post("/oauth/backchannel-logout", %{"logout_token" => "unused"})

    assert conn.status == 200

    {:ok, updated} = McpOAuthGrant.get_by_id(grant.id, actor: SystemActor.system(:oauth_token))
    assert updated.revoked_at

    conn = token_conn(%{"grant_type" => "refresh_token", "refresh_token" => tokens["refresh_token"]})
    assert json_response(conn, 400)["error"] == "invalid_grant"
  end

  test "client_credentials kill switch rejects mcp-scoped tokens", %{user: user} do
    Application.put_env(:serviceradar_web_ng, :mcp_client_credentials_enabled, false)
    refute FeatureFlags.mcp_client_credentials_enabled?()

    {:ok, client, secret} =
      Credentials.create_client(user.id,
        name: "MCP CC #{System.unique_integer([:positive])}",
        scopes: ["read", "mcp"],
        actor: user
      )

    conn =
      token_conn(%{
        "grant_type" => "client_credentials",
        "client_id" => client.id,
        "client_secret" => secret,
        "scope" => "mcp read"
      })

    assert json_response(conn, 400)["error"] == "unauthorized_client"

    {:ok, read_client, read_secret} =
      Credentials.create_client(user.id,
        name: "Read CC #{System.unique_integer([:positive])}",
        scopes: ["read"],
        actor: user
      )

    conn =
      token_conn(%{
        "grant_type" => "client_credentials",
        "client_id" => read_client.id,
        "client_secret" => read_secret,
        "scope" => "read"
      })

    assert json_response(conn, 200)["access_token"]
  end

  test "user can revoke an MCP grant from settings", %{user: user} do
    {challenge, _verifier} = pkce()
    {grant, _code} = issue_code!(user, challenge, %{auth_method: :password})

    conn = log_in_user(build_conn(), user)
    {:ok, view, html} = live(conn, ~p"/settings/mcp-sessions")
    assert html =~ @client_id

    html = render_click(view, "revoke", %{"id" => to_string(grant.id)})
    assert html =~ "MCP grant revoked."

    {:ok, updated} = McpOAuthGrant.get_by_id(grant.id, actor: SystemActor.system(:oauth_token))
    assert updated.revoked_at
  end

  defp issue_code!(user, challenge, idp) do
    request = request_map(challenge)
    {:ok, grant, url} = Server.complete_authorization(user, request, idp)
    code = URI.decode_query(URI.parse(url).query)["code"]
    {grant, code}
  end

  defp exchange_code(code, verifier) do
    conn =
      token_conn(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => @redirect,
        "client_id" => @client_id,
        "code_verifier" => verifier
      })

    json_response(conn, 200)
  end

  defp refresh(refresh_token) do
    conn = token_conn(%{"grant_type" => "refresh_token", "refresh_token" => refresh_token})
    json_response(conn, 200)
  end

  defp token_conn(params) do
    build_conn()
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> post("/oauth/token", params)
  end

  defp authorize_params(challenge) do
    %{
      "response_type" => "code",
      "client_id" => @client_id,
      "redirect_uri" => @redirect,
      "code_challenge" => challenge,
      "code_challenge_method" => "S256",
      "scope" => "mcp read",
      "state" => "state-1"
    }
  end

  defp request_map(challenge) do
    %{
      "client_id" => @client_id,
      "redirect_uri" => @redirect,
      "code_challenge" => challenge,
      "scope" => "mcp read",
      "state" => "state-1"
    }
  end

  defp pkce do
    verifier = OAuth.random_token()
    {Pkce.challenge_s256(verifier), verifier}
  end

  defp mcp_conn do
    build_conn()
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

  defp initialize_body do
    rpc("initialize", %{
      "protocolVersion" => "2025-03-26",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "mcp-oauth-test", "version" => "0.0.1"}
    })
  end

  defp rpc(method, params \\ %{}) do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
  end

  defp redirect_url({:error, {:redirect, %{to: to}}}), do: to
  defp redirect_url({:error, {:live_redirect, %{to: to}}}), do: to
  defp redirect_url(other) when is_binary(other), do: flunk("expected redirect, got html")
  defp redirect_url(other), do: flunk("expected redirect, got: #{inspect(other)}")

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
