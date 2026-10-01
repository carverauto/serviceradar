defmodule ServiceRadarWebNGWeb.Settings.CliAuthPolicyLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadarWebNG.AshTestHelpers

  @moduletag :web_ng_shared_fixture_db

  for initial_state <- [:missing, :existing] do
    @initial_state initial_state
    test "saves CLI policy with #{@initial_state} authorization settings", %{conn: conn} do
      actor = SystemActor.system(:cli_auth_policy_test)
      admin = AshTestHelpers.admin_user_fixture()

      # The sandbox rolls back the singleton deletion after each case.
      ServiceRadar.Repo.query!("DELETE FROM platform.authorization_settings")

      mappings = [%{"source" => "email_domain", "value" => "example.com", "role" => "viewer"}]

      if @initial_state == :existing do
        {:ok, _settings} =
          AuthorizationSettings.create_settings(
            %{
              default_role: :operator,
              role_mappings: mappings,
              cli_auth_enabled: false,
              cli_allowed_scopes: ["dashboard.publish"]
            },
            actor: actor
          )
      end

      {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/settings/cli-auth")

      view
      |> form("form[phx-submit='save']",
        settings: %{
          cli_auth_enabled: "true",
          cli_session_ttl_days: "17",
          cli_allowed_scopes: "dashboard.publish, plugins.manage\nplugins.manage"
        }
      )
      |> render_submit()

      assert has_element?(view, "#flash-info", "CLI authentication settings saved.")
      {:ok, settings} = AuthorizationSettings.get_settings(actor: actor)
      assert settings.key == "default"
      assert settings.cli_auth_enabled == true
      assert settings.cli_session_ttl_days == 17
      assert settings.cli_allowed_scopes == ["dashboard.publish", "plugins.manage"]
      assert settings.default_role == if(@initial_state == :existing, do: :operator, else: :viewer)
      assert settings.role_mappings == if(@initial_state == :existing, do: mappings, else: [])

      # A second save exercises the newly assigned persisted record too.
      view
      |> form("form[phx-submit='save']", settings: %{cli_session_ttl_days: "19"})
      |> render_submit()

      assert has_element?(view, "#flash-info", "CLI authentication settings saved.")
      {:ok, settings} = AuthorizationSettings.get_settings(actor: actor)
      assert settings.cli_session_ttl_days == 19
      assert settings.cli_allowed_scopes == ["dashboard.publish", "plugins.manage"]
    end
  end
end
