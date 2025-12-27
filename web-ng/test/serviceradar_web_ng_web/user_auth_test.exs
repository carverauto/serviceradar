defmodule ServiceRadarWebNGWeb.UserAuthTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  alias Phoenix.LiveView
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.UserAuth

  import ServiceRadarWebNG.AccountsFixtures

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, ServiceRadarWebNGWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    user = user_fixture()
    %{user: user, conn: conn}
  end

  describe "log_out_user/1" do
    test "clears session and redirects", %{conn: conn} do
      conn =
        conn
        |> put_session(:user, "some_token")
        |> put_session(:live_socket_id, "users_sessions:123")
        |> UserAuth.log_out_user()

      refute get_session(conn, :user)
      assert redirected_to(conn) == ~p"/"
    end

    test "broadcasts to the given live_socket_id", %{conn: conn} do
      live_socket_id = "users_sessions:abcdef-token"
      ServiceRadarWebNGWeb.Endpoint.subscribe(live_socket_id)

      conn
      |> put_session(:live_socket_id, live_socket_id)
      |> UserAuth.log_out_user()

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^live_socket_id}
    end

    test "works even if user is already logged out", %{conn: conn} do
      conn = conn |> UserAuth.log_out_user()
      refute get_session(conn, :user)
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "fetch_current_scope_for_user/2" do
    test "assigns nil to current_scope when no token in session", %{conn: conn} do
      conn = UserAuth.fetch_current_scope_for_user(conn, [])
      assert conn.assigns.current_scope.user == nil
    end

    test "assigns nil to current_scope with invalid token", %{conn: conn} do
      conn =
        conn
        |> put_session(:user, "invalid_token")
        |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope.user == nil
    end
  end

  describe "on_mount :mount_current_scope" do
    test "assigns nil to current_scope when no token in session", %{conn: conn} do
      session = conn |> get_session()

      socket = %LiveView.Socket{
        endpoint: ServiceRadarWebNGWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:cont, updated_socket} =
        UserAuth.on_mount(:mount_current_scope, %{}, session, socket)

      assert updated_socket.assigns.current_scope.user == nil
    end

    test "assigns nil to current_scope with invalid token", %{conn: conn} do
      session = conn |> put_session(:user, "invalid_token") |> get_session()

      socket = %LiveView.Socket{
        endpoint: ServiceRadarWebNGWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:cont, updated_socket} =
        UserAuth.on_mount(:mount_current_scope, %{}, session, socket)

      assert updated_socket.assigns.current_scope.user == nil
    end
  end

  describe "on_mount :require_authenticated" do
    test "redirects to login page if there isn't a valid token", %{conn: conn} do
      session = conn |> put_session(:user, "invalid_token") |> get_session()

      socket = %LiveView.Socket{
        endpoint: ServiceRadarWebNGWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:halt, updated_socket} = UserAuth.on_mount(:require_authenticated, %{}, session, socket)
      assert updated_socket.assigns.current_scope.user == nil
    end

    test "redirects to login page if there isn't a token", %{conn: conn} do
      session = conn |> get_session()

      socket = %LiveView.Socket{
        endpoint: ServiceRadarWebNGWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:halt, updated_socket} = UserAuth.on_mount(:require_authenticated, %{}, session, socket)
      assert updated_socket.assigns.current_scope.user == nil
    end
  end

  describe "require_authenticated_user/2" do
    setup %{conn: conn} do
      %{conn: UserAuth.fetch_current_scope_for_user(conn, [])}
    end

    test "redirects if user is not authenticated", %{conn: conn} do
      conn = conn |> fetch_flash() |> UserAuth.require_authenticated_user([])
      assert conn.halted

      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must log in to access this page."
    end

    test "stores the path to redirect to on GET", %{conn: conn} do
      halted_conn =
        %{conn | path_info: ["foo"], query_string: ""}
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert halted_conn.halted
      assert get_session(halted_conn, :user_return_to) == "/foo"

      halted_conn =
        %{conn | path_info: ["foo"], query_string: "bar=baz"}
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert halted_conn.halted
      assert get_session(halted_conn, :user_return_to) == "/foo?bar=baz"

      halted_conn =
        %{conn | path_info: ["foo"], query_string: "bar", method: "POST"}
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert halted_conn.halted
      refute get_session(halted_conn, :user_return_to)
    end

    test "does not redirect if user is authenticated", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> UserAuth.require_authenticated_user([])

      refute conn.halted
      refute conn.status
    end
  end

  describe "disconnect_sessions/1" do
    test "broadcasts disconnect messages for each user ID" do
      user_ids = ["user-id-1", "user-id-2"]

      for user_id <- user_ids do
        ServiceRadarWebNGWeb.Endpoint.subscribe("users_sessions:#{user_id}")
      end

      UserAuth.disconnect_sessions(user_ids)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "disconnect",
        topic: "users_sessions:user-id-1"
      }

      assert_receive %Phoenix.Socket.Broadcast{
        event: "disconnect",
        topic: "users_sessions:user-id-2"
      }
    end
  end
end
