defmodule ServiceRadarWebNGWeb.CliAuthControllerTest do
  @moduledoc """
  DB-backed integration tests for the RFC 8628 CLI device-code flow.

  Covers proposal `add-cli-device-auth` §3.7 + §4.7 + §12.8.

  Run via the srql-fixtures CNPG instance per
  `.agents/skills/srql-fixtures-db-tests/SKILL.md`:

      SERVICERADAR_TEST_DATABASE_URL="postgres://..." \\
      SERVICERADAR_TEST_DATABASE_POOL_SIZE=1 \\
      SERVICERADAR_TEST_SANDBOX_MODE=shared \\
      MIX_ENV=test mix test test/phoenix/controllers/cli_auth_controller_test.exs
  """
  use ServiceRadarWebNGWeb.ConnCase, async: false

  @moduletag :web_ng_shared_fixture_db

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.CliAuthorizationCode
  alias ServiceRadar.Identity.CliSession
  alias ServiceRadar.Identity.DeviceAuthorization
  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNG.AccountsFixtures

  @moduletag :integration

  @device_action :cli_device_auth
  @client_id "serviceradar-cli"
  @ip "127.0.0.1"

  setup do
    RateLimiter.clear(@device_action, @ip)

    on_exit(fn ->
      RateLimiter.clear(@device_action, @ip)
    end)

    :ok
  end

  describe "POST /api/v1/cli/auth/device" do
    test "happy path returns RFC 8628 §3.2 payload + persists a hashed device code",
         %{conn: conn} do
      params = %{"client_id" => @client_id, "scope" => "dashboard.publish"}
      conn = post_with_ip(conn, ~p"/api/v1/cli/auth/device", params)
      body = json_response(conn, 200)

      assert is_binary(body["device_code"])
      assert byte_size(body["device_code"]) >= 30
      assert Regex.match?(~r/^[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}$/, body["user_code"])
      assert String.ends_with?(body["verification_uri"], "/cli/auth/device")
      assert body["verification_uri_complete"] =~ ~r/\?user_code=[A-Z]{4}-[A-Z]{4}$/
      assert body["expires_in"] == 900
      assert body["interval"] == 5

      # The persisted row stores only the SHA-256 hash, never the plaintext.
      hash = :sha256 |> :crypto.hash(body["device_code"]) |> Base.encode16(case: :lower)
      actor = SystemActor.system(:test)
      {:ok, row} = DeviceAuthorization.get_by_device_code_hash(hash, actor: actor)
      assert row.status == :pending
      assert row.client_id == @client_id
      assert row.user_code == body["user_code"]
      assert row.scope == "dashboard.publish"
    end

    test "accepts the edge.manage scope alongside dashboard.publish by default", %{conn: conn} do
      params = %{"client_id" => @client_id, "scope" => "dashboard.publish edge.manage"}
      body = conn |> post_with_ip(~p"/api/v1/cli/auth/device", params) |> json_response(200)

      assert is_binary(body["device_code"])
    end

    test "rejects unknown client_id with 400 invalid_client", %{conn: conn} do
      conn =
        post_with_ip(conn, ~p"/api/v1/cli/auth/device", %{
          "client_id" => "totally-bogus",
          "scope" => "dashboard.publish"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_client"
    end

    test "rejects scope outside cli_allowed_scopes with 400 invalid_scope", %{conn: conn} do
      # Default cli_allowed_scopes is ["dashboard.publish"].
      conn =
        post_with_ip(conn, ~p"/api/v1/cli/auth/device", %{
          "client_id" => @client_id,
          "scope" => "admin"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_scope"
    end

    test "returns 503 cli_auth_disabled when AuthorizationSettings.cli_auth_enabled = false",
         %{conn: conn} do
      with_cli_auth_disabled(fn ->
        conn =
          post_with_ip(conn, ~p"/api/v1/cli/auth/device", %{
            "client_id" => @client_id,
            "scope" => "dashboard.publish"
          })

        assert json_response(conn, 503)["error"] == "cli_auth_disabled"
      end)
    end

    test "rate-limits the next request once the device bucket is full", %{conn: conn} do
      {limit, _window} = RateLimiter.resolve_bucket(@device_action, [])
      Enum.each(1..limit, fn _ -> RateLimiter.record(@device_action, @ip) end)

      conn =
        post_with_ip(conn, ~p"/api/v1/cli/auth/device", %{
          "client_id" => @client_id,
          "scope" => "dashboard.publish"
        })

      assert json_response(conn, 429)["error"] == "rate_limited"
      [retry_after] = get_resp_header(conn, "retry-after")
      assert {n, _} = Integer.parse(retry_after)
      assert n >= 1 and n <= 60
    end
  end

  describe "POST /api/v1/cli/auth/token" do
    test "rejects non-device-code grant_type with 400 unsupported_grant_type",
         %{conn: conn} do
      conn =
        post_with_ip(conn, ~p"/api/v1/cli/auth/token", %{
          "grant_type" => "password",
          "device_code" => "anything"
        })

      assert json_response(conn, 400)["error"] == "unsupported_grant_type"
    end

    test "missing device_code returns 400 invalid_request", %{conn: conn} do
      conn =
        post_with_ip(conn, ~p"/api/v1/cli/auth/token", %{
          "grant_type" => "urn:ietf:params:oauth:grant-type:device_code"
        })

      assert json_response(conn, 400)["error"] == "invalid_request"
    end

    test "unknown device_code returns 400 invalid_grant", %{conn: conn} do
      conn =
        post_with_ip(conn, ~p"/api/v1/cli/auth/token", %{
          "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
          "device_code" => "garbage-#{System.unique_integer()}"
        })

      assert json_response(conn, 400)["error"] == "invalid_grant"
    end

    test "pending row returns 400 authorization_pending", %{conn: conn} do
      {device_code, _user_code} = mint_pending(conn)

      conn = poll_token(conn, device_code)

      assert json_response(conn, 400)["error"] == "authorization_pending"
    end

    test "denied row returns 400 access_denied", %{conn: conn} do
      {device_code, user_code} = mint_pending(conn)
      deny_by_user_code!(user_code)

      conn = poll_token(conn, device_code)

      assert json_response(conn, 400)["error"] == "access_denied"
    end

    test "approved row returns 200 with access_token + scope + user envelope",
         %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      {device_code, user_code} = mint_pending(conn)
      approve_by_user_code!(user_code, user.id)

      conn = poll_token(conn, device_code)
      body = json_response(conn, 200)

      assert is_binary(body["access_token"])
      assert body["token_type"] == "Bearer"
      assert is_integer(body["expires_in"]) and body["expires_in"] > 0
      assert body["scope"] == "dashboard.publish"
      assert body["user"]["id"] == user.id
      assert body["user"]["email"] == to_string(user.email)
    end

    test "expired row returns 400 expired_token", %{conn: conn} do
      {device_code, _user_code} = mint_pending_expired(conn)

      conn = poll_token(conn, device_code)

      assert json_response(conn, 400)["error"] == "expired_token"
    end
  end

  describe "POST /api/v1/cli/auth/token authorization_code" do
    setup do
      user = AccountsFixtures.user_fixture()
      %{user: user}
    end

    test "exchanges a matching verifier for a bearer token and a CLI session",
         %{conn: conn, user: user} do
      {verifier, code} = mint_pkce_code(user)

      conn = exchange_code(conn, code, verifier)
      body = json_response(conn, 200)

      assert body["token_type"] == "Bearer"
      assert is_binary(body["access_token"])
      assert body["scope"] == "dashboard.publish"
      assert body["user"]["id"] == user.id
      assert body["user"]["email"] == to_string(user.email)
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      actor = SystemActor.system(:test)
      {:ok, sessions} = CliSession.list_active_by_user(user.id, actor: actor)
      assert [%{device_authorization_id: nil, client_id: @client_id}] = sessions
    end

    test "a second exchange of the same code is invalid_grant", %{conn: conn, user: user} do
      {verifier, code} = mint_pkce_code(user)

      assert json_response(exchange_code(conn, code, verifier), 200)
      assert json_response(exchange_code(conn, code, verifier), 400)["error"] == "invalid_grant"
    end

    test "a wrong verifier is invalid_grant and leaves the code usable", %{conn: conn, user: user} do
      {verifier, code} = mint_pkce_code(user)
      {other, _other_code} = mint_pkce_code(user)

      assert json_response(exchange_code(conn, code, other), 400)["error"] == "invalid_grant"

      body = json_response(exchange_code(conn, code, verifier), 200)
      assert body["token_type"] == "Bearer"
    end

    test "a different loopback redirect is invalid_grant and leaves the code usable",
         %{conn: conn, user: user} do
      {verifier, code} = mint_pkce_code(user)

      mismatch =
        exchange_code(conn, code, verifier, %{
          "redirect_uri" => "http://127.0.0.1:4318/cli/auth/callback"
        })

      assert json_response(mismatch, 400)["error"] == "invalid_grant"

      body = json_response(exchange_code(conn, code, verifier), 200)
      assert is_binary(body["access_token"])
    end

    test "an unknown client_id is invalid_client and leaves the code usable",
         %{conn: conn, user: user} do
      {verifier, code} = mint_pkce_code(user)

      rejected =
        exchange_code(conn, code, verifier, %{"client_id" => "other-client"})

      assert json_response(rejected, 400)["error"] == "invalid_client"

      body = json_response(exchange_code(conn, code, verifier), 200)
      assert is_binary(body["access_token"])
    end

    test "an expired code is invalid_grant", %{conn: conn, user: user} do
      {verifier, code} = mint_pkce_code(user)
      expire_pkce_code!(code)

      assert json_response(exchange_code(conn, code, verifier), 400)["error"] == "invalid_grant"
    end
  end

  describe "AuthorizationSettings.cli_auth_enabled = false" do
    test "blocks the token endpoint too", %{conn: conn} do
      {device_code, _user_code} = mint_pending(conn)

      with_cli_auth_disabled(fn ->
        conn = poll_token(conn, device_code)
        ## Helpers
        assert json_response(conn, 503)["error"] == "cli_auth_disabled"
      end)
    end
  end

  defp post_with_ip(conn, path, params) do
    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> post(path, params)
  end

  defp poll_token(conn, device_code) do
    post_with_ip(conn, ~p"/api/v1/cli/auth/token", %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
      "device_code" => device_code
    })
  end

  @pkce_redirect "http://127.0.0.1:4317/cli/auth/callback"

  defp exchange_code(conn, code, verifier, overrides \\ %{}) do
    params =
      Map.merge(
        %{
          "grant_type" => "authorization_code",
          "client_id" => @client_id,
          "code" => code,
          "redirect_uri" => @pkce_redirect,
          "code_verifier" => verifier
        },
        overrides
      )

    post_with_ip(conn, ~p"/api/v1/cli/auth/token", params)
  end

  defp mint_pkce_code(user) do
    verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
    plaintext = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    actor = SystemActor.system(:cli_auth)

    {:ok, _row} =
      CliAuthorizationCode.create(
        %{
          user_id: user.id,
          client_id: @client_id,
          code_hash: :sha256 |> :crypto.hash(plaintext) |> Base.encode16(case: :lower),
          redirect_uri: @pkce_redirect,
          code_challenge: challenge,
          scope: "dashboard.publish",
          expires_at: DateTime.shift(DateTime.utc_now(), minute: 10)
        },
        actor: actor
      )

    {verifier, plaintext}
  end

  defp expire_pkce_code!(plaintext) do
    hash = :sha256 |> :crypto.hash(plaintext) |> Base.encode16(case: :lower)
    actor = SystemActor.system(:test)
    {:ok, row} = CliAuthorizationCode.get_by_code_hash(hash, actor: actor)
    past = DateTime.shift(DateTime.utc_now(), hour: -1)

    SQL.query!(
      ServiceRadar.Repo,
      "UPDATE platform.cli_authorization_codes SET expires_at = $1 WHERE id = $2",
      [past, Ecto.UUID.dump!(row.id)]
    )
  end

  defp mint_pending(conn) do
    body =
      conn
      |> post_with_ip(~p"/api/v1/cli/auth/device", %{
        "client_id" => @client_id,
        "scope" => "dashboard.publish"
      })
      |> json_response(200)

    {body["device_code"], body["user_code"]}
  end

  defp mint_pending_expired(conn) do
    {device_code, user_code} = mint_pending(conn)
    actor = SystemActor.system(:test)
    {:ok, row} = DeviceAuthorization.get_by_user_code(user_code, actor: actor)

    # Force the row past its TTL via Ecto so we bypass the Ash validations
    # that lock the changeset after the action callback runs.
    past = DateTime.shift(DateTime.utc_now(), hour: -1)

    SQL.query!(
      ServiceRadar.Repo,
      "UPDATE platform.device_authorizations SET expires_at = $1 WHERE id = $2",
      [past, Ecto.UUID.dump!(row.id)]
    )

    {device_code, user_code}
  end

  defp approve_by_user_code!(user_code, user_id) do
    actor = SystemActor.system(:test)
    {:ok, row} = DeviceAuthorization.get_by_user_code(user_code, actor: actor)
    {:ok, _} = DeviceAuthorization.approve(row, user_id, actor: actor)
    :ok
  end

  defp deny_by_user_code!(user_code) do
    actor = SystemActor.system(:test)
    {:ok, row} = DeviceAuthorization.get_by_user_code(user_code, actor: actor)
    {:ok, _} = DeviceAuthorization.deny(row, actor: actor)
    :ok
  end

  defp with_cli_auth_disabled(fun) do
    actor = SystemActor.system(:test)
    settings = ensure_settings(actor)

    {:ok, _} =
      AuthorizationSettings.update_settings(settings, %{cli_auth_enabled: false}, actor: actor)

    try do
      fun.()
    after
      {:ok, current} = AuthorizationSettings.get_settings(actor: actor)
      AuthorizationSettings.update_settings(current, %{cli_auth_enabled: true}, actor: actor)
    end
  end

  defp ensure_settings(actor) do
    case AuthorizationSettings.get_settings(actor: actor) do
      {:ok, %{} = settings} ->
        settings

      _ ->
        {:ok, settings} = AuthorizationSettings.create_settings(%{}, actor: actor)
        settings
    end
  end
end
