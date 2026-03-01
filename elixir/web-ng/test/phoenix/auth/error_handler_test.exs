defmodule ServiceRadarWebNG.Auth.ErrorHandlerTest do
  @moduledoc """
  Tests for Guardian authentication error handler.

  Tests both JSON API and HTML browser error responses.
  Run with: mix test test/phoenix/auth/error_handler_test.exs
  """

  use ServiceRadarWebNGWeb.ConnCase, async: true

  alias ServiceRadarWebNG.Auth.ErrorHandler

  import ExUnit.CaptureLog

  describe "auth_error/3 for JSON API requests" do
    test "returns 401 with JSON for unauthenticated error", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")

      conn = ErrorHandler.auth_error(conn, {:unauthenticated, :no_token}, [])

      assert conn.status == 401
      assert conn.resp_body =~ "Authentication required"
      assert conn.resp_body =~ "unauthenticated"
    end

    test "returns 401 with JSON for invalid_token error", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")

      conn = ErrorHandler.auth_error(conn, {:invalid_token, :bad_signature}, [])

      assert conn.status == 401
      assert conn.resp_body =~ "Invalid authentication token"
    end

    test "returns 401 with JSON for token_expired error", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")

      conn = ErrorHandler.auth_error(conn, {:token_expired, :expired}, [])

      assert conn.status == 401
      assert conn.resp_body =~ "token has expired"
    end

    test "returns 401 with JSON for invalid_token_type error", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")

      conn = ErrorHandler.auth_error(conn, {:invalid_token_type, :wrong_type}, [])

      assert conn.status == 401
      assert conn.resp_body =~ "Invalid token type"
    end

    test "returns JSON for /api paths", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/api/v1/devices")

      conn = ErrorHandler.auth_error(conn, {:unauthenticated, :no_token}, [])

      assert conn.status == 401
      assert get_resp_header(conn, "content-type") |> List.first() =~ "application/json"
    end
  end

  describe "auth_error/3 for HTML browser requests" do
    test "redirects to login for unauthenticated error", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> fetch_flash()

      conn = ErrorHandler.auth_error(conn, {:unauthenticated, :no_token}, [])

      assert redirected_to(conn) == "/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "log in"
    end

    test "redirects to login and clears session for token_expired", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{some_key: "some_value"})
        |> fetch_flash()

      conn = ErrorHandler.auth_error(conn, {:token_expired, :expired}, [])

      assert redirected_to(conn) == "/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired"
    end

    test "stores return_to for GET requests", %{conn: conn} do
      conn =
        conn
        |> Map.put(:method, "GET")
        |> Map.put(:request_path, "/admin/settings")
        |> init_test_session(%{})
        |> fetch_flash()

      conn = ErrorHandler.auth_error(conn, {:unauthenticated, :no_token}, [])

      assert get_session(conn, :user_return_to) == "/admin/settings"
    end

    test "does not store return_to for POST requests", %{conn: conn} do
      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/some/path")
        |> init_test_session(%{})
        |> fetch_flash()

      conn = ErrorHandler.auth_error(conn, {:unauthenticated, :no_token}, [])

      assert get_session(conn, :user_return_to) == nil
    end
  end

  describe "logging" do
    test "logs authentication errors", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> Map.put(:request_path, "/api/test")
        |> Map.put(:method, "GET")
        |> Map.put(:remote_ip, {192, 168, 1, 1})

      log =
        capture_log(fn ->
          ErrorHandler.auth_error(conn, {:unauthenticated, :test_reason}, [])
        end)

      assert log =~ "Authentication error"
    end
  end
end
