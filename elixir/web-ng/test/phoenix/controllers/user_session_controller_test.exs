defmodule ServiceRadarWebNGWeb.UserSessionControllerTest do
  @moduledoc """
  Tests for UserSessionController.

  Note: Login is handled by AshAuthentication.Phoenix via AuthController.
  This controller handles logout.
  """
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import ServiceRadarWebNG.AccountsFixtures

  alias ServiceRadarWebNG.Accounts

  setup do
    %{user: user_fixture()}
  end

  describe "POST /users/update-password" do
    test "denies viewers without password permission", %{conn: conn} do
      user = set_password(user_fixture(%{role: :viewer}))

      conn =
        conn
        |> log_in_user(user)
        |> init_test_session(%{"sudo_authenticated_at" => DateTime.to_unix(DateTime.utc_now())})
        |> post(~p"/users/update-password", %{
          "user" => %{
            "current_password" => valid_user_password(),
            "password" => "new valid password",
            "password_confirmation" => "new valid password"
          }
        })

      assert redirected_to(conn) == ~p"/settings/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not allowed to change the password"
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, "user_token")
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, "user_token")
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
