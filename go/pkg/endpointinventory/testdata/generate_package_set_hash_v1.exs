# Generates package_set_hash_v1.json (next to this file) from core's Elixir
# implementation, which is authoritative. Every input below is invented; never
# add packages exported from a real host. From the repository root:
#
#   elixir go/pkg/endpointinventory/testdata/generate_package_set_hash_v1.exs \
#     . go/pkg/endpointinventory/testdata/package_set_hash_v1.json
Mix.install([{:jason, "1.4.5"}])

[root, out] = System.argv()
lib = Path.join(root, "elixir/serviceradar_core/lib/serviceradar/inventory")

for f <- ~w(endpoint_inventory_payload.ex package_url.ex endpoint_inventory_package_set.ex) do
  Code.require_file(Path.join(lib, f))
end

alias ServiceRadar.Inventory.EndpointInventoryPackageSet, as: PS

pkg = fn fields -> Map.new(fields, fn {k, v} -> {Atom.to_string(k), v} end) end

cases = [
  {"dpkg_epoch_in_version",
   "A dpkg epoch arrives percent-encoded in the PURL version and raw in the version field. The canonical PURL decodes it once and keeps ':' unescaped.",
   [
     pkg.(name: "zlib1g", version: "1:1.2.13.dfsg-1", architecture: "amd64", manager: "dpkg", ecosystem: "debian",
       purl: "pkg:deb/debian/zlib1g@1%3A1.2.13.dfsg-1?arch=amd64&distro=debian-12"),
     pkg.(name: "libexample2", version: "2:0.9.1-3", architecture: "amd64", manager: "dpkg", ecosystem: "debian",
       purl: "pkg:deb/debian/libexample2@2:0.9.1-3?arch=amd64")
   ]},
  {"plus_raw_and_encoded",
   "'+' raw and as %2B, ':' as %3A. Decoding keeps a raw '+' (it is not a space) and re-encodes it as %2B.",
   [
     pkg.(name: "libwidget++1", version: "4.2.0-7+deb12u1", architecture: "amd64", manager: "dpkg",
       purl: "pkg:deb/debian/libwidget%2B%2B1@4.2.0-7%2Bdeb12u1?arch=amd64"),
     pkg.(name: "gadget-tools", version: "1.0+b2", architecture: "arm64", manager: "dpkg",
       purl: "pkg:deb/debian/gadget-tools@1.0+b2?arch=arm64"),
     pkg.(name: "sprocket", version: "3:5.1+dfsg-2", architecture: "amd64", manager: "dpkg",
       purl: "pkg:deb/debian/sprocket@3%3A5.1%2Bdfsg-2?arch=amd64&distro=debian+12")
   ]},
  {"multiple_qualifiers",
   "Several '&'-separated qualifiers, given out of order and with a mixed-case key. The hash line carries a raw '&', which must not be JSON-escaped.",
   [
     pkg.(name: "bash", version: "5.1.8-6.el9", architecture: "x86_64", manager: "rpm", ecosystem: "rpm",
       purl: "pkg:rpm/rpm/bash@5.1.8-6.el9?epoch=0&Distro=el-9&arch=x86_64"),
     pkg.(name: "coreutils", version: "8.32-34.el9", architecture: "aarch64", manager: "rpm",
       purl: "pkg:rpm/rpm/coreutils@8.32-34.el9?distro=el-9&arch=aarch64&repository_url=https%3A%2F%2Fmirror.example.com%2Frepo")
   ]},
  {"missing_purl_fallback",
   "No PURL at all: the canonical PURL is built from manager, ecosystem, name, version and architecture.",
   [
     pkg.(name: "tzdata", version: "2024a-0+deb12u1", architecture: "all", manager: "dpkg", ecosystem: "debian"),
     pkg.(name: "busybox", version: "1.36.1-r15", architecture: "x86_64", manager: "apk"),
     pkg.(name: "glibc", version: "2.34-100.el9", architecture: "x86_64", manager: "rpm"),
     pkg.(name: "requests", version: "2.31.0", manager: "pip", ecosystem: "PyPI"),
     pkg.(name: "left-pad", version: "1.3.0", manager: "npm")
   ]},
  {"apk_and_rpm_purls",
   "apk and rpm PURLs, one apk PURL with no namespace that takes the default.",
   [
     pkg.(name: "musl", version: "1.2.4-r2", architecture: "x86_64", manager: "apk",
       purl: "pkg:apk/alpine/musl@1.2.4-r2?arch=x86_64&distro=3.19.1"),
     pkg.(name: "ca-certificates", version: "20240226-r0", architecture: "aarch64", manager: "apk",
       purl: "pkg:apk/ca-certificates@20240226-r0"),
     pkg.(name: "openssl-libs", version: "3.0.7-27.el9", architecture: "x86_64", manager: "rpm",
       purl: "pkg:rpm/rpm/openssl-libs@3.0.7-27.el9?arch=x86_64&epoch=1")
   ]},
  {"arch_qualifier_vs_field",
   "Architecture as a PURL qualifier wins over the field; a field fills a missing qualifier; a field alone becomes the qualifier.",
   [
     pkg.(name: "libalpha", version: "1.0-1", architecture: "amd64", manager: "dpkg",
       purl: "pkg:deb/debian/libalpha@1.0-1?arch=i386"),
     pkg.(name: "libbeta", version: "2.0-1", architecture: "arm64", manager: "dpkg",
       purl: "pkg:deb/debian/libbeta@2.0-1"),
     pkg.(name: "libgamma", version: "3.0-1", architecture: "armhf", manager: "dpkg"),
     pkg.(name: "libdelta", version: "4.0-1", manager: "dpkg", purl: "pkg:deb/debian/libdelta@4.0-1?arch=s390x")
   ]},
  {"whitespace_and_case",
   "Surrounding whitespace is trimmed from every field; case is kept in fields, lowered in the PURL type, namespace and qualifier keys.",
   [
     pkg.(name: "  Curl  ", version: " 7.88.1-10 ", architecture: " AMD64 ", manager: " DPKG ", ecosystem: " Debian ",
       purl: "  pkg:DEB/Debian/Curl@7.88.1-10?Arch=AMD64  "),
     pkg.(name: "\u00A0nbsp-tool\u00A0", version: "1.0", manager: "apk"),
     pkg.(name: "spaced", version: "1.0", manager: "dpkg", purl: "pkg:generic/%20/spaced@1.0")
   ]},
  {"exact_duplicates",
   "Exact duplicates collapse to one. Two entries that canonicalize to the same PURL also collapse, and the first one in input order wins.",
   [
     pkg.(name: "dup", version: "1.0", architecture: "amd64", manager: "dpkg"),
     pkg.(name: "dup", version: "1.0", architecture: "amd64", manager: "dpkg"),
     pkg.(name: "first-wins", version: "2.0", manager: "dpkg", purl: "pkg:deb/debian/same@2.0"),
     pkg.(name: "second-loses", version: "2.0", manager: "dpkg", purl: "pkg:deb/debian/same@2.0")
   ]},
  {"non_ascii_and_line_separator",
   "A non-ASCII name and a name containing U+2028 and U+2029, which the JSON line keeps raw. HTML-significant characters are not escaped either.",
   [
     pkg.(name: "libcaf\u00E9-\u00FCtil", version: "1.0", architecture: "amd64", manager: "dpkg"),
     pkg.(name: "odd\u2028line\u2029name", version: "0.1", manager: "dpkg"),
     pkg.(name: "angle<b>&amp", version: "1.0", manager: "dpkg"),
     pkg.(name: "ctl\ttab\u007Fdel/slash\"quote\\back", version: "1.0", manager: "dpkg")
   ]},
  {"rightmost_at_and_subpath",
   "The version follows the RIGHTMOST '@', so a raw '@' in the namespace stays in the path. A '#subpath' is kept.",
   [
     pkg.(name: "widget", version: "1.2.3", manager: "npm", purl: "pkg:npm/@acme/widget@1.2.3"),
     pkg.(name: "mod", version: "v1.0.0", manager: "go", purl: "pkg:golang/example.com/mod@v1.0.0#sub/dir"),
     pkg.(name: "trailing-at", version: "9.9", manager: "dpkg", purl: "pkg:deb/debian/trailing-at@")
   ]},
  {"rejected_purl_falls_back",
   "PURLs the parser rejects -- a duplicate qualifier, a broken percent escape, no path -- are replaced by the fallback PURL.",
   [
     pkg.(name: "dupqual", version: "1.0", architecture: "amd64", manager: "dpkg",
       purl: "pkg:deb/debian/dupqual@1.0?arch=amd64&arch=i386"),
     pkg.(name: "badescape", version: "1.0", manager: "dpkg", purl: "pkg:deb/debian/badescape@1.0%2"),
     pkg.(name: "nopath", version: "1.0", manager: "rpm", purl: "pkg:rpm"),
     pkg.(name: "notapurl", version: "1.0", manager: "rpm", purl: "https://example.com/notapurl")
   ]},
  {"empty_qualifier_values",
   "A qualifier with an empty value or no '=' is dropped. Because the 'arch' key was present, the architecture field does NOT fill it. A whitespace value is kept.",
   [
     pkg.(name: "emptyq", version: "1.0", architecture: "amd64", manager: "dpkg",
       purl: "pkg:deb/debian/emptyq@1.0?arch=&distro"),
     pkg.(name: "spacevalue", version: "1.0", manager: "dpkg", purl: "pkg:deb/debian/spacevalue@1.0?distro=%20")
   ]},
  {"entries_without_name_or_manager",
   "Entries with no name or no manager are left out of the hash entirely.",
   [
     pkg.(name: "kept", version: "1.0", manager: "dpkg"),
     pkg.(name: "", version: "1.0", manager: "dpkg"),
     pkg.(name: "   ", version: "1.0", manager: "dpkg"),
     pkg.(name: "nomanager", version: "1.0", manager: "")
   ]}
]

canonical_purl = fn p ->
  case PS.normalize_packages(%{"packages" => [p]}) do
    [n] -> n.purl_canonical
    [] -> nil
  end
end

case_json =
  Enum.map(cases, fn {name, note, pkgs} ->
    normalized = PS.normalize_packages(%{"packages" => pkgs})

    %{
      "name" => name,
      "note" => note,
      "packages" => pkgs,
      "expected_purls" => Enum.map(pkgs, canonical_purl),
      "expected_package_count" => length(normalized),
      "expected_hash" => PS.server_package_set_hash(normalized)
    }
  end)

# The same packages as a CycloneDX document (core only; the Go producer always
# sends `packages`). Its hash must equal the packages case it mirrors.
{_, _, sbom_source} = Enum.find(cases, fn {n, _, _} -> n == "apk_and_rpm_purls" end)

components =
  Enum.map(sbom_source, fn p ->
    props =
      [{"serviceradar:package_manager", p["manager"]}, {"serviceradar:architecture", p["architecture"]},
       {"serviceradar:ecosystem", p["ecosystem"]}]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> %{"name" => k, "value" => v} end)

    %{"type" => "library", "name" => p["name"], "version" => p["version"], "purl" => p["purl"], "properties" => props}
  end)

sbom_hash = PS.server_package_set_hash(PS.normalize_packages(%{"sbom" => %{"components" => components}}))
pkg_hash = Enum.find(case_json, &(&1["name"] == "apk_and_rpm_purls"))["expected_hash"]
if sbom_hash != pkg_hash, do: raise("cyclonedx hash #{sbom_hash} != packages hash #{pkg_hash}")

doc = %{
  "description" =>
    "Shared package_set_hash (sha256-v1) vectors. Expected values were generated from the authoritative Elixir implementation (ServiceRadar.Inventory.EndpointInventoryPackageSet); go/pkg/endpointinventory and serviceradar_core both test against this file. All data is invented. The empty set is deliberately absent: core treats it as no hash (nil) while the producer reports a digest, and core never compares the two.",
  "hash_algorithm" => "sha256-v1",
  "cases" => case_json,
  "cyclonedx_cases" => [
    %{
      "name" => "cyclonedx_mirrors_apk_and_rpm_purls",
      "note" => "sbom.components carrying the apk_and_rpm_purls packages; core only.",
      "components" => components,
      "expected_hash" => sbom_hash
    }
  ]
}

# :unicode_safe keeps the file ASCII except DEL, which Jason never escapes.
json = doc |> Jason.encode!(pretty: true, escape: :unicode_safe) |> String.replace(<<0x7F>>, "\\u007F")
File.write!(out, json <> "\n")

for c <- case_json, do: IO.puts("#{c["name"]}: #{c["expected_package_count"]} #{c["expected_hash"]}")
