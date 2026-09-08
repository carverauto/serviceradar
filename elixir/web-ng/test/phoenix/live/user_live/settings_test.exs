defmodule ServiceRadarWebNGWeb.UserLive.SettingsTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.AccountsFixtures

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.Accounts

  describe "Settings page" do
    test "renders password controls for users with a local password", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture(%{role: :operator}))
        |> live(~p"/settings/profile")

      assert html =~ "Change Email"
      assert html =~ "Save Password"
    end

    test "lets viewers with a local password change their own password", %{conn: conn} do
      # settings.password.manage is granted to all roles; the change_password
      # policy scopes the action to the signed-in user (self-service), so a
      # viewer can rotate their own local password.
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture(%{role: :viewer}))
        |> live(~p"/settings/profile")

      assert html =~ "Change Email"
      assert html =~ "Save Password"
    end

    test "hides password controls for SSO-only users without a local password", %{conn: conn} do
      actor = SystemActor.system(:test)

      {:ok, sso_user} =
        User.provision_sso_user(
          %{
            email: unique_user_email(),
            display_name: "SSO User",
            external_id: "oidc|#{System.unique_integer([:positive])}",
            provider: :oidc
          },
          actor: actor
        )

      {:ok, _lv, html} =
        conn
        |> log_in_user(sso_user)
        |> live(~p"/settings/profile")

      refute html =~ "Change Email"
      refute html =~ "Save Password"
      assert html =~ "managed by your identity provider"
    end

    test "SSO-linked accounts with a local password still cannot change email or password", %{
      conn: conn
    } do
      actor = SystemActor.system(:test)

      {:ok, sso_user} =
        User.provision_sso_user(
          %{
            email: unique_user_email(),
            display_name: "SSO Hybrid",
            external_id: "oidc|#{System.unique_integer([:positive])}",
            provider: :oidc
          },
          actor: actor
        )

      {:ok, sso_user} =
        User.admin_set_password(sso_user, %{password: valid_user_password()}, actor: actor)

      {:ok, _lv, html} =
        conn
        |> log_in_user(sso_user)
        |> live(~p"/settings/profile")

      refute html =~ "Change Email"
      refute html =~ "Save Password"
      refute html =~ ~s(id="email_form")
      refute html =~ ~s(id="password_form")
      assert html =~ "managed by your identity provider"
    end

    test "topbar exposes a Profile / API docs / Logout menu", %{conn: conn} do
      {:ok, lv, _html} =
        conn
        |> log_in_user(user_fixture(%{role: :operator}))
        |> live(~p"/settings/profile")

      # The canonical details-based profile menu keeps the three actions: Profile
      # (LiveView nav), API docs (Swagger UI, new tab), and the delete logout route.
      assert has_element?(lv, "#ops-profile-menu")
      assert has_element?(lv, "#ops-profile-menu-toggle")
      assert has_element?(lv, "#ops-profile-menu a[href='/api/v2/swaggerui'][target='_blank']")
      assert has_element?(lv, "#ops-profile-menu a[href='/settings/profile']")
      assert has_element?(lv, "#ops-profile-menu a[href='/users/log-out'][data-method='delete']")
    end

    test "the users status strip links the API-keys card to API Credentials", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture(%{role: :operator}))
        |> live(~p"/settings/profile")

      assert html =~ "API keys"
      assert html =~ ~s(href="/settings/api-credentials")
      # The user-population cards link to Users management.
      assert html =~ ~s(href="/settings/auth/users")
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/settings/profile")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: conn |> log_in_user(user) |> put_sudo_mode(), user: user}
    end

    test "updates the user email", %{conn: conn, user: user} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/settings/profile")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{
            "email" => new_email,
            "current_password" => valid_user_password()
          }
        })
        |> render_submit()

      # AshPhoenix.Form.submit updates immediately, so check for success message
      assert result =~ "Email updated successfully"
      # Original user email should no longer exist after update
      refute Accounts.get_user_by_email(user.email)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/profile")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      assert result =~ "Change Email"
      # Ash produces format validation error
      assert result =~ "must match the pattern"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, user: _user} do
      {:ok, lv, _html} = live(conn, ~p"/settings/profile")

      # Ash doesn't have "did not change" validation - it just succeeds
      # So test a truly invalid email format instead
      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => "invalid-email"}
        })
        |> render_submit()

      assert result =~ "Change Email"
      assert result =~ "must match the pattern"
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      user = user_fixture(%{role: :operator})
      %{conn: conn |> log_in_user(user) |> put_sudo_mode(), user: user}
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/profile")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save Password"
      # Ash produces different error message format
      assert result =~ "length must be greater than or equal to 12"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/profile")

      result =
        lv
        |> form("#password_form", %{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Save Password"
      # Ash produces different error message format
      assert result =~ "length must be greater than or equal to 12"
      assert result =~ "does not match password"
    end
  end

  describe "timezone preference form" do
    setup %{conn: conn} do
      user = user_fixture(%{role: :viewer})
      %{conn: log_in_user(conn, user), user: user}
    end

    @tag :web_ng_shared_fixture_db
    test "renders the searchable timezone form in the current responsive settings shell", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/settings/profile")

      assert has_element?(lv, "#settings-view-tree")
      assert has_element?(lv, "#settings-nav-drawer")
      assert has_element?(lv, ".sr-settings-shell section #timezone_form")
      refute has_element?(lv, "#timezone_form[phx-change]")
      refute has_element?(lv, "#user_timezone[list]")
      refute has_element?(lv, "datalist#timezone_catalog")
      assert has_element?(lv, "#user_timezone[phx-hook='TimezoneSelect'][role='combobox']")
      assert has_element?(lv, "#timezone_catalog[role='listbox']")
      assert has_element?(lv, "#timezone_catalog [data-timezone='Etc/UTC']")
      assert has_element?(lv, "#timezone_catalog [data-timezone='America/Chicago']")
      assert has_element?(lv, "#user_timezone[data-current-timezone='#{user.timezone}']")
      assert has_element?(lv, "#timezone-preview[data-user-time-zone='#{user.timezone}']")
    end

    @tag :web_ng_shared_fixture_db
    test "rejects an invalid timezone without changing the saved preference", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/settings/profile")

      result =
        lv
        |> form("#timezone_form", %{"timezone_preference" => %{"timezone" => "Etc/GMT+5"}})
        |> render_submit()

      assert has_element?(lv, "#timezone_form #user_timezone")
      assert result =~ "is not a supported timezone"
      assert fresh_user(user.id).timezone == "Etc/UTC"
    end

    @tag :web_ng_shared_fixture_db
    test "persists a valid timezone and refreshes only the scoped user", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/settings/profile")
      prior_scope = :sys.get_state(lv.pid).socket.assigns.current_scope
      prior_preview = preview_instant(render(lv))

      result =
        lv
        |> form("#timezone_form", %{"timezone_preference" => %{"timezone" => "America/Chicago"}})
        |> render_submit()

      assert result =~ "Timezone updated successfully."
      assert fresh_user(user.id).timezone == "America/Chicago"

      updated_scope = :sys.get_state(lv.pid).socket.assigns.current_scope
      assert updated_scope.user.timezone == "America/Chicago"
      assert updated_scope.permissions == prior_scope.permissions
      assert updated_scope.identity_claims == prior_scope.identity_claims
      assert preview_instant(result) == prior_preview
      assert has_element?(lv, "#timezone-preview[data-user-time-zone='America/Chicago']")
    end

    @tag :web_ng_shared_fixture_db
    test "uses the persisted timezone on a fresh authenticated connection", %{conn: conn, user: user} do
      assert {:ok, updated} =
               User.update_timezone_preference(user, %{timezone: "America/Chicago"}, scope: scope_for(user))

      {:ok, lv, _html} = live(conn, ~p"/settings/profile")

      assert has_element?(lv, "#user_timezone[data-current-timezone='#{updated.timezone}']")
    end

    @tag :web_ng_shared_fixture_db
    test "renders a persisted legacy timezone without allowing it to be saved again", %{conn: conn, user: user} do
      legacy_timezone = "Legacy/Removed"

      ServiceRadar.Repo.query!(
        "UPDATE platform.ng_users SET timezone = $1 WHERE id = $2",
        [legacy_timezone, Ecto.UUID.dump!(user.id)]
      )

      assert fresh_user(user.id).timezone == legacy_timezone

      {:ok, lv, _html} = live(conn, ~p"/settings/profile")

      assert has_element?(lv, "#user_timezone[data-current-timezone='#{legacy_timezone}']")
      assert has_element?(lv, "#timezone_catalog [data-timezone='#{legacy_timezone}']")

      result =
        lv
        |> form("#timezone_form", %{"timezone_preference" => %{"timezone" => legacy_timezone}})
        |> render_submit()

      assert result =~ "is not a supported timezone"
      assert fresh_user(user.id).timezone == legacy_timezone
    end
  end

  # Real logins stamp sudo mode in the session (20-minute window). The view no
  # longer requires sudo, but the sensitive email/password submits still do, so
  # tests that submit must simulate the freshly-authenticated session.
  defp put_sudo_mode(conn) do
    Plug.Conn.put_session(
      conn,
      "sudo_authenticated_at",
      DateTime.to_unix(DateTime.utc_now())
    )
  end

  defp fresh_user(id) do
    assert {:ok, user} = User.get_by_id(id, actor: SystemActor.system(:test))
    user
  end

  defp scope_for(user), do: ServiceRadarWebNG.Accounts.Scope.for_user(user)

  defp preview_instant(html) do
    [_, datetime] = Regex.run(~r/id="timezone-preview"[^>]*datetime="([^"]+)"/, html)
    datetime
  end
end
