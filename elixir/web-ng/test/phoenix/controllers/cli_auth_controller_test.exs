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

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthorizationSettings
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

    test "rate-limits at the 11th request in the same window", %{conn: conn} do
      # Fill the bucket; 11th call should 429.
      Enum.each(1..10, fn _ -> RateLimiter.record(@device_action, @ip) end)

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

  describe "AuthorizationSettings.cli_auth_enabled = false" do
    test "blocks the token endpoint too", %{conn: conn} do
      {device_code, _user_code} = mint_pending(conn)

      with_cli_auth_disabled(fn ->
        conn = poll_token(conn, device_code)
        assert json_response(conn, 503)["error"] == "cli_auth_disabled"
      end)
    end
  end

  ## Helpers

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
    past = DateTime.add(DateTime.utc_now(), -3600, :second)

    Ecto.Adapters.SQL.query!(
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
