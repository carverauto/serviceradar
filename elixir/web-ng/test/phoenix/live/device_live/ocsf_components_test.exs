defmodule ServiceRadarWebNGWeb.DeviceLive.OcsfComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DeviceLive.OcsfComponents

  @moduletag :db_free

  test "Risk & Compliance uses KEV and CVSS from vulnerability matches when stored score is zero" do
    html =
      render_component(&OcsfComponents.ocsf_info_section/1,
        device_row: %{
          "risk_score" => 0,
          "risk_level" => "Info",
          "is_active" => true,
          "is_managed" => true
        },
        vulnerability_matches: [
          %{
            cve_id: "CVE-2025-32463",
            cvss_score: 7.8,
            kev: true,
            exploit_available: true,
            cwes: ["CWE-829"],
            evidence: %{"package" => %{"name" => "sudo"}}
          }
        ]
      )

    assert html =~ "Risk &amp; Compliance" or html =~ "Risk & Compliance"
    assert html =~ "83"
    assert html =~ "High"
    refute html =~ ">Info<"
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
