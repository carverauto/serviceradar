defmodule ServiceRadarWebNGWeb.Settings.AuthorizationLiveTest do
  @moduledoc """
  The Settings -> Authorization surface: the dry-run resolver and the warning
  that a groups mapping cannot match because the scope is not requested.

  Both exist for the same reason. A mapping that matches nothing and a mapping
  that is wrong look identical from the outside, and the only way to tell them
  apart used to be signing in as the affected user.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.AuthSettings
  alias ServiceRadarWebNG.AshTestHelpers

  defp settings!(mappings) do
    actor = SystemActor.system(:authorization_live_test)
    attrs = %{default_role: :viewer, role_mappings: mappings}

    case AuthorizationSettings.get_settings(actor: actor) do
      {:ok, %AuthorizationSettings{} = existing} ->
        {:ok, settings} = AuthorizationSettings.update_settings(existing, attrs, actor: actor)
        settings

      _not_found ->
        {:ok, settings} = AuthorizationSettings.create_settings(attrs, actor: actor)
        settings
    end
  end

  describe "dry-run resolver" do
    test "resolves a pasted claim set without signing anyone in", %{conn: conn} do
      settings!([%{"source" => "groups", "value" => "ops", "role" => "operator"}])
      admin = AshTestHelpers.admin_user_fixture()

      {:ok, live, html} =
        conn |> log_in_user(admin) |> live(~p"/settings/auth/authorization")

      assert html =~ "Settings Console"
      assert html =~ "Default built-in role"
      assert html =~ "Role profile"

      html =
        live
        |> form("#dry-run-form", dry_run: %{claims: ~s({"groups": ["ops"]})})
        |> render_submit()

      assert html =~ "operator"
    end

    test "reports malformed claim JSON instead of resolving it", %{conn: conn} do
      settings!([%{"source" => "groups", "value" => "ops", "role" => "operator"}])
      admin = AshTestHelpers.admin_user_fixture()

      {:ok, live, _html} =
        conn |> log_in_user(admin) |> live(~p"/settings/auth/authorization")

      html =
        live
        |> form("#dry-run-form", dry_run: %{claims: "not json"})
        |> render_submit()

      assert html =~ "Invalid JSON"
      refute html =~ "Resolved role"
    end
  end

  describe "RBAC" do
    test "redirects viewers without settings.auth.manage", %{conn: conn} do
      user = AshTestHelpers.viewer_user_fixture()
      conn = log_in_user(conn, user)

      assert {:error, {:live_redirect, %{to: "/dashboard"} = info}} =
               live(conn, ~p"/settings/auth/authorization")

      assert is_map(info.flash)
    end

    test "redirects operators without settings.auth.manage", %{conn: conn} do
      user = AshTestHelpers.operator_user_fixture()
      conn = log_in_user(conn, user)

      assert {:error, {:live_redirect, %{to: "/dashboard"} = info}} =
               live(conn, ~p"/settings/auth/authorization")

      assert is_map(info.flash)
    end

    test "allows admins with settings.auth.manage", %{conn: conn} do
      user = AshTestHelpers.admin_user_fixture()
      conn = log_in_user(conn, user)

      {:ok, live, html} = live(conn, ~p"/settings/auth/authorization")
      assert html =~ "Authorization"
      assert html =~ "Default built-in role"
      assert html =~ "Create accounts on first SSO login"
      assert html =~ "Role profile"
      refute html =~ "Role Mappings (JSON)"

      source_count = fn markup ->
        ~r/name="settings\[mappings\]\[\d+\]\[source\]"/
        |> Regex.scan(markup)
        |> length()
      end

      assert source_count.(html) >= 1
      assert source_count.(render_click(live, "add_mapping", %{})) == source_count.(html) + 1
    end
  end

  describe "SSO auto-provision" do
    test "persists sso_auto_provision onto AuthSettings", %{conn: conn} do
      admin = AshTestHelpers.admin_user_fixture()
      actor = SystemActor.system(:authorization_live_test)

      {:ok, _settings} =
        case AuthSettings.get_settings(actor: actor) do
          {:ok, nil} -> AuthSettings.create(%{sso_auto_provision: false}, actor: actor)
          {:ok, existing} -> AuthSettings.update(existing, %{sso_auto_provision: false}, actor: actor)
          {:error, _} -> AuthSettings.create(%{sso_auto_provision: false}, actor: actor)
        end

      {:ok, live, html} =
        conn |> log_in_user(admin) |> live(~p"/settings/auth/authorization")

      assert html =~ "Create accounts on first SSO login"

      html =
        live
        |> form("#authorization-form", settings: %{sso_auto_provision: "true"})
        |> render_submit()

      assert html =~ "Authorization settings updated"
      {:ok, settings} = AuthSettings.get_settings(actor: actor)
      assert settings.sso_auto_provision == true
    end
  end

  describe "groups scope warning" do
    test "warns when a groups mapping exists but the scope is not requested", %{conn: conn} do
      settings!([%{"source" => "groups", "value" => "ops", "role" => "operator"}])
      admin = AshTestHelpers.admin_user_fixture()

      {:ok, _live, html} =
        conn |> log_in_user(admin) |> live(~p"/settings/auth/authorization")

      # With no auth settings configured, OIDCStrategy.scopes/0 falls back to
      # openid/email/profile -- no groups scope -- so Authentik-style mappings
      # cannot match. Entra is called out separately: it has no groups scope.
      assert html =~ "will never match"
      assert html =~ "Microsoft Entra"
      assert html =~ "object IDs"
    end

    test "does not warn when no mapping matches on groups", %{conn: conn} do
      settings!([%{"source" => "email_domain", "value" => "example.com", "role" => "viewer"}])
      admin = AshTestHelpers.admin_user_fixture()

      {:ok, _live, html} =
        conn |> log_in_user(admin) |> live(~p"/settings/auth/authorization")

      refute html =~ "will never match"
    end
  end
end
