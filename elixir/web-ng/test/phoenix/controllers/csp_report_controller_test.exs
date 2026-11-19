defmodule ServiceRadarWebNGWeb.CspReportControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Security.Events
  alias ServiceRadar.Security.SecurityEvent

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db

  # The shape and media type a browser sends for a `report-uri` violation
  # (CSP Level 2, "Sample violation report").
  test "a browser violation report is stored with its directive and blocked resource", %{conn: conn} do
    document = "https://app.example.com/reports/#{System.unique_integer([:positive])}"

    body =
      Jason.encode!(%{
        "csp-report" => %{
          "document-uri" => document,
          "violated-directive" => "script-src 'self'",
          "blocked-uri" => "https://cdn.example.net/widget.js"
        }
      })

    conn =
      conn
      |> put_req_header("content-type", "application/csp-report")
      |> post("/api/security/csp-report", body)

    assert conn.status == 204
    Events.flush()

    reports =
      SecurityEvent
      |> Ash.Query.filter(kind == :csp_violation)
      |> Ash.read!(actor: SystemActor.system(:csp_report_test), authorize?: false)
      |> Enum.map(& &1.details["report"])
      |> Enum.filter(&(is_map(&1) and &1["document-uri"] == document))

    assert [%{"violated-directive" => "script-src 'self'", "blocked-uri" => "https://cdn.example.net/widget.js"}] =
             reports
  end
end
