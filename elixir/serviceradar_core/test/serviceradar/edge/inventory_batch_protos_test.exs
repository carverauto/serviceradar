defmodule ServiceRadar.Edge.InventoryBatchProtosTest do
  @moduledoc """
  Executes the generated Elixir protobuf modules for the batch inventory
  contracts. Expected bytes come from the protobuf wire encoding spec
  (tag = field_number << 3 | wire_type; proto3 omits default zeros), so an
  encoder that drops has_detected / has_risk_score / has_runtime_pid fails
  even if encode and decode share that bug.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.ContractCatalog
  alias ServiceRadar.Edge.Projectors.BumblebeeScan
  alias ServiceRadar.Edge.Projectors.K8sPublicEndpoints
  alias Serviceradar.Edge.V1.BumblebeeFindingV1
  alias Serviceradar.Edge.V1.BumblebeeScanPayloadV1
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.EdgeSourceAuthorizationV1
  alias Serviceradar.Edge.V1.EndpointInventoryScanPayloadV1
  alias Serviceradar.Edge.V1.EndpointInventorySourceSummaryV1
  alias Serviceradar.Edge.V1.K8sPublicEndpointsSnapshotV1
  alias Serviceradar.Edge.V1.K8sPublicEndpointV1
  alias Serviceradar.Edge.V1.WorkloadIdentityContainerLookupV1
  alias Serviceradar.Edge.V1.WorkloadIdentityRecordV1
  alias Serviceradar.Edge.V1.WorkloadIdentitySnapshotV1
  alias ServiceRadar.Edge.WireDecode

  test "explicit false detected is distinct non-empty wire bytes from unset" do
    unset = %EndpointInventorySourceSummaryV1{name: "trivy"}

    explicit = %EndpointInventorySourceSummaryV1{
      name: "trivy",
      detected: false,
      has_detected: true
    }

    unset_bytes = <<0x0A, 0x05, "trivy">>
    explicit_bytes = <<0x0A, 0x05, "trivy", 0x50, 0x01>>

    assert Protobuf.encode(unset) == unset_bytes
    assert Protobuf.encode(explicit) == explicit_bytes
    refute unset_bytes == explicit_bytes

    decoded = Protobuf.decode(explicit_bytes, EndpointInventorySourceSummaryV1)
    assert decoded.name == "trivy"
    assert decoded.detected == false
    assert decoded.has_detected == true
  end

  test "explicit zero risk score and runtime pid survive encode and decode" do
    finding = %BumblebeeFindingV1{risk_score: 0, has_risk_score: true}
    assert Protobuf.encode(finding) == <<0x30, 0x01>>
    decoded_finding = Protobuf.decode(<<0x30, 0x01>>, BumblebeeFindingV1)
    assert decoded_finding.risk_score == 0
    assert decoded_finding.has_risk_score == true

    nested = <<0x2A, 0x04, 0x12, 0x02, 0x50, 0x01>>

    snapshot = %WorkloadIdentitySnapshotV1{
      identities: [
        %WorkloadIdentityContainerLookupV1{
          identity: %WorkloadIdentityRecordV1{runtime_pid: 0, has_runtime_pid: true}
        }
      ]
    }

    assert Protobuf.encode(snapshot) == nested
    decoded = Protobuf.decode(nested, WorkloadIdentitySnapshotV1)
    [lookup] = decoded.identities
    assert lookup.identity.runtime_pid == 0
    assert lookup.identity.has_runtime_pid == true
  end

  test "four batch messages round-trip a schema marker" do
    for {module, field} <- [
          {WorkloadIdentitySnapshotV1, :context_name},
          {EndpointInventoryScanPayloadV1, :schema_version},
          {BumblebeeScanPayloadV1, :schema_version},
          {K8sPublicEndpointsSnapshotV1, :schema_version}
        ] do
      original = struct!(module, [{field, "batch-v1"}])
      encoded = Protobuf.encode(original)
      assert encoded != <<>>
      decoded = Protobuf.decode(encoded, module)
      assert Map.fetch!(decoded, field) == "batch-v1"
    end
  end

  test "k8s public endpoints snapshot projector decode" do
    snap = %K8sPublicEndpointsSnapshotV1{
      schema_version: "serviceradar.k8s_public_endpoints.v1",
      agent_id: "agent-k8s-1",
      cluster_id: "cluster-alpha",
      generated_at: "2026-07-01T12:00:00Z",
      endpoints: [
        %K8sPublicEndpointV1{
          cluster_id: "cluster-alpha",
          ip: "192.0.2.10",
          port: 443,
          protocol: "TCP",
          namespace: "default",
          service_name: "ingress"
        }
      ]
    }

    encoded = K8sPublicEndpointsSnapshotV1.encode(snap)
    assert {:ok, ^snap} = WireDecode.decode_k8s_public_endpoints_snapshot(encoded)

    record = %EdgeRecordV1{
      source_authorization: nil,
      payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
      compression: :EDGE_RECORD_COMPRESSION_NONE,
      encoded_size: byte_size(encoded),
      uncompressed_size: byte_size(encoded),
      payload_sha256: :crypto.hash(:sha256, encoded),
      projected_row_count: 1,
      payload: encoded
    }

    assert {:ok, ^snap} = K8sPublicEndpoints.decode(record)

    # Empty-endpoints snapshot requires projected_row_count == 1
    empty_snap = %K8sPublicEndpointsSnapshotV1{cluster_id: "cluster-alpha"}
    empty_encoded = K8sPublicEndpointsSnapshotV1.encode(empty_snap)

    assert {:ok, ^empty_snap} =
             K8sPublicEndpoints.decode(%{
               record
               | payload: empty_encoded,
                 encoded_size: byte_size(empty_encoded),
                 uncompressed_size: byte_size(empty_encoded),
                 payload_sha256: :crypto.hash(:sha256, empty_encoded),
                 projected_row_count: 1
             })

    assert {:error, :k8s_public_endpoints_row_count} =
             K8sPublicEndpoints.decode(%{record | projected_row_count: 2})

    assert {:error, :k8s_public_endpoints_generated_at} =
             K8sPublicEndpoints.decode(with_snapshot(record, %{snap | generated_at: "yesterday"}))

    [endpoint] = snap.endpoints

    assert {:error, :k8s_public_endpoints_endpoint_cluster_mismatch} =
             K8sPublicEndpoints.decode(
               with_snapshot(record, %{snap | endpoints: [%{endpoint | cluster_id: "  "}]})
             )
  end

  defp with_snapshot(record, snap) do
    encoded = K8sPublicEndpointsSnapshotV1.encode(snap)

    %{
      record
      | payload: encoded,
        encoded_size: byte_size(encoded),
        uncompressed_size: byte_size(encoded),
        payload_sha256: :crypto.hash(:sha256, encoded)
    }
  end

  test "serviceradar.bumblebee.scan contract catalog entry and decode validation" do
    assert {:ok,
            %{
              authority: :standing_grant,
              projector: BumblebeeScan,
              max_projected_rows: 10_000,
              write_bytes_per_row: 16_384,
              package_id: "serviceradar.agent.bumblebee"
            }} = ContractCatalog.fetch({"serviceradar.bumblebee.scan", 1})

    scan = %BumblebeeScanPayloadV1{
      schema_version: "serviceradar.bumblebee.scan.v1",
      agent_id: "agent-1",
      run_id: "run-1",
      metadata_json: ~s({"profile":"default"}),
      findings: [
        %BumblebeeFindingV1{
          finding_id: "finding-1",
          risk_score: 0,
          has_risk_score: true,
          evidence_json: ~s({"path":"/opt/demo"}),
          metadata_json: ~s({"source":"osv"})
        }
      ]
    }

    encoded = BumblebeeScanPayloadV1.encode(scan)

    record = %EdgeRecordV1{
      payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
      compression: :EDGE_RECORD_COMPRESSION_NONE,
      payload: encoded,
      encoded_size: byte_size(encoded),
      uncompressed_size: byte_size(encoded),
      payload_sha256: :crypto.hash(:sha256, encoded),
      projected_row_count: 1
    }

    assert {:ok, ^scan} = BumblebeeScan.decode(record)

    assert {:error, :bumblebee_scan_row_count} =
             BumblebeeScan.decode(%{record | projected_row_count: 2})

    assert {:error, :bumblebee_scan_source_authorization} =
             BumblebeeScan.decode(%{record | source_authorization: %EdgeSourceAuthorizationV1{}})
  end
end
