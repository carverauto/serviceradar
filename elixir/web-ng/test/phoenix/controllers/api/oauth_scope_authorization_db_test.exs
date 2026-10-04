defmodule ServiceRadarWebNGWeb.Api.OAuthScopeAuthorizationDbTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Identity.OAuthClient.Credentials
  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.Mcp.OAuth.Pkce
  alias ServiceRadarWebNG.Mcp.OAuth.Server
  alias ServiceRadarWebNGWeb.UserAuth

  @moduletag :web_ng_shared_fixture_db

  setup do
    RateLimiter.clear(:oauth_client_credentials, "127.0.0.1")
    on_exit(fn -> RateLimiter.clear(:oauth_client_credentials, "127.0.0.1") end)
    :ok
  end

  test "read OAuth clients cannot mutate rules even when their owners can" do
    for user <- [admin_user_fixture(), operator_user_fixture()] do
      read_token = client_token(user, "read")
      write_token = client_token(user, "write")

      for {path, type, attrs} <- rule_resources() do
        created = write_token |> request() |> post(path, payload(type, attrs)) |> json_response(201)
        id = created["data"]["id"]
        detail = "#{path}/#{id}"
        assert read_token |> request() |> get(detail) |> json_response(200) |> get_in(["data", "id"]) == id

        new_attrs = Map.put(attrs, "name", "#{attrs["name"]} denied")
        update = type |> payload(%{"enabled" => false}) |> put_in(["data", "id"], id)

        for denied <- [
              read_token |> request() |> post(path, payload(type, new_attrs)),
              read_token |> request() |> patch(detail, update),
              read_token |> request() |> delete(detail)
            ] do
          assert json_response(denied, 403)["error"] == "insufficient_scope"
        end

        persisted = read_token |> request() |> get(detail) |> json_response(200)
        assert persisted["data"]["attributes"]["enabled"] == true
        rules = read_token |> request() |> get(path) |> json_response(200)
        refute Enum.any?(rules["data"], &(&1["attributes"]["name"] == new_attrs["name"]))

        updated = write_token |> request() |> patch(detail, update) |> json_response(200)
        assert updated["data"]["attributes"]["enabled"] == false
        assert (write_token |> request() |> delete(detail)).status == 200
      end
    end
  end

  test "empty, unknown, MCP and narrow API grants cannot inherit user RBAC" do
    user = admin_user_fixture()

    for scopes <- [[], ["unknown.scope"], ["mcp"], ["dashboard.publish"], ["plugins.manage"]] do
      {:ok, token, _claims} = Guardian.create_api_token(user, scopes: scopes)

      for {path, type, attrs} <- rule_resources() do
        for denied <- [token |> request() |> get(path), token |> request() |> post(path, payload(type, attrs))] do
          assert json_response(denied, 403)["error"] == "insufficient_scope"
        end
      end
    end
  end

  test "a write API grant does not replace the viewer owner's resource permission checks" do
    {:ok, token, _claims} = Guardian.create_api_token(viewer_user_fixture(), scopes: ["write"])

    for {path, type, attrs} <- rule_resources() do
      denied = token |> request() |> post(path, payload(type, attrs))
      assert denied.status == 403
      assert Enum.any?(json_response(denied, 403)["errors"], &(&1["code"] == "forbidden"))
    end
  end

  test "API grants cannot enter browser authorization to inherit an existing MCP grant" do
    previous = Application.get_env(:serviceradar_web_ng, :mcp_enabled, false)
    Application.put_env(:serviceradar_web_ng, :mcp_enabled, true)
    on_exit(fn -> Application.put_env(:serviceradar_web_ng, :mcp_enabled, previous) end)
    RateLimiter.clear(:oauth_authorize, "127.0.0.1")
    on_exit(fn -> RateLimiter.clear(:oauth_authorize, "127.0.0.1") end)

    user = admin_user_fixture()
    {:ok, _grant} = Server.upsert_grant(user, %{client_id: "serviceradar-mcp", scope: "mcp read", auth_method: :password})

    params = %{
      "client_id" => "serviceradar-mcp",
      "response_type" => "code",
      "redirect_uri" => "http://127.0.0.1:43721/callback",
      "scope" => "mcp read",
      "code_challenge" => Pkce.challenge_s256(String.duplicate("s", 64)),
      "code_challenge_method" => "S256"
    }

    for scopes <- [["read"], ["write"], ["admin"], ["mcp"]] do
      {:ok, token, _claims} = Guardian.create_api_token(user, scopes: scopes)
      denied = token |> request() |> get("/oauth/authorize", params)
      assert json_response(denied, 403)["error"] == "insufficient_scope"
      assert get_resp_header(denied, "location") == []

      if scopes != ["mcp"] do
        for path <- ["/v1/stream/synthetic-session", "/topology/snapshot/latest", "/topology/tiles/search"] do
          authenticated =
            :get
            |> build_conn(path)
            |> put_req_header("authorization", "Bearer #{token}")
            |> Plug.Test.init_test_session(%{})
            |> UserAuth.fetch_current_scope_for_user([])

          refute authenticated.halted
          assert authenticated.assigns.current_scope.user.id == user.id
        end
      end
    end

    {:ok, access_token, _claims} = Guardian.create_access_token(user)

    for conn <- [log_in_user(build_conn(), user), request(access_token)] do
      allowed = get(conn, "/oauth/authorize", params)

      code =
        allowed |> redirected_to(302) |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("code")

      assert is_binary(code) and code != ""
    end
  end

  defp client_token(user, scope) do
    {:ok, client, secret} =
      Credentials.create_client(user.id,
        name: "Synthetic scope client #{System.unique_integer([:positive])}",
        scopes: [scope],
        actor: system_actor()
      )

    build_conn()
    |> post("/oauth/token", %{
      "grant_type" => "client_credentials",
      "client_id" => client.id,
      "client_secret" => secret
    })
    |> json_response(200)
    |> Map.fetch!("access_token")
  end

  defp request(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/vnd.api+json")
  end

  defp payload(type, attrs), do: %{"data" => %{"type" => type, "attributes" => attrs}}

  defp rule_resources do
    suffix = System.unique_integer([:positive])

    [
      {"/api/v2/event-rules", "event-rule",
       %{"name" => "Synthetic event rule #{suffix}", "source_type" => "log", "enabled" => true}},
      {"/api/v2/stateful-alert-rules", "stateful-alert-rule",
       %{"name" => "Synthetic alert rule #{suffix}", "signal" => "log", "match" => %{}, "enabled" => true}}
    ]
  end
end
