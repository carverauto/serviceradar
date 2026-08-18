defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryFindingsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryFindings

  @moduletag :db_free

  test "collapses an NVD CPE match and a KEV name match for the same CVE" do
    package_ref = Ecto.UUID.generate()

    findings =
      EndpointInventoryFindings.group([
        %{
          id: "nvd",
          endpoint_package_ref: package_ref,
          cve_id: "CVE-2024-0001",
          advisory_id: "CVE-2024-0001",
          provider: "nvd",
          feed_key: "nist-nvd2",
          coordinate_type: "cpe",
          coordinate_value: "cpe:2.3:a:openssl:openssl:*:*:*:*:*:*:*:*",
          confidence: "medium",
          status: "active",
          severity: "high",
          cvss_score: 7.5,
          fixed_version: "3.0.14",
          kev: false,
          exploit_available: false,
          description: "OpenSSL buffer overflow",
          evidence: %{"package" => %{"name" => "openssl", "version" => "3.0.13"}},
          metadata: %{}
        },
        %{
          id: "kev",
          endpoint_package_ref: package_ref,
          cve_id: "CVE-2024-0001",
          advisory_id: "CVE-2024-0001",
          provider: "cisa",
          feed_key: "cisa-kev",
          coordinate_type: "vendor_product",
          coordinate_value: "openssl",
          confidence: "low",
          status: "active",
          kev: true,
          exploit_available: true,
          evidence: %{"package" => %{"name" => "openssl", "version" => "3.0.13"}},
          metadata: %{
            "match_kind" => "name",
            "priority" => %{"due_date" => "2024-02-01", "epss_score" => 0.88}
          }
        }
      ])

    assert [
             %{
               cve_id: "CVE-2024-0001",
               kev: true,
               exploit_available: true,
               cvss_score: 7.5,
               fixed_version: "3.0.14",
               due_date: "2024-02-01",
               epss_score: 0.88,
               description: "OpenSSL buffer overflow",
               coordinate_type: "cpe",
               name_match_only?: false
             }
           ] = findings
  end

  test "keeps a KEV-only name match marked as lower confidence" do
    [finding] =
      EndpointInventoryFindings.group([
        %{
          id: "kev-only",
          endpoint_package_ref: Ecto.UUID.generate(),
          cve_id: "CVE-2024-0003",
          advisory_id: "CVE-2024-0003",
          provider: "cisa",
          feed_key: "cisa-kev",
          coordinate_type: "vendor_product",
          coordinate_value: "struts",
          confidence: "low",
          kev: true,
          exploit_available: true,
          evidence: %{"package" => %{"name" => "struts"}},
          metadata: %{"match_kind" => "name"}
        }
      ])

    assert finding.name_match_only?
    assert finding.confidence == "low"
    assert finding.kev
  end
end
