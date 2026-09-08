defmodule ServiceRadarWebNGWeb.Auth.LoginPolicyTest do
  # async: false — the break-glass switch is read from global application env.
  use ExUnit.Case, async: false

  alias ServiceRadarWebNGWeb.Auth.LoginPolicy

  # Pure unit test — no database required.
  @moduletag :db_free

  @app :serviceradar_web_ng

  setup do
    original = Application.get_env(@app, :auth, [])
    on_exit(fn -> Application.put_env(@app, :auth, original) end)
    :ok
  end

  defp set_auth(opts), do: Application.put_env(@app, :auth, opts)

  defp user(hashed_password, local_login_enabled),
    do: %{hashed_password: hashed_password, local_login_enabled: local_login_enabled}

  @password_only %{is_enabled: true, mode: :password_only}
  @sso_disabled %{is_enabled: false, mode: :active_sso}
  @active_sso %{is_enabled: true, mode: :active_sso}
  @passive_proxy %{is_enabled: true, mode: :passive_proxy}

  describe "break-glass env switch (always wins, checked first)" do
    setup do
      set_auth(force_local_login: true, disable_sso: false)
      :ok
    end

    test "permits local login under every mode for an account with a password" do
      hp = "$2b$hash"

      for settings <- [@password_only, @sso_disabled, @active_sso, @passive_proxy, nil],
          enabled <- [true, false] do
        assert LoginPolicy.local_login_allowed?(user(hp, enabled), settings),
               "expected allow for settings=#{inspect(settings)} enabled=#{enabled}"
      end
    end

    test "force_local_login?/0 reflects the switch" do
      assert LoginPolicy.force_local_login?()
    end
  end

  describe "break-glass off" do
    setup do
      set_auth(force_local_login: false, disable_sso: false)
      :ok
    end

    test "denies an account with no password hash regardless of mode/flag" do
      for settings <- [@password_only, @sso_disabled, @active_sso, @passive_proxy, nil],
          enabled <- [true, false] do
        refute LoginPolicy.local_login_allowed?(user(nil, enabled), settings),
               "expected deny (no password) for settings=#{inspect(settings)} enabled=#{enabled}"
      end
    end

    test "password_only mode allows any account with a password" do
      hp = "$2b$hash"

      for settings <- [@password_only, @sso_disabled], enabled <- [true, false] do
        assert LoginPolicy.local_login_allowed?(user(hp, enabled), settings),
               "expected allow for settings=#{inspect(settings)} enabled=#{enabled}"
      end
    end

    test "SSO modes allow only opted-in accounts" do
      hp = "$2b$hash"

      for settings <- [@active_sso, @passive_proxy] do
        assert LoginPolicy.local_login_allowed?(user(hp, true), settings)
        refute LoginPolicy.local_login_allowed?(user(hp, false), settings)
      end
    end

    test "fail-closed: nil settings deny a non-opted-in account but allow an opted-in one" do
      hp = "$2b$hash"
      refute LoginPolicy.local_login_allowed?(user(hp, false), nil)
      assert LoginPolicy.local_login_allowed?(user(hp, true), nil)
    end

    test "force_local_login?/0 is false" do
      refute LoginPolicy.force_local_login?()
    end
  end

  describe "full matrix (env off): hashed_password nil takes precedence over mode/flag" do
    setup do
      set_auth(force_local_login: false, disable_sso: false)
      :ok
    end

    test "every combination matches the documented order" do
      for settings <- [@password_only, @sso_disabled, @active_sso, @passive_proxy, nil],
          enabled <- [true, false],
          hp <- [nil, "$2b$hash"] do
        expected =
          cond do
            is_nil(hp) -> false
            settings in [@password_only, @sso_disabled] -> true
            enabled -> true
            true -> false
          end

        assert LoginPolicy.local_login_allowed?(user(hp, enabled), settings) == expected,
               "settings=#{inspect(settings)} enabled=#{enabled} hp=#{inspect(hp)} expected=#{expected}"
      end
    end
  end

  describe "disable_sso?/0 and sso_entry_path/1" do
    test "disable_sso? reflects the switch" do
      set_auth(force_local_login: false, disable_sso: true)
      assert LoginPolicy.disable_sso?()

      set_auth(force_local_login: false, disable_sso: false)
      refute LoginPolicy.disable_sso?()
    end

    test "sso_entry_path points at SSO entry only for active SSO modes with SSO enabled" do
      set_auth(force_local_login: false, disable_sso: false)

      assert LoginPolicy.sso_entry_path(@active_sso) == "/auth/oidc"
      assert LoginPolicy.sso_entry_path(@passive_proxy) == "/auth/oidc"
      assert LoginPolicy.sso_entry_path(@password_only) == "/users/log-in"
      assert LoginPolicy.sso_entry_path(@sso_disabled) == "/users/log-in"
      assert LoginPolicy.sso_entry_path(nil) == "/users/log-in"
    end

    test "sso_entry_path falls back to local login when SSO button is disabled" do
      set_auth(force_local_login: false, disable_sso: true)
      assert LoginPolicy.sso_entry_path(@active_sso) == "/users/log-in"
    end
  end
end
