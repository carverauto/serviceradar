defmodule ServiceRadarWebNGWeb.Plugs.SecurityHeadersTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias ServiceRadarWebNGWeb.Plugs.SecurityHeaders

  @moduletag :db_free

  setup do
    previous = Application.get_env(:serviceradar_web_ng, SecurityHeaders, [])

    on_exit(fn ->
      Application.put_env(:serviceradar_web_ng, SecurityHeaders, previous)
    end)

    Application.put_env(:serviceradar_web_ng, SecurityHeaders, [])
    :ok
  end

  describe "HSTS" do
    test "adds strict-transport-security on HTTPS responses" do
      conn = run_plug(https_conn(), [])
      conn = send_resp(conn, 200, "ok")

      assert [hsts] = get_resp_header(conn, "strict-transport-security")
      assert hsts =~ ~r/^max-age=\d+/
      assert hsts =~ "includeSubDomains"
      refute hsts =~ "preload"
    end

    test "skips HSTS on plain HTTP" do
      conn = run_plug(http_conn(), [])
      conn = send_resp(conn, 200, "ok")

      assert get_resp_header(conn, "strict-transport-security") == []
    end

    test "honors hsts_preload when explicitly enabled" do
      conn = run_plug(https_conn(), hsts_preload: true)
      conn = send_resp(conn, 200, "ok")

      assert [hsts] = get_resp_header(conn, "strict-transport-security")
      assert hsts =~ "preload"
    end
  end

  describe "Permissions-Policy" do
    test "denies camera, microphone, geolocation, payment, etc. by default" do
      conn = run_plug(http_conn(), [])
      conn = send_resp(conn, 200, "ok")

      assert [policy] = get_resp_header(conn, "permissions-policy")

      for feature <- ~w(camera microphone geolocation payment usb serial fullscreen display-capture) do
        assert policy =~ "#{feature}=()", "expected permissions-policy to deny #{feature}"
      end
    end

    test "respects an explicit override" do
      conn = run_plug(http_conn(), permissions_policy: "camera=(self)")
      conn = send_resp(conn, 200, "ok")

      assert get_resp_header(conn, "permissions-policy") == ["camera=(self)"]
    end
  end

  describe "CSP mode" do
    test "in :enforce mode the existing CSP header passes through (with report-uri appended)" do
      conn =
        http_conn()
        |> put_resp_header("content-security-policy", "default-src 'self'")
        |> run_plug(csp_mode: :enforce, csp_report_uri: "/api/security/csp-report")
        |> send_resp(200, "ok")

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'self'"
      assert csp =~ "report-uri /api/security/csp-report"
      assert get_resp_header(conn, "content-security-policy-report-only") == []
    end

    test "in :report_only mode the CSP is rewritten to the report-only header" do
      conn =
        http_conn()
        |> put_resp_header("content-security-policy", "default-src 'self'")
        |> run_plug(csp_mode: :report_only, csp_report_uri: "/api/security/csp-report")
        |> send_resp(200, "ok")

      assert get_resp_header(conn, "content-security-policy") == []
      assert [report_only] = get_resp_header(conn, "content-security-policy-report-only")
      assert report_only =~ "default-src 'self'"
      assert report_only =~ "report-uri /api/security/csp-report"
    end

    test "leaves responses without a CSP header alone" do
      conn = run_plug(http_conn(), csp_mode: :enforce)
      conn = send_resp(conn, 200, "ok")

      assert get_resp_header(conn, "content-security-policy") == []
      assert get_resp_header(conn, "content-security-policy-report-only") == []
    end

    test "runtime config overrides plug opts" do
      Application.put_env(
        :serviceradar_web_ng,
        SecurityHeaders,
        csp_mode: :report_only,
        csp_report_uri: "/runtime-uri"
      )

      conn =
        http_conn()
        |> put_resp_header("content-security-policy", "default-src 'self'")
        # Plug opt says :enforce; runtime config flips to :report_only.
        |> run_plug(csp_mode: :enforce, csp_report_uri: "/plug-opt-uri")
        |> send_resp(200, "ok")

      assert get_resp_header(conn, "content-security-policy") == []
      assert [report_only] = get_resp_header(conn, "content-security-policy-report-only")
      assert report_only =~ "report-uri /runtime-uri"
      refute report_only =~ "/plug-opt-uri"
    end
  end

  describe "websocket upgrades" do
    # WebSockAdapter.upgrade/4 (e.g. the camera relay browser stream) runs
    # before_send callbacks with the conn already handed to the transport
    # (state: :upgraded). put_resp_header/3 raises Plug.Conn.AlreadySentError
    # on such a conn, which 500'd every websocket upgrade behind this plug
    # and broke camera relay browser playback.
    test "before_send skips an upgraded conn instead of raising" do
      conn = run_plug(https_conn(), [])
      [callback | _] = conn.private[:before_send]

      upgraded = %{conn | state: :upgraded}

      assert %Plug.Conn{} = result = callback.(upgraded)
      assert result.resp_headers == upgraded.resp_headers
      assert get_resp_header(result, "permissions-policy") == []
      assert get_resp_header(result, "strict-transport-security") == []
    end

    test "before_send skips an already-sent conn" do
      conn = run_plug(http_conn(), [])
      [callback | _] = conn.private[:before_send]

      sent = %{conn | state: :sent}

      assert %Plug.Conn{} = result = callback.(sent)
      assert get_resp_header(result, "permissions-policy") == []
    end
  end

  ## Helpers

  defp run_plug(conn, opts) do
    SecurityHeaders.call(conn, SecurityHeaders.init(opts))
  end

  defp https_conn do
    %{Plug.Test.conn(:get, "/") | scheme: :https}
  end

  defp http_conn do
    %{Plug.Test.conn(:get, "/") | scheme: :http}
  end
end
