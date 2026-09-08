defmodule ServiceRadar.Inventory.BumblebeeCatalogArtifactTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.BumblebeeCatalogArtifact

  test "uploads immutable catalog artifact with hash and version metadata" do
    test_pid = self()

    upload_object = fn metadata, data, opts ->
      send(test_pid, {:upload, metadata, data, opts})
      {:ok, :uploaded}
    end

    entries = [
      %{
        catalog_id: "pkg-a",
        ecosystem: "npm",
        package_name: "left-pad",
        affected_versions: ["1.0.0"],
        severity: "critical",
        source_url: "https://example.invalid/advisory/pkg-a",
        metadata: %{"source" => "fixture"}
      }
    ]

    assert {:ok, artifact} =
             BumblebeeCatalogArtifact.materialize(
               "bumblebee:test:v1",
               entries,
               %{
                 "catalog_version" => "v1",
                 "source_revision" => "rev-1",
                 "schema_version" => "0.1.0"
               },
               upload_object: upload_object,
               timeout: 123
             )

    assert_receive {:upload, metadata, data, [timeout: 123]}

    expected_sha = :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)

    assert artifact["content_sha256"] == expected_sha
    assert artifact["object_key"] == "bumblebee/catalogs/bumblebee-test-v1/#{expected_sha}.json"
    assert artifact["object_size_bytes"] == byte_size(data)

    assert metadata.key == artifact["object_key"]
    assert metadata.sha256 == expected_sha
    assert metadata.total_size == byte_size(data)
    assert metadata.content_type == "application/json"
    assert metadata.attributes["catalog_snapshot_ref"] == "bumblebee:test:v1"
    assert metadata.attributes["catalog_version"] == "v1"
    assert metadata.attributes["source_revision"] == "rev-1"
    assert metadata.attributes["entry_count"] == "1"

    assert %{
             "schema_version" => "0.1.0",
             "snapshot_ref" => "bumblebee:test:v1",
             "catalog_version" => "v1",
             "source_revision" => "rev-1",
             "entries" => [
               %{
                 "id" => "pkg-a",
                 "ecosystem" => "npm",
                 "package" => "left-pad",
                 "versions" => ["1.0.0"],
                 "severity" => "critical"
               }
             ]
           } = Jason.decode!(data)
  end
end
