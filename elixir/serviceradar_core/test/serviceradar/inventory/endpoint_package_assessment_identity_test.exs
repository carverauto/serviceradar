defmodule ServiceRadar.Inventory.EndpointPackageAssessmentIdentityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.EndpointPackageAssessmentIdentity

  test "version and PURL changes preserve the logical package key" do
    original = package()

    changed =
      original
      |> Map.put(:installed_version, "42.0~test1-0ubuntu99.9")
      |> Map.put(:source_version, "42.0~test1-0ubuntu99.9")
      |> Map.put(:purl, "pkg:deb/ubuntu/starling-fetch@42.0~test1-0ubuntu99.9")
      |> Map.put(:cpes, ["cpe:2.3:a:example:starling_fetch:42.0:*:*:*:*:*:*:*"])
      |> Map.put(:authority, :qualified_purl)
      |> Map.put(:conflicts, [%{field: :release}])

    assert EndpointPackageAssessmentIdentity.key(original) ==
             EndpointPackageAssessmentIdentity.key(changed)
  end

  test "every scoped identity component separates packages" do
    original = package()
    original_key = EndpointPackageAssessmentIdentity.key(original)

    for {field, value} <- [
          source_scope: "container:abc",
          package_type: "rpm",
          package_manager: "rpm",
          namespace: "debian",
          release: "equinox",
          ecosystem: "container",
          binary_package: "libstarling-fetch3",
          source_package: "starling-suite-minimal",
          architecture: "arm64"
        ] do
      refute EndpointPackageAssessmentIdentity.key(Map.put(original, field, value)) ==
               original_key,
             "expected #{field} to participate in package identity"
    end
  end

  test "source and host defaults are explicit and atom/string maps agree" do
    minimal =
      package()
      |> Map.delete(:source_scope)
      |> Map.delete(:source_package)

    explicit =
      package()
      |> Map.put(:source_scope, "host")
      |> Map.put(:source_package, "starling-fetch")

    string_keys = Map.new(explicit, fn {key, value} -> {Atom.to_string(key), value} end)

    assert EndpointPackageAssessmentIdentity.key(minimal) ==
             EndpointPackageAssessmentIdentity.key(explicit)

    assert EndpointPackageAssessmentIdentity.key(explicit) ==
             EndpointPackageAssessmentIdentity.key(string_keys)
  end

  test "nil and blank tuple components never collapse" do
    for field <- [
          :package_type,
          :package_manager,
          :namespace,
          :release,
          :ecosystem,
          :binary_package,
          :architecture
        ] do
      nil_key = EndpointPackageAssessmentIdentity.key(Map.put(package(), field, nil))
      blank_key = EndpointPackageAssessmentIdentity.key(Map.put(package(), field, ""))

      refute nil_key == blank_key, "expected nil and blank #{field} to differ"
    end
  end

  test "emits a stable namespaced URL-safe SHA-256 key" do
    key = EndpointPackageAssessmentIdentity.key(package())

    assert key == "pkgid:v1:m-Y2WaYyMjnn7Uuspy8hY260bvReUL6hHWpLR3AVN1E"
    assert key =~ ~r/\Apkgid:v1:[A-Za-z0-9_-]{43}\z/
  end

  defp package do
    %{
      source_scope: "host",
      package_type: "deb",
      package_manager: "dpkg",
      namespace: "ubuntu",
      release: "solstice",
      ecosystem: "linux",
      binary_package: "starling-fetch",
      source_package: "starling-suite",
      architecture: "amd64",
      installed_version: "42.0~test1-0ubuntu99.7",
      source_version: "42.0~test1-0ubuntu99.7",
      purl: "pkg:deb/ubuntu/starling-fetch@42.0~test1-0ubuntu99.7",
      cpes: []
    }
  end
end
