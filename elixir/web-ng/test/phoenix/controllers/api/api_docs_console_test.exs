defmodule ServiceRadarWebNGWeb.Api.ApiDocsConsoleTest do
  @moduledoc """
  Covers the gated `/api/v2` documentation surface and the RBAC-backed SwaggerUI
  API console.

  Posture under test:
    * The OpenAPI spec (`/api/v2/open_api`) requires authentication.
    * The spec drops the *global* bearer-auth requirement so the console defaults
      to seamless session authentication (no manual "paste JWT" step); the bearer
      scheme is retained as an optional fallback.
    * The SwaggerUI console sends same-origin credentials (the session cookie)
      plus the CSRF token, so "Try it out" runs AS THE LOGGED-IN USER and each
      call is authorized by the resource's Ash policies (RBAC).
  """
  use ServiceRadarWebNGWeb.ConnCase, async: true
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadarWebNG.AshTestHelpers

  @service_check_params %{
    "data" => %{
      "type" => "service-check",
      "attributes" => %{
        "name" => "console-rbac-check",
        "check_type" => "http",
        "target" => "https://example.com/health",
        "interval_seconds" => 120,
        "timeout_seconds" => 30
      }
    }
  }

  describe "OpenAPI spec (/api/v2/open_api)" do
    test "requires authentication", %{conn: conn} do
      conn = get(conn, ~p"/api/v2/open_api")
      assert conn.status == 401
    end

    test "authenticated user gets a spec with no forced bearer requirement", %{conn: conn} do
      conn =
        conn
        |> log_in_user(AshTestHelpers.viewer_user_fixture())
        |> get(~p"/api/v2/open_api")

      body = json_response(conn, 200)

      assert body["openapi"] =~ "3.0"
      assert get_in(body, ["info", "title"]) == "ServiceRadar API"

      # The global bearer-auth *requirement* is removed, so SwaggerUI does not
      # force a manual "Authorize / paste JWT" step.
      assert body["security"] in [nil, []]

      # The bearer *scheme* is retained as an optional fallback for non-browser
      # clients.
      assert get_in(body, ["components", "securitySchemes", "bearerAuth", "scheme"]) == "bearer"
    end
  end

  describe "SwaggerUI console authenticates via the user's session" do
    test "the rendered console sends same-origin credentials and the CSRF token", %{conn: conn} do
      conn =
        conn
        |> log_in_user(AshTestHelpers.viewer_user_fixture())
        |> get(~p"/api/v2/swaggerui")

      body = html_response(conn, 200)

      # `with_credentials: true` -> SwaggerUI includes credentials (session cookie).
      assert body =~ "withCredentials"
      # Built-in request interceptor attaches the CSRF token for same-origin calls.
      assert body =~ "x-csrf-token"
      # Console targets the gated spec.
      assert body =~ "/api/v2/open_api"
    end
  end

  describe "RBAC is enforced for console (session-authenticated) calls" do
    test "a viewer's session-authenticated read is allowed and returns data", %{conn: conn} do
      _device = device_fixture(%{hostname: "console-visible-host"})

      conn =
        conn
        |> log_in_user(AshTestHelpers.viewer_user_fixture())
        |> get(~p"/api/v2/devices")

      response = json_response(conn, 200)
      assert is_list(response["data"])
      # `devices.view` is granted to viewers, so the session-authenticated read
      # returns the device — proving the console's session auth resolves the
      # actor and the read policy allows it.
      refute Enum.empty?(response["data"])
    end

    test "a viewer's session-authenticated create is DENIED by policy", %{conn: conn} do
      conn =
        conn
        |> log_in_user(AshTestHelpers.viewer_user_fixture())
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post(~p"/api/v2/service-checks", @service_check_params)

      # A viewer lacks `services.create`, so the Ash policy forbids the write —
      # proving RBAC is enforced through the session-authenticated console path.
      assert conn.status == 403
    end

    test "an admin's session-authenticated create is permitted by policy (not 403)", %{conn: conn} do
      conn =
        conn
        |> log_in_user(AshTestHelpers.admin_user_fixture())
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post(~p"/api/v2/service-checks", @service_check_params)

      # An admin holds `services.create`; the policy allows the action (201, or a
      # validation error) — but never a 403 authorization failure.
      refute conn.status == 403
    end
  end

  # Belt-and-suspenders RBAC evidence via bearer auth (the API policies are
  # actor-based, so they enforce identically whether the console authenticates
  # by session cookie or by bearer token).
  describe "RBAC is enforced for bearer-authenticated calls" do
    test "a viewer's create is denied while an admin's is permitted", %{conn: conn} do
      viewer_conn =
        conn
        |> log_in_api_user(AshTestHelpers.viewer_user_fixture())
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post(~p"/api/v2/service-checks", @service_check_params)

      assert viewer_conn.status == 403

      admin_conn =
        Phoenix.ConnTest.build_conn()
        |> log_in_api_user(AshTestHelpers.admin_user_fixture())
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post(~p"/api/v2/service-checks", @service_check_params)

      refute admin_conn.status == 403
    end
  end
end
