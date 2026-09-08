defmodule ServiceRadar.Inventory.AdvisoryFeeds.CvePriorityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.CvePriority
  alias ServiceRadar.Inventory.AdvisoryFeeds.Parsers.Kev

  describe "from_entry/1" do
    test "extracts CISA due date, ransomware use, and title from raw" do
      entry = %{
        "cveID" => "CVE-2024-0001",
        "vendorProject" => "Apache",
        "product" => "Log4j2",
        "vulnerabilityName" => "Log4Shell",
        "shortDescription" => "JNDI lookup RCE",
        "dueDate" => "2021-12-24",
        "knownRansomwareCampaignUse" => "Known"
      }

      priority = CvePriority.from_entry(entry)

      assert priority.cve_id == "CVE-2024-0001"
      assert priority.kev
      assert priority.exploit_available
      assert priority.due_date == "2021-12-24"
      assert priority.ransomware_use == "Known"
      assert priority.title == "Log4Shell"
      assert priority.description == "JNDI lookup RCE"
      assert is_nil(priority.epss_score)
    end

    test "extracts EPSS when the VulnCheck payload already has it" do
      entry = %{
        "cve" => ["CVE-2017-5638"],
        "vulnerabilityName" => "Apache Struts RCE",
        "epss" => %{"epss_score" => 0.973}
      }

      assert CvePriority.from_entry(entry).epss_score == 0.973
    end
  end

  describe "union/2" do
    test "keeps kev true and prefers the CISA due date" do
      cisa = %CvePriority{
        cve_id: "CVE-2024-0001",
        provider: "cisa",
        feed_key: "cisa-kev",
        kev: true,
        due_date: "2024-02-01",
        sources: ["cisa-kev"]
      }

      vulncheck = %CvePriority{
        cve_id: "CVE-2024-0001",
        provider: "vulncheck",
        feed_key: "vulncheck-kev",
        kev: true,
        due_date: "2024-03-15",
        epss_score: 0.42,
        sources: ["vulncheck-kev"]
      }

      unioned = CvePriority.union(cisa, vulncheck)

      assert unioned.kev
      assert unioned.due_date == "2024-02-01"
      assert unioned.epss_score == 0.42
      assert Enum.sort(unioned.sources) == ["cisa-kev", "vulncheck-kev"]
    end

    test "still prefers CISA when VulnCheck is the left-hand side" do
      unioned =
        CvePriority.union(
          %CvePriority{
            feed_key: "vulncheck-kev",
            due_date: "2024-03-15",
            sources: ["vulncheck-kev"]
          },
          %CvePriority{feed_key: "cisa-kev", due_date: "2024-02-01", sources: ["cisa-kev"]}
        )

      assert unioned.due_date == "2024-02-01"
    end
  end

  describe "apply/2" do
    test "stamps KEV flags onto an nist-nvd2 advisory" do
      advisory = %{
        cve_id: "CVE-2024-0001",
        feed_key: "nist-nvd2",
        kev: false,
        exploit_available: false,
        cvss_score: 5.0
      }

      priority = %CvePriority{
        cve_id: "CVE-2024-0001",
        kev: true,
        exploit_available: true,
        due_date: "2024-02-01"
      }

      assert {overlaid, ^priority} = CvePriority.apply(advisory, priority)
      assert overlaid.kev
      assert overlaid.exploit_available
      assert overlaid.cvss_score == 5.0
    end

    test "leaves a non-KEV NVD advisory unmarked" do
      advisory = %{cve_id: "CVE-2024-0002", kev: false, exploit_available: false}

      assert {^advisory, nil} = CvePriority.apply(advisory, nil)
    end
  end

  describe "Kev.operator_fields/1" do
    test "normalizes a date-only dueDate and nested EPSS" do
      fields =
        Kev.operator_fields(%{
          "cveID" => "CVE-2024-0001",
          "dueDate" => "2024-06-01T00:00:00.000Z",
          "knownRansomwareCampaignUse" => "Unknown",
          "epss_score" => "0.11"
        })

      assert fields.due_date == "2024-06-01"
      assert fields.ransomware_use == "Unknown"
      assert fields.epss_score == 0.11
    end
  end
end
