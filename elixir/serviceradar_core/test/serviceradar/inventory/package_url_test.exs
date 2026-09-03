defmodule ServiceRadar.Inventory.PackageUrlTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.PackageUrl

  test "parses and canonicalizes a Debian epoch version without double encoding" do
    assert {:ok, parsed} =
             PackageUrl.parse("pkg:deb/debian/attr@1:2.4.47-2%2Bb1?arch=amd64")

    assert parsed.version == "1:2.4.47-2+b1"

    assert PackageUrl.canonical(parsed) ==
             "pkg:deb/debian/attr@1:2.4.47-2%2Bb1?arch=amd64"

    assert {:ok, "pkg:deb/debian/attr@1:2.4.47-2%2Bb1?arch=amd64"} =
             PackageUrl.canonicalize("pkg:DEB/debian/attr@1:2.4.47-2%2Bb1?arch=amd64")

    refute PackageUrl.canonical(parsed) =~ "%252B"
  end

  test "preserves literal pluses, tildes, and the rightmost version delimiter" do
    assert {:ok, parsed} =
             PackageUrl.parse("pkg:deb/ubuntu/name@with@at@1:2.0~rc1+build?arch=amd64")

    assert parsed.name == "name@with@at"
    assert parsed.version == "1:2.0~rc1+build"

    assert PackageUrl.canonical(parsed) ==
             "pkg:deb/ubuntu/name%40with%40at@1:2.0~rc1%2Bbuild?arch=amd64"
  end

  test "lowercases qualifier keys, keeps values exact, and sorts qualifier keys" do
    assert {:ok, parsed} =
             PackageUrl.parse(
               "pkg:deb/ubuntu/example-agent@42.0~test1?Source=Example%2BSource&arch=amd64"
             )

    assert parsed.qualifiers == %{"arch" => "amd64", "source" => "Example+Source"}

    assert PackageUrl.canonical(parsed) ==
             "pkg:deb/ubuntu/example-agent@42.0~test1?arch=amd64&source=Example%2BSource"
  end

  test "rejects duplicate qualifiers after key normalization" do
    assert :error =
             PackageUrl.parse(
               "pkg:deb/ubuntu/example-agent@42.0~test1?source=example-source&source=other"
             )

    assert :error =
             PackageUrl.parse(
               "pkg:deb/ubuntu/example-agent@42.0~test1?Source=example-source&source=other"
             )
  end

  test "retains SCALIBR source qualifiers and subpaths" do
    assert {:ok, ubuntu} =
             PackageUrl.parse(
               "pkg:deb/ubuntu/libexample42@7:42.0~test1-0ubuntu99.7%2Bfixture1?distro=noble&source=example-source&sourceversion=7:42.0~test1-0ubuntu99.7%2Bfixture1#licenses/Example%20License"
             )

    assert ubuntu.qualifiers["source"] == "example-source"
    assert ubuntu.qualifiers["sourceversion"] == "7:42.0~test1-0ubuntu99.7+fixture1"
    assert ubuntu.subpath == ["licenses", "Example License"]
  end

  test "encodes reserved characters in every component exactly once" do
    components = %{
      type: "deb",
      namespace: ["ubuntu/ports"],
      name: "example?agent",
      version: "1:2.0+build#1",
      qualifiers: %{"source" => "example@source"},
      subpath: ["licenses/Example", "notice#1"]
    }

    canonical = PackageUrl.canonical(components)

    assert canonical ==
             "pkg:deb/ubuntu%2Fports/example%3Fagent@1:2.0%2Bbuild%231?source=example%40source#licenses%2FExample/notice%231"

    assert {:ok, ^components} = PackageUrl.parse(canonical)
  end

  test "rejects malformed percent escapes" do
    assert :error = PackageUrl.parse("pkg:deb/ubuntu/example-agent@42.0%2")
    assert :error = PackageUrl.parse("pkg:deb/ubuntu/example-agent@42.0%XZ")
  end
end
