defmodule ServiceRadarWebNGWeb.DeviceLive.OcsfComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DeviceLive.OcsfComponents

  @moduletag :db_free

  test "Risk & Compliance fallback scores only active confirmed affected assessments" do
    html =
      render_component(&OcsfComponents.ocsf_info_section/1,
        device_row: %{
          "risk_score" => 0,
          "risk_level" => "Info",
          "is_active" => true,
          "is_managed" => true
        },
        vulnerability_assessments: %{
          confirmed: %{
            rows: [
              %{
                cve_id: "CVE-2099-4101",
                status: "active",
                assessment: "confirmed",
                disposition: "affected",
                cvss_score: 7.8,
                kev: true,
                exploit_available: true,
                package_name: "starling-fetch"
              }
            ]
          },
          candidates: %{rows: []},
          history: %{rows: []}
        }
      )

    assert html =~ "Risk &amp; Compliance" or html =~ "Risk & Compliance"
    assert html =~ "Risk score 90 out of 100"
    assert html =~ "Critical"
    refute html =~ ">Info<"
  end

  test "candidate KEV and malformed confirmed rows cannot enter fallback risk" do
    html =
      render_component(&OcsfComponents.ocsf_info_section/1,
        device_row: %{
          "risk_score" => 0,
          "risk_level" => "Info",
          "is_active" => true
        },
        vulnerability_assessments: %{
          confirmed: %{
            rows: [
              %{
                cve_id: "CVE-2099-4302",
                status: "active",
                assessment: "confirmed",
                disposition: "fixed",
                cvss_score: 10.0,
                kev: true,
                package_name: "quartz"
              }
            ]
          },
          candidates: %{
            rows: [
              %{
                cve_id: "CVE-2099-4201",
                status: "active",
                assessment: "candidate",
                disposition: "unknown",
                cvss_score: 10.0,
                kev: true,
                package_name: "moonbeam"
              }
            ]
          },
          history: %{rows: []}
        }
      )

    assert html =~ ">Info<"
    assert html =~ "Risk score 0 out of 10"
    refute html =~ "Risk score 100 out of 100"
  end

  test "Risk & Compliance shows one radial score and spans the full width" do
    html =
      render_component(&OcsfComponents.ocsf_info_section/1,
        device_row: %{
          "risk_score" => 6,
          "risk_level" => "low",
          "is_active" => true,
          "is_managed" => true,
          "is_trusted" => true
        }
      )

    assert html =~ ~s(data-role="risk-compliance-card")
    assert html =~ ~s(data-role="risk-score-radial")
    assert html =~ "radial-progress"
    assert html =~ "6"
    assert html =~ "/10"
    refute html =~ "Risk Score"
    assert html =~ ~s(data-role="risk-level-badge")
    assert html =~ "Low"
    assert html =~ "bg-emerald-500/10"
  end
end
