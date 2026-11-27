defmodule Palisade.Plug.SecurityHeadersTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Palisade.Plug.SecurityHeaders

  defp run(conn, opts), do: SecurityHeaders.call(conn, SecurityHeaders.init(opts))
  defp http, do: conn(:get, "http://example.com/")
  defp https, do: conn(:get, "https://example.com/")

  defp directives(conn, header) do
    [value] = get_resp_header(conn, header)

    value
    |> String.split(";", trim: true)
    |> Map.new(fn directive ->
      [name | sources] = String.split(directive)
      {name, sources}
    end)
  end

  describe "default policy" do
    test "allows only same-origin resources and denies framing" do
      csp = directives(run(http(), []), "content-security-policy")

      assert csp["default-src"] == ["'none'"]

      for directive <- ~w(script-src style-src img-src font-src connect-src) do
        assert csp[directive] == ["'self'"], "expected #{directive} 'self'"
      end

      assert csp["frame-ancestors"] == ["'none'"]
    end

    test "sets the static headers" do
      conn = run(http(), [])

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
      assert get_resp_header(conn, "referrer-policy") == ["strict-origin-when-cross-origin"]
      assert [policy] = get_resp_header(conn, "permissions-policy")
      assert policy =~ "camera=()"
      assert policy =~ "microphone=()"
    end
  end

  describe "content security policy" do
    test "is built from a keyword list, with valueless directives" do
      conn =
        run(http(),
          content_security_policy: [
            default_src: ["'self'"],
            img_src: ["'self'", "data:"],
            upgrade_insecure_requests: true
          ]
        )

      assert get_resp_header(conn, "content-security-policy") ==
               ["default-src 'self'; img-src 'self' data:; upgrade-insecure-requests"]
    end

    test "report-only mode uses the report-only header name and drops the enforcing one" do
      conn =
        http()
        |> put_resp_header("content-security-policy", "default-src *")
        |> run(csp_mode: :report_only, csp_report_uri: "/csp-report")

      assert get_resp_header(conn, "content-security-policy") == []
      assert [policy] = get_resp_header(conn, "content-security-policy-report-only")
      assert policy =~ "default-src 'none'"
      assert policy =~ "; report-uri /csp-report"
    end

    test "enforce mode drops a report-only header set earlier" do
      conn =
        http()
        |> put_resp_header("content-security-policy-report-only", "default-src *")
        |> run([])

      assert get_resp_header(conn, "content-security-policy-report-only") == []
      assert [_policy] = get_resp_header(conn, "content-security-policy")
    end

    test "can be turned off" do
      conn = run(http(), content_security_policy: false)

      assert get_resp_header(conn, "content-security-policy") == []
      assert get_resp_header(conn, "content-security-policy-report-only") == []
    end

    test "rejects sources that would inject directives" do
      for bad <- ["'self'; script-src *", "a,b", "", "two words"] do
        assert_raise ArgumentError, fn ->
          SecurityHeaders.init(content_security_policy: [script_src: [bad]])
        end
      end

      assert_raise ArgumentError, fn ->
        SecurityHeaders.init(csp_report_uri: "/r; script-src *")
      end

      assert_raise ArgumentError, fn -> SecurityHeaders.init(csp_mode: :sometimes) end
    end
  end

  describe "HSTS" do
    test "is sent on HTTPS and not on HTTP by default" do
      assert get_resp_header(run(https(), []), "strict-transport-security") ==
               ["max-age=63072000; includeSubDomains"]

      assert get_resp_header(run(http(), []), "strict-transport-security") == []
    end

    test "can be forced on HTTP for TLS terminated upstream" do
      conn = run(http(), hsts: :always, hsts_preload: true, hsts_include_subdomains: false)
      assert get_resp_header(conn, "strict-transport-security") == ["max-age=63072000; preload"]
    end

    test "can be turned off" do
      assert get_resp_header(run(https(), hsts: false), "strict-transport-security") == []
    end
  end

  test "static headers can be turned off or replaced" do
    conn = run(http(), frame_options: false, referrer_policy: "no-referrer")

    assert get_resp_header(conn, "x-frame-options") == []
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
  end

  test "header values with control characters are rejected at init" do
    assert_raise ArgumentError, fn ->
      SecurityHeaders.init(referrer_policy: "a\r\nset-cookie: x")
    end
  end
end
