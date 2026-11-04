defmodule ServiceRadar.Edge.SweepContractTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.ContractBundle
  alias ServiceRadar.Edge.ContractCatalog
  alias ServiceRadar.Edge.OutputContract
  alias ServiceRadar.Edge.Projectors.ScheduledMtrTrace
  alias ServiceRadar.Edge.Projectors.WorkloadIdentity
  alias Serviceradar.Edge.V1.AgentScheduledMtrTraceBatchV1
  alias Serviceradar.Edge.V1.AgentScheduledMtrTraceV1
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.MtrHopReplyDiagnosticsV1
  alias Serviceradar.Edge.V1.MtrMplsLabelV1
  alias Serviceradar.Edge.V1.MtrTcpHandshakeDiagnosticsV1
  alias Serviceradar.Edge.V1.MtrTraceEventV1
  alias Serviceradar.Edge.V1.MtrTraceHopV1
  alias Serviceradar.Edge.V1.WorkloadIdentityContainerLookupV1
  alias Serviceradar.Edge.V1.WorkloadIdentityRecordV1
  alias Serviceradar.Edge.V1.WorkloadIdentitySnapshotV1
  alias ServiceRadar.Observability.MtrMetricsIngestor

  @ref {"serviceradar.sweep.observation", 1}
  @snapshot :binary.copy(<<0xCD>>, 32)

  # A verified registry epoch whose sweep entry is this release's, with `change` applied.
  defp epoch(change \\ & &1) do
    entry = ContractBundle.local().contracts |> Map.fetch!(@ref) |> change.()
    %{epoch: 1_000_003, snapshot_sha256: @snapshot, contracts: %{@ref => entry}}
  end

  test "the active epoch's sweep entry gives the values a production capability signs" do
    assert {:ok, contract} = OutputContract.from_epoch(epoch(), @ref)

    assert contract.contract_id == "serviceradar.sweep.observation"
    assert contract.contract_version == 1
    assert contract.contract_bundle_sha256 == ContractBundle.bundle_sha256(sweep_catalog_entry())
    assert contract.registry_epoch == 1_000_003
    assert contract.registry_snapshot_sha256 == @snapshot
    assert contract.cost_model_version == 1
    assert contract.max_projected_row_count == 10_000
    assert contract.max_projected_write_bytes == 10_000 * 2_048
  end

  test "an entry that is missing, off the durable bulk lane, or a bundle this node does not hold gives no contract" do
    assert {:error, :contract_not_registered} =
             OutputContract.from_epoch(%{epoch() | contracts: %{}}, @ref)

    assert {:error, :contract_lane} =
             OutputContract.from_epoch(
               epoch(&%{&1 | traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE}),
               @ref
             )

    assert {:error, :contract_bundle_not_held} =
             OutputContract.from_epoch(
               epoch(&%{&1 | contract_bundle_sha256: :binary.copy(<<0xEE>>, 32)}),
               @ref
             )
  end

  defp sweep_catalog_entry do
    {:ok, entry} = ContractCatalog.fetch(@ref)
    entry
  end

  describe "serviceradar.mtr.scheduled_trace contract and projector" do
    test "is registered in ContractCatalog as a standing-grant contract" do
      assert {:ok, spec} = ContractCatalog.fetch({"serviceradar.mtr.scheduled_trace", 1})
      assert spec.authority == :standing_grant
      assert spec.projector == ScheduledMtrTrace
      assert spec.max_projected_rows == 1_000
      assert spec.write_bytes_per_row == 2_048
      assert spec.package_id == "serviceradar.agent.mtr"
    end

    test "decodes a valid batch and builds identical MtrMetricsIngestor rows as legacy JSON" do
      trace_uuid = "0197f8a0-0000-7000-8000-000000000053"
      event_uuid = "0197f8a0-0000-7000-8000-000000000054"

      batch = %AgentScheduledMtrTraceBatchV1{
        traces: [
          %AgentScheduledMtrTraceV1{
            check_id: "mtr-check-01",
            check_name: "Synthetic Edge Core Link",
            device_id: "sr:0197f8a0-0000-7000-8000-000000000001",
            probed_hops: 4,
            last_responding_hop: 2,
            tcp_port: 443,
            tcp_probe_mode: :MTR_TCP_PROBE_MODE_V1_SYN,
            trace: %MtrTraceEventV1{
              trace_id: Ecto.UUID.dump!(trace_uuid),
              event_id: Ecto.UUID.dump!(event_uuid),
              sweep_host_address: <<192, 0, 2, 10>>,
              device_hint: "sr:0197f8a0-0000-7000-8000-000000000001",
              observed_at_unix_nano: 1_780_000_000_000_000_000,
              attempted: true,
              outcome: :MTR_OUTCOME_REACHED,
              target: "target.example.com",
              resolved_address: <<192, 0, 2, 10>>,
              protocol: :TRANSPORT_PROTOCOL_TCP,
              ip_version: 4,
              packet_size: 64,
              target_reached: true,
              total_hops: 2,
              hops: [
                %MtrTraceHopV1{
                  hop_number: 1,
                  address: <<198, 51, 100, 1>>,
                  hostname: "hop1.example.com",
                  ecmp_addresses: [<<198, 51, 100, 2>>],
                  mpls_labels: [
                    %MtrMplsLabelV1{
                      label: 24_001,
                      experimental: 0,
                      bottom_of_stack: true,
                      ttl: 63
                    }
                  ],
                  asn: 64_512,
                  asn_org: "Example Transit AS64512",
                  sent: 10,
                  received: 10,
                  loss_pct: 0.0,
                  last_micro: 1_200,
                  avg_micro: 1_150,
                  min_micro: 1_000,
                  max_micro: 1_400,
                  stddev_micro: 120,
                  jitter_micro: 80,
                  jitter_worst_micro: 200,
                  jitter_interarrival_micro: 95
                },
                %MtrTraceHopV1{
                  hop_number: 2,
                  address: <<192, 0, 2, 10>>,
                  hostname: "target.example.com",
                  asn: 64_513,
                  asn_org: "Example Edge AS64513",
                  sent: 10,
                  received: 9,
                  loss_pct: 10.0,
                  last_micro: 3_400,
                  avg_micro: 3_200,
                  min_micro: 2_900,
                  max_micro: 3_800,
                  stddev_micro: 250,
                  jitter_micro: 140,
                  jitter_worst_micro: 400,
                  jitter_interarrival_micro: 160
                }
              ]
            },
            tcp_handshake: %MtrTcpHandshakeDiagnosticsV1{
              ttl: 64,
              attempts: 3,
              syn_sent: 4,
              synack_received: 3,
              rst_received: 0,
              unanswered: 1,
              syn_drop_pct: 25.0,
              syn_retransmits: 1,
              answered_after_retx: 1,
              ack_mismatch: 0,
              synack_duplicates: 0,
              rtt_min_us: 2_900,
              rtt_avg_us: 3_200,
              rtt_max_us: 3_800,
              server_response_us: 3_100,
              has_server_response_us: true
            },
            hop_diagnostics: [
              %MtrHopReplyDiagnosticsV1{
                hop_number: 1,
                reply_time_exceeded: 10
              },
              %MtrHopReplyDiagnosticsV1{
                hop_number: 2,
                has_unreachable_code: true,
                unreachable_code: 3,
                reply_unreachable: 1,
                reply_synack: 8
              }
            ]
          }
        ]
      }

      payload = AgentScheduledMtrTraceBatchV1.encode(batch)

      record = %EdgeRecordV1{
        source_authorization: nil,
        payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
        compression: :EDGE_RECORD_COMPRESSION_NONE,
        encoded_size: byte_size(payload),
        uncompressed_size: byte_size(payload),
        projected_row_count: 1,
        projected_write_bytes: 2_048,
        payload: payload
      }

      assert {:ok, decoded} = ScheduledMtrTrace.decode(record)
      assert decoded == batch

      legacy_payload = %{
        "results" => [
          %{
            "trace_uuid" => trace_uuid,
            "check_id" => "mtr-check-01",
            "check_name" => "Synthetic Edge Core Link",
            "target" => "target.example.com",
            "device_id" => "sr:0197f8a0-0000-7000-8000-000000000001",
            "available" => true,
            "timestamp" => 1_780_000_000_000_000_000,
            "error" => nil,
            "trace" => %{
              "target" => "target.example.com",
              "target_ip" => "192.0.2.10",
              "target_reached" => true,
              "total_hops" => 2,
              "probed_hops" => 4,
              "last_responding_hop" => 2,
              "protocol" => "tcp",
              "tcp_port" => 443,
              "tcp_probe_mode" => "syn",
              "ip_version" => 4,
              "packet_size" => 64,
              "timestamp" => 1_780_000_000_000_000_000,
              "tcp_handshake" => %{
                "ttl" => 64,
                "attempts" => 3,
                "syn_sent" => 4,
                "synack_received" => 3,
                "rst_received" => 0,
                "unanswered" => 1,
                "syn_drop_pct" => 25.0,
                "syn_retransmits" => 1,
                "answered_after_retx" => 1,
                "ack_mismatch" => 0,
                "synack_duplicates" => 0,
                "rtt_min_us" => 2_900,
                "rtt_avg_us" => 3_200,
                "rtt_max_us" => 3_800,
                "server_response_us" => 3_100
              },
              "hops" => [
                %{
                  "hop_number" => 1,
                  "addr" => "198.51.100.1",
                  "hostname" => "hop1.example.com",
                  "ecmp_addrs" => ["198.51.100.2"],
                  "asn" => %{"asn" => 64_512, "org" => "Example Transit AS64512"},
                  "mpls_labels" => [%{"label" => 24_001, "exp" => 0, "s" => true, "ttl" => 63}],
                  "sent" => 10,
                  "received" => 10,
                  "loss_pct" => 0.0,
                  "last_us" => 1_200,
                  "avg_us" => 1_150,
                  "min_us" => 1_000,
                  "max_us" => 1_400,
                  "stddev_us" => 120,
                  "jitter_us" => 80,
                  "jitter_worst_us" => 200,
                  "jitter_interarrival_us" => 95,
                  "reply_time_exceeded" => 10
                },
                %{
                  "hop_number" => 2,
                  "addr" => "192.0.2.10",
                  "hostname" => "target.example.com",
                  "ecmp_addrs" => [],
                  "asn" => %{"asn" => 64_513, "org" => "Example Edge AS64513"},
                  "mpls_labels" => nil,
                  "sent" => 10,
                  "received" => 9,
                  "loss_pct" => 10.0,
                  "last_us" => 3_400,
                  "avg_us" => 3_200,
                  "min_us" => 2_900,
                  "max_us" => 3_800,
                  "stddev_us" => 250,
                  "jitter_us" => 140,
                  "jitter_worst_us" => 400,
                  "jitter_interarrival_us" => 160,
                  "unreachable_code" => 3,
                  "reply_unreachable" => 1,
                  "reply_synack" => 8
                }
              ]
            }
          }
        ]
      }

      status = %{agent_id: "agent-test-01", gateway_id: "gw-test-01", partition: "default"}
      edge_payload = ScheduledMtrTrace.to_ingestor_payload(decoded)

      assert {:ok, %{traces: edge_traces, hops: edge_hops}} =
               MtrMetricsIngestor.rows(edge_payload, status)

      assert {:ok, %{traces: legacy_traces, hops: legacy_hops}} =
               MtrMetricsIngestor.rows(legacy_payload, status)

      assert edge_traces == legacy_traces
      assert edge_hops == legacy_hops
    end
  end

  describe "serviceradar.workload_identity.snapshot contract and projector" do
    test "is registered in ContractCatalog as a standing-grant contract" do
      assert {:ok, spec} = ContractCatalog.fetch({"serviceradar.workload_identity.snapshot", 1})
      assert spec.authority == :standing_grant
      assert spec.projector == WorkloadIdentity
      assert spec.max_projected_rows == 10_000
      assert spec.write_bytes_per_row == 8_192
      assert spec.package_id == "serviceradar.agent.workload_identity"
    end

    test "decodes populated and empty disabled snapshots and refuses malformed records" do
      populated = %WorkloadIdentitySnapshotV1{
        observed_at_unix_nano: 1_780_000_000_000_000_000,
        enabled: true,
        count: 1,
        identities: [
          %WorkloadIdentityContainerLookupV1{
            container_id: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            identity: %WorkloadIdentityRecordV1{
              container_id: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
              pod_name: "api-server-0",
              has_runtime_pid: true,
              runtime_pid: 4242
            }
          }
        ]
      }

      populated_payload = WorkloadIdentitySnapshotV1.encode(populated)

      populated_record = %EdgeRecordV1{
        payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
        compression: :EDGE_RECORD_COMPRESSION_NONE,
        encoded_size: byte_size(populated_payload),
        uncompressed_size: byte_size(populated_payload),
        projected_row_count: 1,
        projected_write_bytes: 8_192,
        payload: populated_payload
      }

      assert {:ok, ^populated} = WorkloadIdentity.decode(populated_record)

      empty = %WorkloadIdentitySnapshotV1{
        observed_at_unix_nano: 1_780_000_000_000_000_000,
        enabled: false,
        degradation_reason: "Disabled"
      }

      empty_payload = WorkloadIdentitySnapshotV1.encode(empty)

      empty_record = %EdgeRecordV1{
        payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
        compression: :EDGE_RECORD_COMPRESSION_NONE,
        encoded_size: byte_size(empty_payload),
        uncompressed_size: byte_size(empty_payload),
        projected_row_count: 1,
        projected_write_bytes: 8_192,
        payload: empty_payload
      }

      assert {:ok, ^empty} = WorkloadIdentity.decode(empty_record)

      assert {:error, :workload_identity_snapshot_row_count} =
               WorkloadIdentity.decode(%{empty_record | projected_row_count: 2})

      missing_container = %WorkloadIdentitySnapshotV1{
        observed_at_unix_nano: 1_780_000_000_000_000_000,
        enabled: true,
        identities: [%WorkloadIdentityContainerLookupV1{container_id: ""}]
      }

      missing_payload = WorkloadIdentitySnapshotV1.encode(missing_container)

      assert {:error, :workload_identity_no_container_id} =
               WorkloadIdentity.decode(%EdgeRecordV1{
                 payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
                 compression: :EDGE_RECORD_COMPRESSION_NONE,
                 encoded_size: byte_size(missing_payload),
                 uncompressed_size: byte_size(missing_payload),
                 projected_row_count: 1,
                 projected_write_bytes: 8_192,
                 payload: missing_payload
               })
    end
  end
end
