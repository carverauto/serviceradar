defmodule ServiceRadar.Inventory.EndpointInventoryPackageSetDeltaTest do
  @moduledoc """
  Pure (DB-free) unit tests for the endpoint inventory package-set delta
  application path. These verify reconstruction and hash agreement without
  touching the database, so they run in any environment.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.EndpointInventoryPackageSet, as: PackageSet

  defp pkg(name, version, opts \\ []) do
    %{
      "name" => name,
      "version" => version,
      "architecture" => Keyword.get(opts, :arch, "amd64"),
      "manager" => Keyword.get(opts, :manager, "dpkg"),
      "ecosystem" => Keyword.get(opts, :ecosystem)
    }
  end

  defp normalized(name, version, opts \\ []) do
    [pkg(name, version, opts)]
    |> PackageSet.normalize_delta_packages()
    |> hd()
  end

  test "normalize_delta_packages drops invalid entries" do
    entries = [pkg("bash", "5.1"), %{"version" => "x"}, "garbage"]
    assert [package] = PackageSet.normalize_delta_packages(entries)
    assert package.name == "bash"
  end

  test "apply_delta adds, removes, and replaces by coordinate" do
    current = [
      normalized("bash", "5.1"),
      normalized("curl", "7.80"),
      normalized("openssl", "3.0")
    ]

    delta = %{
      added: [normalized("nginx", "1.24")],
      removed: [normalized("openssl", "3.0")],
      changed: [normalized("curl", "7.81")]
    }

    reconstructed = PackageSet.apply_delta(current, delta)
    names_versions = reconstructed |> Enum.map(&{&1.name, &1.version}) |> Enum.sort()

    assert names_versions == [{"bash", "5.1"}, {"curl", "7.81"}, {"nginx", "1.24"}]
  end

  test "apply_delta then server_package_set_hash equals hash of the equivalent full set" do
    current = [normalized("bash", "5.1"), normalized("curl", "7.80")]

    delta = %{
      added: [normalized("nginx", "1.24")],
      removed: [],
      changed: [normalized("curl", "7.81")]
    }

    reconstructed = PackageSet.apply_delta(current, delta)

    full_equivalent = [
      normalized("bash", "5.1"),
      normalized("curl", "7.81"),
      normalized("nginx", "1.24")
    ]

    assert PackageSet.server_package_set_hash(reconstructed) ==
             PackageSet.server_package_set_hash(full_equivalent)
  end

  test "apply_delta is idempotent for an added coordinate that already exists" do
    current = [normalized("bash", "5.1")]
    delta = %{added: [normalized("bash", "5.2")], removed: [], changed: []}

    reconstructed = PackageSet.apply_delta(current, delta)
    assert [%{name: "bash", version: "5.2"}] = reconstructed
  end

  test "empty delta reproduces the current set" do
    current = [normalized("bash", "5.1"), normalized("curl", "7.80")]
    delta = %{added: [], removed: [], changed: []}

    reconstructed = PackageSet.apply_delta(current, delta)

    assert PackageSet.server_package_set_hash(reconstructed) ==
             PackageSet.server_package_set_hash(current)
  end

  test "canonical persistence decodes encoded PURL components once" do
    version = "7:42.0~test1-0ubuntu99.7+fixture1"

    [package] =
      PackageSet.normalize_delta_packages([
        %{
          "name" => "libexample42",
          "version" => version,
          "architecture" => "amd64",
          "manager" => "dpkg",
          "purl" =>
            "pkg:deb/ubuntu/libexample42@7:42.0~test1-0ubuntu99.7%2Bfixture1?arch=amd64&source=example-source&sourceversion=7:42.0~test1-0ubuntu99.7%2Bfixture1"
        }
      ])

    assert package.purl_canonical ==
             "pkg:deb/ubuntu/libexample42@7:42.0~test1-0ubuntu99.7%2Bfixture1?arch=amd64&source=example-source&sourceversion=7:42.0~test1-0ubuntu99.7%2Bfixture1"

    refute package.purl_canonical =~ "%252B"
  end

  test "canonical persistence retains a parsed PURL subpath" do
    [package] =
      PackageSet.normalize_delta_packages([
        %{
          "name" => "example-agent",
          "version" => "42.0~test1-0ubuntu99.7",
          "architecture" => "amd64",
          "manager" => "dpkg",
          "purl" =>
            "pkg:deb/ubuntu/example-agent@42.0~test1-0ubuntu99.7?arch=amd64#licenses/Example%20License"
        }
      ])

    assert package.purl_canonical ==
             "pkg:deb/ubuntu/example-agent@42.0~test1-0ubuntu99.7?arch=amd64#licenses/Example%20License"
  end
end
