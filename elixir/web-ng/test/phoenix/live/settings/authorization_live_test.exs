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
  alias ServiceRadarWebNG.AshTestHelpers

  defp settings!(mappings) do
    actor = SystemActor.system(:authorization_live_test)

    case AuthorizationSettings.get_settings(actor: actor) do
      {:ok, nil} ->
        {:ok, settings} =
          AuthorizationSettings.create_settings(
            %{default_role: :viewer, role_mappings: mappings},
            actor: actor
          )

        settings

      {:ok, existing} ->
        {:ok, settings} =
          AuthorizationSettings.update_settings(existing, %{role_mappings: mappings}, actor: actor)

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
