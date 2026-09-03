defmodule ServiceRadar.Inventory.AdvisoryFeeds.UbuntuParserTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.Parsers.Ubuntu

  @normalization_version 2
  @product_domain "serviceradar.ubuntu.product.v2"
  @lookup_domain "serviceradar.ubuntu.product-lookup.v2"
  @set_domain "serviceradar.ubuntu.product-set.v2"
  @osv_assertion_domain "serviceradar.ubuntu.osv-assertion.v2"
  @advisory_projection_domain "serviceradar.ubuntu.advisory.v2"
  @coordinate_projection_domain "serviceradar.ubuntu.coordinate.v2"
  @coordinates_projection_domain "serviceradar.ubuntu.coordinates.v2"
  @assertion_ref_projection_domain "serviceradar.ubuntu.projection-assertion-ref.v2"
  @assertion_refs_projection_domain "serviceradar.ubuntu.projection-assertions.v2"
  @projection_domain "serviceradar.ubuntu.projection.v2"
  @fixtures Path.expand("../../../support/fixtures/advisory_feeds/ubuntu", __DIR__)

  test "accepts the Go projector cross-language golden vector" do
    projected =
      @fixtures
      |> Path.join("projected_record_v2.json")
      |> File.read!()
      |> Jason.decode!()

    assert projected["projection_digest"] ==
             "1b50dc484913445449ace90285bf4f67395f15cbc16b74c35089e7a297f651e1"

    assert {:ok, record} =
             Ubuntu.parse_record(projected,
               source_digests: %{
                 osv: String.duplicate("a", 64),
                 vex: String.duplicate("b", 64)
               }
             )

    assert record.advisory.description ==
             "Synthetic <advisory> & café \u2028 used only to verify source-to-binary projection."

    assert Enum.any?(record.products, fn product ->
             product.id == "98675c6d-3fe5-8e34-8f23-a8b3be402e2a" and
               product.content_sha256 ==
                 "98675c6d3fe5ee34cf23a8b3be402e2ade2c728c9d69b8d34048eff21d89ec7b" and
               product.lookup_key == "65882bc3-9ac8-8cd5-a979-958b54c21406" and
               product.canonical_purl ==
                 "pkg:deb/ubuntu/starforge@42.0%2Btest1-0ubuntu1?arch=source&distro=noble"
           end)

    assert Enum.map(record.product_sets, &{&1.id, &1.content_sha256}) == [
             {"d96fb370-a225-8316-9d8b-d75604c10d40",
              "d96fb370a225d3161d8bd75604c10d4028f522907b60da48e63c08df987498b9"},
             {"f3d9ee88-91b7-87db-978c-23a7015e3af3",
              "f3d9ee8891b7f7db178c23a7015e3af335e9444b9ee6aa31af69c8fdc335bb93"}
           ]

    assert Enum.map(record.assertions, & &1.assertion_key) == [
             "573ec3f9c352d782c5431d1e847c1d620a2da4dec9250bfbc79fa0cf1a794b73",
             "90224ffd095e753bf425fb231f026ea5487dd643130e6aa5b062e8e12553c285"
           ]

    assert Enum.find(record.assertions, &(&1.source_kind == "ubuntu_openvex")).statement_fingerprint ==
             "cc2d0d7bd3c0913c594dbc1703cd7641e317ddb0bfcb300febd16bc504c056de"
  end

  test "accepts bounded top-level VEX fingerprint aliases" do
    projected =
      @fixtures
      |> Path.join("projected_record_v2.json")
      |> File.read!()
      |> Jason.decode!()

    index = Enum.find_index(projected["assertions"], &(&1["source_kind"] == "ubuntu_openvex"))

    aliases =
      get_in(projected, [
        "assertions",
        Access.at(index),
        "fingerprint_aliases"
      ])

    bounded =
      projected
      |> update_in(
        ["assertions", Access.at(index), "validation", "fingerprint_basis"],
        &Map.delete(&1, "vulnerability_aliases")
      )
      |> put_in(["assertions", Access.at(index), "fingerprint_aliases"], aliases)

    assert {:ok, _record} =
             Ubuntu.parse_record(bounded,
               source_digests: %{
                 osv: String.duplicate("a", 64),
                 vex: String.duplicate("b", 64)
               }
             )
  end

  test "accepts a normalized v2 projection and maps it to loader-native fields" do
    projected = valid_projected_record()

    assert {:ok,
            %{
              advisory: advisory,
              coordinates: [coordinate],
              products: [product],
              product_sets: [product_set],
              assertions: [assertion]
            }} =
             Ubuntu.parse_record(projected,
               provider: "ubuntu",
               feed_key: "ubuntu-osv-vex",
               source_digests: %{osv: String.duplicate("a", 64), vex: String.duplicate("b", 64)}
             )

    assert advisory.provider == "ubuntu"
    assert advisory.feed_key == "ubuntu-osv-vex"
    assert advisory.source_object_id == "UBUNTU-CVE-2099-424242"
    assert advisory.cve_id == "CVE-2099-424242"
    assert advisory.cvss_score == nil
    assert advisory.kev == false
    assert advisory.exploit_available == false
    assert advisory.metadata["normalization_version"] == 2
    assert advisory.metadata["projection_digest"] == projected["projection_digest"]
    assert advisory.raw == %{"projection_provenance" => projected["advisory"]["provenance"]}
    refute Map.has_key?(advisory.raw, "osv")
    refute Map.has_key?(advisory.raw, "vex")

    assert coordinate.coordinate_type == "purl"
    assert coordinate.value == hd(projected["coordinates"])["value"]

    assert product.id == hd(projected["products"])["id"]
    assert product.content_sha256 == hd(projected["products"])["digest"]
    assert product.package_name == "starforge-cli"
    assert product.package_version == "7:42.0-0ubuntu1.1"
    assert product.release == "noble"
    assert product.release_channel == "24.04:LTS"
    assert product.canonical_purl == hd(projected["products"])["purl"]
    assert product.product_scope == "binary"

    assert product_set.content_sha256 == hd(projected["product_sets"])["digest"]
    assert product_set.product_ids == [product.id]
    assert product_set.product_count == 1

    assert assertion.assertion_shape == "product_set"
    assert assertion.product_set_ref == product_set.id
    assert assertion.source_kind == "ubuntu_osv"
    assert assertion.affected_versions == []
    assert assertion.raw == hd(projected["assertions"])["provenance"]
    assert assertion.metadata == %{"validated_projection" => "ubuntu-v2"}
  end

  test "rejects product digest, deterministic id, lookup key, and canonical PURL tampering" do
    projected = valid_projected_record()

    tampered = [
      put_in(projected, ["products", Access.at(0), "digest"], String.duplicate("0", 64)),
      put_in(projected, ["products", Access.at(0), "id"], "00000000-0000-8000-8000-000000000000"),
      put_in(
        projected,
        ["products", Access.at(0), "lookup_key"],
        "00000000-0000-8000-8000-000000000000"
      ),
      put_in(projected, ["products", Access.at(0), "normalization_version"], 1),
      put_in(projected, ["products", Access.at(0), "canonical_size_bytes"], 1),
      update_in(projected, ["products", Access.at(0)], &Map.delete(&1, "normalization_version")),
      update_in(projected, ["products", Access.at(0)], &Map.delete(&1, "canonical_size_bytes")),
      put_in(
        projected,
        ["products", Access.at(0), "purl"],
        "pkg:deb/ubuntu/starforge-cli@7:42.0-0ubuntu1.1?distro=noble&arch=amd64"
      ),
      put_in(projected, ["products", Access.at(0), "release"], "jammy"),
      put_in(projected, ["products", Access.at(0), "version"], "")
    ]

    Enum.each(tampered, fn value ->
      assert {:error, {:invalid_ubuntu_projection, _reason}} = Ubuntu.parse_record(value)
    end)
  end

  test "rejects product-set count, order, digest, id, and missing-member tampering" do
    projected = valid_projected_record(two_products?: true)

    [first, second] = get_in(projected, ["product_sets", Access.at(0), "product_ids"])

    tampered = [
      put_in(projected, ["product_sets", Access.at(0), "count"], 1),
      put_in(projected, ["product_sets", Access.at(0), "product_ids"], [second, first]),
      put_in(projected, ["product_sets", Access.at(0), "product_ids"], [first, first]),
      put_in(
        projected,
        ["product_sets", Access.at(0), "digest"],
        String.duplicate("0", 64)
      ),
      put_in(
        projected,
        ["product_sets", Access.at(0), "id"],
        "00000000-0000-8000-8000-000000000000"
      ),
      put_in(
        projected,
        ["product_sets", Access.at(0), "product_ids", Access.at(0)],
        "00000000-0000-8000-8000-000000000000"
      )
    ]

    Enum.each(tampered, fn value ->
      assert {:error, {:invalid_ubuntu_projection, _reason}} = Ubuntu.parse_record(value)
    end)
  end

  test "accepts references to prior immutable definitions and rejects digest collisions" do
    projected = valid_projected_record()
    [product] = projected["products"]
    [set] = projected["product_sets"]

    replay =
      projected
      |> Map.put("products", [])
      |> Map.put("product_sets", [])

    assert {:ok, _record} =
             Ubuntu.parse_record(replay,
               known_products: %{product["id"] => product["digest"]},
               known_product_sets: %{set["id"] => set["digest"]}
             )

    assert {:error, {:invalid_ubuntu_projection, _reason}} =
             Ubuntu.parse_record(projected,
               known_products: %{product["id"] => String.duplicate("f", 64)}
             )
  end

  test "rejects assertion key, set digest, and top-level projection digest tampering" do
    projected = valid_projected_record()

    tampered = [
      put_in(
        projected,
        ["assertions", Access.at(0), "assertion_key"],
        String.duplicate("0", 64)
      ),
      put_in(
        projected,
        ["assertions", Access.at(0), "product_set_digest"],
        String.duplicate("0", 64)
      ),
      Map.put(projected, "projection_digest", String.duplicate("0", 64))
    ]

    Enum.each(tampered, fn value ->
      assert {:error, {:invalid_ubuntu_projection, _reason}} = Ubuntu.parse_record(value)
    end)
  end

  test "withdrawn OSV projections cannot retain coordinates or OSV assertions" do
    projected = valid_projected_record()

    withdrawn =
      projected
      |> put_in(["advisory", "withdrawn_at"], "2099-04-09T10:11:12Z")
      |> put_in(["advisory", "provenance", "osv_withdrawn"], true)

    assert {:error, {:invalid_ubuntu_projection, _reason}} = Ubuntu.parse_record(withdrawn)

    valid_tombstone =
      withdrawn
      |> Map.put("coordinates", [])
      |> Map.put("assertions", [])
      |> Map.put("products", [])
      |> Map.put("product_sets", [])
      |> with_projection_digest()

    assert {:ok, %{coordinates: [], assertions: []}} = Ubuntu.parse_record(valid_tombstone)
  end

  test "rejects oversized maps and advisory evidence before persistence" do
    projected = valid_projected_record()

    oversized_metadata =
      put_in(
        projected,
        ["products", Access.at(0), "metadata", "unexpected"],
        String.duplicate("x", 8_193)
      )

    assert {:error, {:invalid_ubuntu_projection, _reason}} =
             Ubuntu.parse_record(oversized_metadata)

    oversized_description =
      put_in(projected, ["advisory", "description"], String.duplicate("x", 1_048_577))

    assert {:error, {:invalid_ubuntu_projection, _reason}} =
             Ubuntu.parse_record(oversized_description)
  end

  test "normalization version is the projection protocol version" do
    assert Ubuntu.normalization_version() == 2
  end

  defp valid_projected_record(opts \\ []) do
    cve = "CVE-2099-424242"

    products =
      [
        product(%{
          "name" => "starforge-cli",
          "version" => "7:42.0-0ubuntu1.1",
          "source_name" => "starforge",
          "source_version" => "7:42.0-0ubuntu1.1"
        })
      ] ++
        if Keyword.get(opts, :two_products?, false) do
          [
            product(%{
              "name" => "libstarforge9",
              "version" => "7:42.0-0ubuntu1.1",
              "source_name" => "starforge",
              "source_version" => "7:42.0-0ubuntu1.1"
            })
          ]
        else
          []
        end

    products = Enum.sort_by(products, & &1["id"])
    set = product_set(products)
    advisory = advisory(cve)

    with_projection_digest(%{
      "protocol_version" => 2,
      "cve_id" => cve,
      "projection_digest" => "",
      "advisory" => advisory,
      "coordinates" => [
        %{
          "coordinate_type" => "purl",
          "value" => "pkg:deb/ubuntu/starforge@7:42.0-0ubuntu1.1?arch=source&distro=noble",
          "metadata" => %{"namespace" => "ubuntu"}
        }
      ],
      "products" => products,
      "product_sets" => [set],
      "assertions" => [osv_assertion(cve, set)]
    })
  end

  defp product(overrides) do
    value =
      Map.merge(
        %{
          "package_type" => "deb",
          "namespace" => "ubuntu",
          "name" => "starforge-cli",
          "version" => "7:42.0-0ubuntu1.1",
          "release" => "noble",
          "release_channel" => "24.04:LTS",
          "distro" => "noble",
          "source_name" => "starforge",
          "source_version" => "7:42.0-0ubuntu1.1",
          "scope" => "binary",
          "qualifiers" => %{"distro" => "noble"},
          "metadata" => %{"missing_release" => false}
        },
        overrides
      )

    value =
      Map.put(
        value,
        "purl",
        "pkg:deb/ubuntu/#{value["name"]}@#{value["version"]}?distro=noble"
      )

    canonical =
      tuple(@product_domain, [
        u32(@normalization_version),
        value["package_type"],
        value["namespace"],
        value["name"],
        value["version"],
        optional(value["release"]),
        optional(value["release_channel"]),
        optional(value["distro"]),
        optional(value["architecture"]),
        optional(value["source_name"]),
        optional(value["source_version"]),
        value["scope"],
        nil,
        string_map(value["qualifiers"])
      ])

    digest = :crypto.hash(:sha256, canonical)

    lookup =
      tuple_digest(@lookup_domain, [
        value["package_type"],
        value["namespace"],
        value["name"],
        value["version"]
      ])

    value
    |> Map.put("digest", hex(digest))
    |> Map.put("id", uuid(digest))
    |> Map.put("lookup_key", uuid(lookup))
    |> Map.put("canonical_size_bytes", byte_size(canonical))
    |> Map.put("normalization_version", @normalization_version)
  end

  defp product_set(products) do
    product_ids = products |> Enum.map(& &1["id"]) |> Enum.sort_by(&uuid_bytes/1)

    canonical =
      tuple(
        @set_domain,
        [u32(@normalization_version), u32(length(product_ids))] ++
          Enum.map(product_ids, &uuid_bytes/1)
      )

    digest = :crypto.hash(:sha256, canonical)

    %{
      "id" => uuid(digest),
      "digest" => hex(digest),
      "product_ids" => product_ids,
      "count" => length(product_ids),
      "canonical_size_bytes" => byte_size(canonical),
      "normalization_version" => 2
    }
  end

  defp osv_assertion(cve, set) do
    assertion = %{
      "cve_id" => cve,
      "source_kind" => "ubuntu_osv",
      "authority" => "Canonical Ltd.",
      "source_timestamp" => "2099-04-06T07:08:09Z",
      "disposition" => "affected",
      "product_set_ref" => set["id"],
      "product_set_digest" => set["digest"],
      "package_type" => "deb",
      "namespace" => "ubuntu",
      "release" => "noble",
      "release_channel" => "24.04:LTS",
      "version_scheme" => "deb",
      "product_scope" => "source_to_binary",
      "source_package" => "starforge",
      "package_purl" => "pkg:deb/ubuntu/starforge@7:42.0-0ubuntu1.1?arch=source&distro=noble",
      "introduced_version" => "0",
      "fixed_version" => "7:42.0-0ubuntu1.2",
      "validation" => %{
        "ecosystem" => "Ubuntu:24.04:LTS",
        "range_type" => "ECOSYSTEM",
        "event_cycle_count" => 1
      },
      "provenance" => %{
        "archive_sha256" => String.duplicate("a", 64),
        "source_document_sha256" => String.duplicate("c", 64),
        "explicit_source_versions" => 1,
        "binary_correlations" => 1,
        "source_purl_repaired" => false
      },
      "metadata" => %{}
    }

    key =
      tuple_digest(@osv_assertion_domain, [
        u32(@normalization_version),
        assertion["source_kind"],
        assertion["cve_id"],
        assertion["product_scope"],
        assertion["authority"],
        assertion["source_timestamp"],
        assertion["disposition"],
        assertion["package_type"],
        assertion["namespace"],
        optional(assertion["release"]),
        optional(assertion["release_channel"]),
        assertion["version_scheme"],
        assertion["source_package"],
        assertion["package_purl"],
        assertion["introduced_version"],
        optional(assertion["fixed_version"]),
        Base.decode16!(assertion["product_set_digest"], case: :lower)
      ])

    Map.put(assertion, "assertion_key", hex(key))
  end

  defp advisory(cve) do
    %{
      "source_object_id" => "UBUNTU-#{cve}",
      "advisory_id" => "UBUNTU-#{cve}",
      "cve_id" => cve,
      "title" => cve,
      "description" => "Synthetic advisory used only for projection tests.",
      "severity" => "medium",
      "cvss_vector" => "CVSS:3.1/AV:N",
      "published_at" => "2099-04-05T06:07:08Z",
      "modified_at" => "2099-04-06T07:08:09Z",
      "references" => ["https://security.example.invalid/#{cve}"],
      "provenance" => %{
        "normalization_version" => 2,
        "osv_present" => true,
        "vex_present" => false,
        "osv_archive_sha256" => String.duplicate("a", 64),
        "osv_document_sha256" => String.duplicate("c", 64),
        "osv_withdrawn" => false,
        "vex_empty_statements_tombstone" => false,
        "osv_affected_count" => 1,
        "vex_statement_count" => 0,
        "repaired_source_purl_count" => 0
      }
    }
  end

  defp with_projection_digest(record) do
    advisory = advisory_projection(record["advisory"])

    coordinates =
      record["coordinates"]
      |> Enum.map(fn coordinate ->
        tuple(@coordinate_projection_domain, [
          u32(@normalization_version),
          coordinate["coordinate_type"],
          coordinate["value"],
          string_map(coordinate["metadata"])
        ])
      end)
      |> Enum.sort()
      |> then(fn entries ->
        tuple(
          @coordinates_projection_domain,
          [u32(@normalization_version), u32(length(entries))] ++ entries
        )
      end)

    refs =
      record["assertions"]
      |> Enum.map(fn assertion ->
        tuple(@assertion_ref_projection_domain, [
          u32(@normalization_version),
          Base.decode16!(assertion["assertion_key"], case: :lower),
          optional_hex(assertion["statement_fingerprint"]),
          optional_uuid(assertion["product_set_ref"]),
          optional_hex(assertion["product_set_digest"])
        ])
      end)
      |> Enum.sort()
      |> then(fn entries ->
        tuple(
          @assertion_refs_projection_domain,
          [u32(@normalization_version), u32(length(entries))] ++ entries
        )
      end)

    digest =
      tuple_digest(@projection_domain, [
        u32(@normalization_version),
        record["cve_id"],
        advisory,
        coordinates,
        refs
      ])

    Map.put(record, "projection_digest", hex(digest))
  end

  defp advisory_projection(advisory) do
    provenance = advisory["provenance"]

    tuple(@advisory_projection_domain, [
      u32(@normalization_version),
      advisory["source_object_id"],
      advisory["advisory_id"],
      advisory["cve_id"],
      advisory["title"],
      optional(advisory["description"]),
      optional(advisory["severity"]),
      optional(advisory["cvss_vector"]),
      optional(advisory["published_at"]),
      optional(advisory["modified_at"]),
      optional(advisory["withdrawn_at"]),
      string_list(advisory["references"]),
      bool(provenance["osv_present"]),
      bool(provenance["vex_present"]),
      bool(provenance["osv_withdrawn"]),
      bool(provenance["vex_empty_statements_tombstone"]),
      u64(provenance["osv_affected_count"]),
      u64(provenance["vex_statement_count"]),
      u64(provenance["repaired_source_purl_count"])
    ])
  end

  defp optional_hex(nil), do: nil
  defp optional_hex(value), do: Base.decode16!(value, case: :lower)
  defp optional_uuid(nil), do: nil
  defp optional_uuid(value), do: uuid_bytes(value)
  defp bool(true), do: <<1>>
  defp bool(false), do: <<0>>
  defp u64(value), do: <<value::64-big>>

  defp string_list(values), do: u32(length(values)) <> Enum.map_join(values, &field/1)

  defp tuple_digest(domain, values), do: :crypto.hash(:sha256, tuple(domain, values))

  defp tuple(domain, values),
    do: field(domain) <> u32(length(values)) <> Enum.map_join(values, &field/1)

  defp field(nil), do: <<0xFFFFFFFF::32-big>>
  defp field(value) when is_binary(value), do: <<byte_size(value)::32-big, value::binary>>
  defp optional(nil), do: nil
  defp optional(""), do: nil
  defp optional(value), do: value
  defp u32(value), do: <<value::32-big>>

  defp string_map(values) do
    values
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(fn {key, value} -> field(key) <> field(value) end)
    |> then(&(u32(map_size(values)) <> &1))
  end

  defp uuid(digest) do
    <<a::32, b::16, c::16, d::16, e::48, _::binary>> = uuid_shaped(digest)

    [a, b, c, d, e]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {value, width} ->
      value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
    end)
  end

  defp uuid_shaped(<<prefix::binary-size(16), _::binary>>) do
    <<head::binary-size(6), seventh, eighth, ninth, rest::binary-size(7)>> = prefix

    <<head::binary, Bitwise.bor(Bitwise.band(seventh, 0x0F), 0x80), eighth,
      Bitwise.bor(Bitwise.band(ninth, 0x3F), 0x80), rest::binary>>
  end

  defp uuid_bytes(value) do
    value |> String.replace("-", "") |> Base.decode16!(case: :lower)
  end

  defp hex(value), do: Base.encode16(value, case: :lower)
end
