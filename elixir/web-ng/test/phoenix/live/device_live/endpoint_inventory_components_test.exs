defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryComponents

  @moduletag :db_free

  test "renders match modal with advisory text, KEV action, and outbound links" do
    match = %{
      id: "match-1",
      cve_id: "CVE-2025-32463",
      advisory_id: "CVE-2025-32463",
      kev: true,
      exploit_available: true,
      confidence: "low",
      status: "active",
      cvss_score: 7.8,
      cwes: ["CWE-829"],
      coordinate_type: "vendor_product",
      coordinate_value: "sudo",
      provider: "cisa",
      feed_key: "cisa-kev",
      severity: "unknown",
      evidence: %{
        "package" => %{
          "name" => "sudo",
          "version" => "1.9.15p5",
          "package_manager" => "dpkg"
        }
      },
      version_evidence: %{"installed_version" => "1.9.15p5"},
      advisory: %{
        title: "Sudo chroot Privilege Escalation",
        description: "Sudo contains a flaw that allows local privilege escalation.",
        references: ["https://www.sudo.ws/security/advisories/sudo-cve-2025-32463/"],
        published_at: ~U[2025-07-01 00:00:00Z],
        raw: %{
          "requiredAction" => "Apply mitigations per vendor instructions",
          "dueDate" => "2025-07-21",
          "knownRansomwareCampaignUse" => "Unknown",
          "vendorProject" => "Sudo Project",
          "product" => "Sudo"
        }
      }
    }

    html =
      render_component(&EndpointInventoryComponents.endpoint_inventory_match_modal/1,
        show: true,
        match: match
      )

    assert html =~ "CVE-2025-32463"
    assert html =~ "Sudo chroot Privilege Escalation"
    assert html =~ "Sudo contains a flaw"
    assert html =~ "CISA required action"
    assert html =~ "Apply mitigations per vendor instructions"
    assert html =~ "Due 2025-07-21"
    assert html =~ "Low-confidence name match"
    assert html =~ "https://nvd.nist.gov/vuln/detail/CVE-2025-32463"
    assert html =~ "https://www.cve.org/CVERecord?id=CVE-2025-32463"
    assert html =~ "https://www.cisa.gov/known-exploited-vulnerabilities-catalog"
    assert html =~ "https://www.sudo.ws/security/advisories/sudo-cve-2025-32463/"
    assert html =~ "NVD · CVE-2025-32463"
    assert html =~ "CVSS 7.8"
    assert html =~ "CWE-829"
    assert html =~ "2025-07-01"
    assert html =~ "endpoint_inventory_close_match"
  end

  test "hides the match modal when it is not shown" do
    html =
      render_component(&EndpointInventoryComponents.endpoint_inventory_match_modal/1,
        show: false,
        match: %{id: "match-1", cve_id: "CVE-2025-32463"}
      )

    refute html =~ "CVE-2025-32463"
    refute html =~ "endpoint-match-modal"
  end

  test "renders one card per unique CVE when a package group has several advisories" do
    group = %{
      id: "ref:pkg-sudo",
      package_name: "sudo",
      installed_version: "dpkg 1.9.15p5",
      kev: true,
      exploit_available: true,
      severity: "unknown",
      cvss_score: nil,
      confidence: "low",
      advisory_count: 2,
      cve_ids: ["CVE-2025-32463", "CVE-2021-3156"],
      sources: [
        %{provider: "cisa", feed_key: "cisa-kev"},
        %{provider: "vulncheck", feed_key: "vulncheck-kev"}
      ],
      fixed_versions: [],
      cwes: ["CWE-829"],
      matches: [],
      advisories: [
        %{
          id: "cve-2025-32463",
          cve_id: "CVE-2025-32463",
          primary: %{
            cve_id: "CVE-2025-32463",
            kev: true,
            provider: "cisa",
            feed_key: "cisa-kev",
            evidence: %{"package" => %{"name" => "sudo"}}
          },
          feeds: [
            %{provider: "cisa", feed_key: "cisa-kev"},
            %{provider: "vulncheck", feed_key: "vulncheck-kev"}
          ],
          matches: []
        },
        %{
          id: "cve-2021-3156",
          cve_id: "CVE-2021-3156",
          primary: %{
            cve_id: "CVE-2021-3156",
            kev: true,
            provider: "cisa",
            feed_key: "cisa-kev",
            evidence: %{"package" => %{"name" => "sudo"}}
          },
          feeds: [%{provider: "cisa", feed_key: "cisa-kev"}],
          matches: []
        }
      ]
    }

    html =
      render_component(&EndpointInventoryComponents.endpoint_inventory_match_modal/1,
        show: true,
        group: group
      )

    assert html =~ "sudo"
    assert html =~ "2 advisories"
    assert html =~ "CVE-2025-32463"
    assert html =~ "CVE-2021-3156"
    assert html =~ "cisa / cisa-kev"
    assert html =~ "vulncheck / vulncheck-kev"
  end
end
