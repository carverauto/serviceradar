defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryDataTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryData

  @moduletag :db_free

  test "overlays NVD CVSS and CWE onto a KEV match that has no score" do
    match = %{
      cve_id: "CVE-2025-32463",
      cvss_score: nil,
      severity: nil,
      metadata: %{},
      advisory: %{
        raw: %{"cwes" => ["CWE-829"]}
      }
    }

    metrics = %{
      "CVE-2025-32463" => %{
        cvss_score: 7.8,
        cvss_vector: "CVSS:3.1/AV:L/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:H",
        severity: "high",
        cwes: ["CWE-829"]
      }
    }

    enriched = EndpointInventoryData.apply_nvd_metrics(match, metrics)

    assert enriched.cvss_score == 7.8
    assert enriched.severity == "high"
    assert enriched.cwes == ["CWE-829"]
    assert enriched.metadata["cvss_vector"] =~ "CVSS:3.1"
  end

  test "keeps an existing match CVSS score instead of overwriting it" do
    match = %{cve_id: "CVE-1", cvss_score: 9.8, severity: "critical", metadata: %{}}
    metrics = %{"CVE-1" => %{cvss_score: 4.0, severity: "medium", cwes: []}}

    enriched = EndpointInventoryData.apply_nvd_metrics(match, metrics)

    assert enriched.cvss_score == 9.8
    assert enriched.severity == "critical"
  end
end
