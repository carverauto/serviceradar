defmodule ServiceRadar.Inventory.EndpointPackageIdentityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.EndpointPackageIdentity

  @version "7:42.0~test1-0ubuntu99.7+fixture1"
  @encoded_version "7:42.0~test1-0ubuntu99.7%2Bfixture1"

  test "projects a qualified raw PURL and prefers it to purl_canonical" do
    package = %{
      purl:
        "pkg:deb/ubuntu/libexample42@#{@encoded_version}?arch=amd64&distro=noble&source=example-source&sourceversion=#{@encoded_version}",
      purl_canonical: "pkg:deb/debian/libexample42@wrong?arch=amd64",
      package_manager: "dpkg",
      name: "libexample42",
      version: @version,
      architecture: "amd64"
    }

    assert EndpointPackageIdentity.from_package(package, nil) == %{
             package_type: "deb",
             namespace: "ubuntu",
             release: "noble",
             binary_package: "libexample42",
             installed_version: @version,
             source_package: "example-source",
             source_version: @version,
             source_package_explicit: true,
             architecture: "amd64",
             version_scheme: "deb",
             authority: :qualified_purl,
             conflicts: []
           }
  end

  test "falls back to canonical PURL but does not grant manager-only distro authority" do
    package = %{
      purl_canonical: "pkg:deb/debian/example-agent@#{@encoded_version}?arch=amd64",
      package_manager: "dpkg",
      name: "example-agent",
      version: @version,
      architecture: "amd64"
    }

    assert %{authority: :purl, namespace: "debian", release: nil, conflicts: []} =
             EndpointPackageIdentity.from_package(package, nil)

    assert %{authority: :manager_only, namespace: nil, release: nil, conflicts: []} =
             EndpointPackageIdentity.from_package(
               Map.delete(package, :purl_canonical),
               nil
             )
  end

  test "uses a qualified canonical PURL when the raw PURL is invalid" do
    package = %{
      purl: "not-a-purl",
      purl_canonical: "pkg:deb/ubuntu/example-agent@#{@encoded_version}?distro=noble",
      package_manager: "dpkg"
    }

    assert %{authority: :qualified_purl, namespace: "ubuntu", release: "noble"} =
             EndpointPackageIdentity.from_package(package, nil)
  end

  test "sourceversion alone does not make the fallback source package authoritative" do
    package = %{
      purl:
        "pkg:deb/ubuntu/libexample42@#{@encoded_version}?arch=amd64&distro=noble&sourceversion=#{@encoded_version}",
      name: "libexample42",
      version: @version
    }

    assert %{source_package: "libexample42", source_package_explicit: false} =
             EndpointPackageIdentity.from_package(package, nil)
  end

  test "does not invent a source version for a distinct explicit source package" do
    package = %{
      purl:
        "pkg:deb/ubuntu/libexample42@#{@encoded_version}?arch=amd64&distro=noble&source=example-source",
      name: "libexample42",
      version: @version
    }

    assert %{
             source_package: "example-source",
             source_package_explicit: true,
             source_version: nil
           } = EndpointPackageIdentity.from_package(package, nil)
  end

  test "does not grant Ubuntu distro authority to a cross-ecosystem PURL" do
    package = %{
      purl: "pkg:rpm/ubuntu/example-agent@42.0?arch=x86_64&distro=noble",
      name: "example-agent",
      version: "42.0"
    }

    assert %{package_type: "rpm", namespace: "ubuntu", authority: :purl} =
             EndpointPackageIdentity.from_package(package, nil)
  end

  test "retains provider and comparable release conflicts in deterministic order" do
    package = %{
      purl: "pkg:deb/ubuntu/example-agent@#{@encoded_version}?distro=noble",
      package_manager: "dpkg"
    }

    assert %{authority: :qualified_purl, conflicts: conflicts} =
             EndpointPackageIdentity.from_package(package, %{
               "id" => "debian",
               "version_codename" => "bookworm"
             })

    assert conflicts == [
             %{field: :namespace, package: "ubuntu", os: "debian"},
             %{field: :release, package: "noble", os: "bookworm"}
           ]
  end

  test "does not compare a numeric OS version to a PURL codename" do
    package = %{
      purl: "pkg:deb/ubuntu/example-agent@#{@encoded_version}?distro=noble",
      package_manager: "dpkg"
    }

    assert %{conflicts: []} =
             EndpointPackageIdentity.from_package(package, %{
               namespace: "ubuntu",
               version_id: "24.04"
             })
  end

  test "checks every provider alias so a benign alias cannot mask a mismatch" do
    package = %{
      purl: "pkg:deb/ubuntu/example-agent@#{@encoded_version}?distro=noble",
      package_manager: "dpkg"
    }

    assert %{conflicts: [%{field: :namespace, package: "ubuntu", os: "debian"}]} =
             EndpointPackageIdentity.from_package(package, %{
               namespace: "ubuntu",
               id: "debian",
               provider: "debian"
             })
  end

  test "checks every comparable release alias despite an incomparable numeric value" do
    package = %{
      purl: "pkg:deb/ubuntu/example-agent@#{@encoded_version}?distro=noble",
      package_manager: "dpkg"
    }

    assert %{conflicts: [%{field: :release, package: "noble", os: "jammy"}]} =
             EndpointPackageIdentity.from_package(package, %{
               namespace: "ubuntu",
               version_id: "22.04",
               version_codename: "jammy"
             })
  end
end
