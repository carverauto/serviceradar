defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryMatchGroupsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryMatchGroups

  @moduletag :db_free

  test "groups matches by package and collapses the same CVE across feeds" do
    matches = [
      match("m1", "sudo", "CVE-2025-32463", "cisa", "cisa-kev",
        kev: true,
        endpoint_package_ref: "pkg-sudo"
      ),
      match("m2", "sudo", "CVE-2025-32463", "vulncheck", "vulncheck-kev",
        kev: true,
        endpoint_package_ref: "pkg-sudo"
      ),
      match("m3", "sudo", "CVE-2021-3156", "cisa", "cisa-kev",
        kev: true,
        endpoint_package_ref: "pkg-sudo"
      ),
      match("m4", "openssl", "CVE-2014-0160", "cisa", "cisa-kev",
        kev: true,
        endpoint_package_ref: "pkg-openssl"
      ),
      match("m5", "openssl", "CVE-2014-0160", "vulncheck", "vulncheck-kev",
        kev: true,
        endpoint_package_ref: "pkg-openssl"
      )
    ]

    groups = EndpointInventoryMatchGroups.group(matches)

    assert groups |> Enum.map(& &1.package_name) |> Enum.sort() == ["openssl", "sudo"]

    sudo = Enum.find(groups, &(&1.package_name == "sudo"))
    assert sudo.advisory_count == 2
    assert sudo.cve_ids == ["CVE-2025-32463", "CVE-2021-3156"]
    assert Enum.map(sudo.sources, & &1.provider) == ["cisa", "vulncheck"]

    openssl = Enum.find(groups, &(&1.package_name == "openssl"))
    assert openssl.advisory_count == 1
    assert Enum.map(hd(openssl.advisories).feeds, & &1.provider) == ["cisa", "vulncheck"]
  end

  test "finds a group by package key or by a member match id" do
    matches = [
      match("m1", "sudo", "CVE-2025-32463", "cisa", "cisa-kev", endpoint_package_ref: "pkg-sudo")
    ]

    [group] = EndpointInventoryMatchGroups.group(matches)

    assert EndpointInventoryMatchGroups.find([group], group.id).id == group.id
    assert EndpointInventoryMatchGroups.find([group], "m1").id == group.id
    assert EndpointInventoryMatchGroups.find([group], "missing") == nil
  end

  defp match(id, name, cve, provider, feed_key, opts) do
    %{
      id: id,
      cve_id: cve,
      advisory_id: cve,
      provider: provider,
      feed_key: feed_key,
      kev: Keyword.get(opts, :kev, false),
      exploit_available: Keyword.get(opts, :exploit_available, false),
      endpoint_package_ref: Keyword.get(opts, :endpoint_package_ref),
      evidence: %{"package" => %{"name" => name, "version" => "1.0", "package_manager" => "dpkg"}},
      version_evidence: %{"installed_version" => "1.0"}
    }
  end
end
