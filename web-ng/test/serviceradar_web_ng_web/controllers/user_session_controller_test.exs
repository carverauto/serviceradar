defmodule ServiceRadarWebNGWeb.UserSessionControllerTest do
  @moduledoc """
  Tests for UserSessionController.

  Note: Login and registration are handled by AshAuthentication.Phoenix via AuthController.
  This controller only handles logout.
  """
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import ServiceRadarWebNG.AccountsFixtures

  setup do
    %{user: user_fixture()}
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
