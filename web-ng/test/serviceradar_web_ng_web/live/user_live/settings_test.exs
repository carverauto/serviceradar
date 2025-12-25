defmodule ServiceRadarWebNGWeb.UserLive.SettingsTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  alias ServiceRadarWebNG.Accounts
  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.AccountsFixtures

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Change Email"
      assert html =~ "Save Password"
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user email", %{conn: conn, user: user} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

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
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

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
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

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
      # User registered via magic link - no password initially
      # The settings form allows setting an initial password
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

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
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

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
end
