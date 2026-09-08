defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryMatchGroupsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryMatchGroups

  @moduletag :db_free

  test "groups assessments by package without ranking a raw provider as authority" do
    assessments = [
      assessment("assessment-starling-a", "pkg-starling", "starling-fetch", "CVE-2099-4101"),
      assessment("assessment-starling-b", "pkg-starling", "starling-fetch", "CVE-2099-4102"),
      assessment("assessment-moonbeam", "pkg-moonbeam", "moonbeam", "CVE-2099-4201")
    ]

    raw_matches = [
      raw_match("raw-starling-cisa", "pkg-starling", "CVE-2099-4101", "cisa", "cisa-kev"),
      raw_match("raw-starling-nvd", "pkg-starling", "CVE-2099-4101", "nvd", "nist-nvd2")
    ]

    groups = EndpointInventoryMatchGroups.group(assessments, raw_matches)

    assert groups |> Enum.map(& &1.package_name) |> Enum.sort() == ["moonbeam", "starling-fetch"]

    starling = Enum.find(groups, &(&1.package_name == "starling-fetch"))
    assert starling.advisory_count == 2
    assert starling.cve_ids == ["CVE-2099-4102", "CVE-2099-4101"]
    assert Enum.map(starling.sources, & &1.provider) == ["ubuntu", "cisa", "nvd"]

    first = Enum.find(starling.advisories, &(&1.cve_id == "CVE-2099-4101"))
    assert first.primary.authority == "ubuntu:USN-2099-4101-1"
    assert first.primary.provider == "ubuntu"
    assert Enum.map(first.feeds, & &1.provider) == ["ubuntu", "cisa", "nvd"]
  end

  test "finds a group by package key, assessment id, or supporting raw match id" do
    assessment =
      assessment(
        "assessment-quartz",
        "pkg-quartz",
        "quartz",
        "CVE-2099-4301"
      )

    raw = raw_match("raw-quartz-nvd", "pkg-quartz", "CVE-2099-4301", "nvd", "nist-nvd2")
    [group] = EndpointInventoryMatchGroups.group([assessment], [raw])

    assert EndpointInventoryMatchGroups.find([group], group.id).id == group.id
    assert EndpointInventoryMatchGroups.find([group], "assessment-quartz").id == group.id
    assert EndpointInventoryMatchGroups.find([group], "raw-quartz-nvd").id == group.id
    assert EndpointInventoryMatchGroups.find([group], "missing") == nil
  end

  defp assessment(id, package_ref, name, cve) do
    %{
      id: id,
      endpoint_package_ref: package_ref,
      cve_id: cve,
      advisory_id: cve,
      status: "active",
      assessment: "confirmed",
      disposition: "affected",
      authority: "ubuntu:USN-#{String.trim_leading(cve, "CVE-")}-1",
      applicability_reason: "exact distro package range",
      freshness: "fresh",
      provider: "ubuntu",
      feed_key: "ubuntu-usn",
      package_name: name,
      package_manager: "dpkg",
      package_release: "fixture-series",
      installed_version: "3.2.1-1ubuntu99.7",
      fixed_version: "3.2.1-1ubuntu99.8",
      severity: "high",
      cvss_score: 7.5,
      kev: false,
      exploit_available: false,
      supporting_match_ids: []
    }
  end

  defp raw_match(id, package_ref, cve, provider, feed_key) do
    %{
      id: id,
      endpoint_package_ref: package_ref,
      cve_id: cve,
      advisory_id: cve,
      provider: provider,
      feed_key: feed_key,
      kev: provider == "cisa",
      exploit_available: provider == "cisa",
      metadata: %{}
    }
  end
end
