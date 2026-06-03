defmodule ServiceRadar.Inventory.EndpointInventoryArtifactStoreTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.EndpointInventoryArtifactStore

  test "uploads CycloneDX SBOM bytes with deterministic metadata" do
    sbom = sbom_payload()
    test = self()

    upload_object = fn metadata, data, opts ->
      send(test, {:upload, metadata, data, opts})
      {:ok, %{ok?: true}}
    end

    assert {:ok, artifact} =
             EndpointInventoryArtifactStore.upload_sbom("agent/one", "scan:one", sbom,
               upload_object: upload_object,
               timeout: 123
             )

    assert artifact.object_key =~ ~r|^endpoint-inventory/by-hash/[a-f0-9]{64}\.cdx\.json$|

    assert artifact.content_type == "application/json"
    assert artifact.format == "CycloneDX"
    assert artifact.spec_version == "1.6"
    assert artifact.size_bytes > 0

    assert_receive {:upload, metadata, data, [timeout: 123]}
    assert metadata.key == artifact.object_key
    assert metadata.sha256 == artifact.sha256
    assert metadata.total_size == artifact.size_bytes
    assert metadata.attributes["agent_id"] == "agent/one"
    assert metadata.attributes["scan_id"] == "scan:one"
    assert metadata.attributes["artifact_hash"] == artifact.artifact_hash
    assert Jason.decode!(data)["bomFormat"] == "CycloneDX"
  end

  test "rejects mismatched expected sha" do
    assert {:error, {:sha256_mismatch, "bad", _actual}} =
             EndpointInventoryArtifactStore.upload_sbom("agent-one", "scan-one", sbom_payload(),
               expected_sha256: "bad",
               upload_object: fn _metadata, _data, _opts -> {:ok, %{}} end
             )
  end

  defp sbom_payload do
    %{
      "bomFormat" => "CycloneDX",
      "specVersion" => "1.6",
      "version" => 1,
      "components" => [
        %{
          "type" => "library",
          "name" => "nginx",
          "version" => "1.24.0",
          "purl" => "pkg:deb/nginx@1.24.0",
          "properties" => [
            %{"name" => "serviceradar:package_manager", "value" => "dpkg"},
            %{"name" => "serviceradar:architecture", "value" => "amd64"}
          ]
        }
      ]
    }
  end
end
