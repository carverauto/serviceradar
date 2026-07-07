defmodule ServiceRadarWebNGWeb.UserLive.SettingsTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

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

      assert html =~ "Change Email"
      refute html =~ "Save Password"
    end

    test "topbar exposes a Profile / API docs / Logout dropdown", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture(%{role: :operator}))
        |> live(~p"/settings/profile")

      # The topbar avatar is now a daisyUI dropdown (dropdown-end) with three
      # actions: Profile (LiveView nav), API docs (Swagger UI, new tab), Logout
      # (reusing the existing delete session route).
      assert html =~ "dropdown dropdown-end"
      assert html =~ ~s(href="/api/v2/swaggerui")
      assert html =~ ~s(target="_blank")
      assert html =~ "API docs"
      assert html =~ ~s(href="/settings/profile")
      assert html =~ ~s(href="/users/log-out")
      assert html =~ ~s(data-method="delete")
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
          "user" => %{"email" => new_email}
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

    test "renders errors with invalid data (phx-submit)", %{conn: conn, user: user} do
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
end
