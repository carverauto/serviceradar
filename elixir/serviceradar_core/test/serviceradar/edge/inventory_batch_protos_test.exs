defmodule ServiceRadar.Edge.InventoryBatchProtosTest do
  @moduledoc """
  Executes the generated Elixir protobuf modules for the batch inventory
  contracts. Expected bytes come from the protobuf wire encoding spec
  (tag = field_number << 3 | wire_type; proto3 omits default zeros), so an
  encoder that drops has_detected / has_risk_score / has_runtime_pid fails
  even if encode and decode share that bug.
  """
  use ExUnit.Case, async: true

  alias Serviceradar.Edge.V1.BumblebeeFindingV1
  alias Serviceradar.Edge.V1.BumblebeeScanPayloadV1
  alias Serviceradar.Edge.V1.EndpointInventoryScanPayloadV1
  alias Serviceradar.Edge.V1.EndpointInventorySourceSummaryV1
  alias Serviceradar.Edge.V1.K8sPublicEndpointsSnapshotV1
  alias Serviceradar.Edge.V1.WorkloadIdentityContainerLookupV1
  alias Serviceradar.Edge.V1.WorkloadIdentityRecordV1
  alias Serviceradar.Edge.V1.WorkloadIdentitySnapshotV1

  test "explicit false detected is distinct non-empty wire bytes from unset" do
    unset = %EndpointInventorySourceSummaryV1{name: "trivy"}
    explicit = %EndpointInventorySourceSummaryV1{name: "trivy", detected: false, has_detected: true}

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
end
