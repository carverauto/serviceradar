defmodule ServiceRadarWebNGWeb.AuthControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.Users
  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNGWeb.Auth.ConfigCache

  require Ash.Query

  @password_action :auth_local
  @reset_action :auth_password_reset
  @ip "127.0.0.1"
  @fixture_password "test_password_123!"

  setup do
    RateLimiter.clear(@password_action, @ip)
    RateLimiter.clear(@reset_action, @ip)

    on_exit(fn ->
      RateLimiter.clear(@password_action, @ip)
      RateLimiter.clear(@reset_action, @ip)
    end)

    :ok
  end

  test "password login is rate limited before authentication work begins", %{conn: conn} do
    Enum.each(1..10, fn _ -> RateLimiter.record(@password_action, @ip) end)

    conn =
      conn
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("accept", "text/html")
      |> post(~p"/auth/sign-in", %{
        "user" => %{"email" => "nobody@example.com", "password" => "bad-password"}
      })

    assert redirected_to(conn, 303) == ~p"/users/log-in"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
             "Too many login attempts. Please try again"
  end

  test "password reset is rate limited before notifier work begins", %{conn: conn} do
    Enum.each(1..5, fn _ -> RateLimiter.record(@reset_action, @ip) end)

    conn =
      conn
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("accept", "text/html")
      |> post(~p"/auth/password-reset", %{
        "user" => %{"email" => "nobody@example.com"}
      })

    assert redirected_to(conn, 303) == ~p"/auth/password-reset"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
             "Too many password reset requests. Please try again"
  end

  describe "server-side local-login enforcement" do
    setup do
      previous_loader = Application.get_env(:serviceradar_web_ng, :auth_settings_loader)
      previous_auth = Application.get_env(:serviceradar_web_ng, :auth, [])
      Application.put_env(:serviceradar_web_ng, :auth, force_local_login: false, disable_sso: false)

      on_exit(fn ->
        if previous_loader do
          Application.put_env(:serviceradar_web_ng, :auth_settings_loader, previous_loader)
        else
          Application.delete_env(:serviceradar_web_ng, :auth_settings_loader)
        end

        Application.put_env(:serviceradar_web_ng, :auth, previous_auth)
        clear_auth_cache()
      end)

      :ok
    end

    test "denies a regular (SSO-only) account when SSO is enforced", %{conn: conn} do
      set_auth_mode(:active_sso)
      user = AshTestHelpers.user_fixture()
      {:ok, _} = set_local_login(user, false)

      conn = post_login(conn, user.email, @fixture_password)

      assert redirected_to(conn) == "/auth/oidc"
      assert is_nil(get_session(conn, "user_token"))
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "organization's SSO"
    end

    test "denies a regular account at the /auth/local backdoor too", %{conn: conn} do
      set_auth_mode(:active_sso)
      user = AshTestHelpers.user_fixture()
      {:ok, _} = set_local_login(user, false)

      conn =
        conn
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> post(~p"/auth/local/sign-in", %{
          "user" => %{"email" => to_string(user.email), "password" => @fixture_password}
        })

      assert redirected_to(conn) == "/auth/oidc"
      assert is_nil(get_session(conn, "user_token"))
    end

    test "allows an opted-in account when SSO is enforced", %{conn: conn} do
      set_auth_mode(:active_sso)
      # Locally-registered fixture users are local_login_enabled by default.
      user = AshTestHelpers.user_fixture()

      conn = post_login(conn, user.email, @fixture_password)

      assert redirected_to(conn) == ~p"/dashboard"
      assert get_session(conn, "user_token")
    end

    test "password login replaces a historical SSO authentication method before session creation", %{
      conn: conn
    } do
      set_auth_mode(:active_sso)
      user = AshTestHelpers.user_fixture()
      actor = SystemActor.system(:test)

      assert {:ok, _user} = Users.record_login(user, :oidc, actor: actor)

      conn = post_login(conn, user.email, @fixture_password)

      assert redirected_to(conn) == ~p"/dashboard"
      assert get_session(conn, "user_token")
      assert {:ok, persisted} = Ash.get(User, user.id, actor: actor)
      assert persisted.last_auth_method == :password
    end

    test "password_only mode allows any account regardless of the flag", %{conn: conn} do
      set_auth_mode(:password_only)
      user = AshTestHelpers.user_fixture()
      {:ok, _} = set_local_login(user, false)

      conn = post_login(conn, user.email, @fixture_password)

      assert redirected_to(conn) == ~p"/dashboard"
      assert get_session(conn, "user_token")
    end

    test "break-glass env permits an SSO-only account with a valid password", %{conn: conn} do
      set_auth_mode(:active_sso)
      Application.put_env(:serviceradar_web_ng, :auth, force_local_login: true, disable_sso: false)
      user = AshTestHelpers.user_fixture()
      {:ok, _} = set_local_login(user, false)

      conn = post_login(conn, user.email, @fixture_password)

      assert redirected_to(conn) == ~p"/dashboard"
      assert get_session(conn, "user_token")
    end

    test "does not issue a reset credential for an SSO-provisioned identity", %{conn: conn} do
      set_auth_mode(:active_sso)

      {:ok, user} =
        User.provision_sso_user(
          %{
            email: "reset-sso-only@example.com",
            display_name: "Reset SSO Only",
            external_id: "oidc|reset-sso-only",
            provider: :oidc
          },
          actor: AshTestHelpers.system_actor()
        )

      conn = request_password_reset(conn, user.email)

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If your email is in our system"
      refute_email_sent()
    end

    test "local-password recovery records the current password authentication before login", %{
      conn: conn
    } do
      set_auth_mode(:active_sso)
      user = AshTestHelpers.user_fixture()

      conn = request_password_reset(conn, user.email)
      assert redirected_to(conn) == ~p"/users/log-in"
      assert_receive {:email, email}
      token = reset_token(email.text_body)

      conn =
        conn
        |> recycle()
        |> put(~p"/auth/password-reset/#{token}", %{
          "user" => %{
            "password" => "new_local_password_123!",
            "password_confirmation" => "new_local_password_123!"
          }
        })

      assert redirected_to(conn) == ~p"/dashboard"
      assert get_session(conn, "user_token")

      assert {:ok, persisted} =
               Ash.get(User, user.id, actor: SystemActor.system(:password_reset_test))

      assert persisted.last_auth_method == :password
    end

    test "consumption rechecks local recovery policy after a reset token was issued", %{conn: conn} do
      set_auth_mode(:active_sso)
      user = AshTestHelpers.user_fixture()

      conn = request_password_reset(conn, user.email)
      assert_receive {:email, email}
      token = reset_token(email.text_body)
      assert {:ok, _user} = set_local_login(user, false)

      conn =
        conn
        |> recycle()
        |> put(~p"/auth/password-reset/#{token}", %{
          "user" => %{
            "password" => "policy_race_password_123!",
            "password_confirmation" => "policy_race_password_123!"
          }
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      assert is_nil(get_session(conn, "user_token"))

      assert {:error, _reason} =
               User.authenticate(user.email, "policy_race_password_123!", actor: AshTestHelpers.system_actor())
    end
  end

  defp post_login(conn, email, password) do
    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> post(~p"/auth/sign-in", %{
      "user" => %{"email" => to_string(email), "password" => password}
    })
  end

  defp request_password_reset(conn, email) do
    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> post(~p"/auth/password-reset", %{
      "user" => %{"email" => to_string(email)}
    })
  end

  defp reset_token(body) do
    assert [_, token] = Regex.run(~r{/auth/password-reset/([^\s]+)}, body)
    token
  end

  defp set_auth_mode(mode) do
    settings = %{is_enabled: mode != :password_only, mode: mode, provider_type: :oidc}
    Application.put_env(:serviceradar_web_ng, :auth_settings_loader, fn -> {:ok, settings} end)
    clear_auth_cache()
    ConfigCache.refresh()
    :ok
  end

  defp set_local_login(user, enabled) do
    user
    |> Ash.Changeset.for_update(:set_local_login, %{local_login_enabled: enabled}, actor: AshTestHelpers.system_actor())
    |> Ash.update()
  end

  defp clear_auth_cache do
    if :ets.whereis(ConfigCache) != :undefined, do: :ets.delete(ConfigCache, :auth_settings)
    :ok
  end
end
