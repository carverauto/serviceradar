defmodule ServiceRadarAgentGateway.EdgeRecordIngestServerTest do
  use ExUnit.Case, async: false

  alias Serviceradar.Edge.V1.EdgeDeliveryAckV1
  alias Serviceradar.Edge.V1.EdgeDeliveryFrameV1
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordClientMessage
  alias Serviceradar.Edge.V1.EdgeRecordDisposition
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpen
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpenAck
  alias Serviceradar.Edge.V1.EdgeRecordServerMessage
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadarAgentGateway.EdgeRecordIngestServer
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaAdapterStub
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaIdentityResolverStub
  alias ServiceRadarAgentGateway.TestSupport.EdgeContractRegistryStub
  alias ServiceRadarAgentGateway.TestSupport.EdgeRecordCapabilityStub
  alias ServiceRadarAgentGateway.TestSupport.EdgeRecordPublisherStub

  @spool_id :binary.copy(<<0xAB>>, 16)
  @session_nonce :binary.copy(<<0xCD>>, 8)
  @network_scope_id :binary.copy(<<0x40>>, 16)
  @event_id :binary.copy(<<0x0E>>, 16)

  setup do
    previous = %{
      publisher: Application.get_env(:serviceradar_agent_gateway, :edge_record_ingest_publisher),
      resolver: Application.get_env(:serviceradar_agent_gateway, :edge_record_ingest_identity_resolver),
      capability: Application.get_env(:serviceradar_agent_gateway, :edge_record_ingest_capability),
      supervisor: Application.get_env(:serviceradar_agent_gateway, :edge_record_ingest_task_supervisor),
      registry: Application.get_env(:serviceradar_agent_gateway, :edge_record_contract_registry_impl)
    }

    Application.put_env(:serviceradar_agent_gateway, :edge_record_contract_registry_impl, EdgeContractRegistryStub)

    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})

    Application.put_env(:serviceradar_agent_gateway, :edge_record_ingest_publisher, EdgeRecordPublisherStub)

    Application.put_env(
      :serviceradar_agent_gateway,
      :edge_record_ingest_identity_resolver,
      CameraMediaIdentityResolverStub
    )

    Application.put_env(:serviceradar_agent_gateway, :edge_record_ingest_capability, EdgeRecordCapabilityStub)

    Application.put_env(
      :serviceradar_agent_gateway,
      :edge_record_ingest_task_supervisor,
      __MODULE__.TaskSupervisor
    )

    on_exit(fn ->
      restore_env(:edge_record_ingest_publisher, previous.publisher)
      restore_env(:edge_record_ingest_identity_resolver, previous.resolver)
      restore_env(:edge_record_ingest_capability, previous.capability)
      restore_env(:edge_record_ingest_task_supervisor, previous.supervisor)
      restore_env(:edge_record_contract_registry_impl, previous.registry)
    end)

    %{supervisor: supervisor}
  end

  test "opens a lane, publishes a verified frame, and acks it durable" do
    record = record()
    frame = frame(1, record)

    messages = [client({:lane_open, lane_open()}), client({:delivery_frame, frame})]

    assert :ok = EdgeRecordIngestServer.stream(messages, stream())

    assert_receive {:edge_record_stream_reply,
                    %EdgeRecordServerMessage{
                      payload:
                        {:lane_open_ack,
                         %EdgeRecordLaneOpenAck{
                           spool_id: @spool_id,
                           session_nonce: @session_nonce,
                           route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
                           traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK
                         }}
                    }}

    assert_received {:edge_record_published, publication}
    assert publication.slot.authenticated_agent_id == "agent-1"
    assert publication.slot.network_scope_id == @network_scope_id
    assert publication.slot.spool_id == @spool_id
    assert publication.slot.sequence == 1
    assert publication.route_profile == :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1
    assert publication.traffic_class == :EDGE_RECORD_TRAFFIC_CLASS_BULK
    assert publication.partition_rule == :network_scope_v1
    assert publication.record_bytes == frame.record_bytes
    assert publication.record_sha256 == frame.record_sha256
    assert publication.semantic_envelope_sha256 == record.semantic_envelope_sha256

    assert_receive {:edge_record_stream_reply,
                    %EdgeRecordServerMessage{
                      payload:
                        {:ack,
                         %EdgeDeliveryAckV1{
                           spool_id: @spool_id,
                           resolved_through_sequence: 1,
                           session_nonce: @session_nonce,
                           dispositions: [
                             %EdgeRecordDisposition{
                               sequence: 1,
                               event_id: @event_id,
                               kind: :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE
                             }
                           ]
                         }}
                    }}
  end

  test "replies through a real GRPC.Server.Stream, not only the test_pid shortcut" do
    messages = [client({:lane_open, lane_open()}), client({:delivery_frame, frame(1, record())})]

    assert :ok = EdgeRecordIngestServer.stream(messages, grpc_stream())

    assert_receive {:grpc_adapter_reply,
                    %EdgeRecordServerMessage{
                      payload: {:lane_open_ack, %EdgeRecordLaneOpenAck{spool_id: @spool_id}}
                    }}

    assert_receive {:grpc_adapter_reply,
                    %EdgeRecordServerMessage{
                      payload: {:ack, %EdgeDeliveryAckV1{resolved_through_sequence: 1}}
                    }}
  end

  test "refuses a lane_open when the client identity is not an agent" do
    Application.put_env(
      :serviceradar_agent_gateway,
      :edge_record_ingest_identity_resolver,
      __MODULE__.AddonIdentityResolverStub
    )

    error =
      assert_raise GRPC.RPCError, fn ->
        EdgeRecordIngestServer.stream([client({:lane_open, lane_open()})], stream())
      end

    assert error.status == GRPC.Status.permission_denied()
  end

  test "refuses a lane_open while the edge-records:v1 capability is not ready" do
    Process.put(:edge_record_capability_ready, false)

    error =
      assert_raise GRPC.RPCError, fn ->
        EdgeRecordIngestServer.stream([client({:lane_open, lane_open()})], stream())
      end

    assert error.status == GRPC.Status.unavailable()
  end

  test "rejects a stream whose first message is a delivery_frame" do
    error =
      assert_raise GRPC.RPCError, fn ->
        EdgeRecordIngestServer.stream([client({:delivery_frame, frame(1, record())})], stream())
      end

    assert error.status == GRPC.Status.failed_precondition()
  end

  test "refuses a delivery_frame naming a spool_id other than the opened lane's" do
    other_frame = 1 |> frame(record()) |> Map.put(:spool_id, :binary.copy(<<0xEE>>, 16))

    error =
      assert_raise GRPC.RPCError, fn ->
        EdgeRecordIngestServer.stream(
          [client({:lane_open, lane_open()}), client({:delivery_frame, other_frame})],
          stream()
        )
      end

    assert error.status == GRPC.Status.permission_denied()
  end

  test "permanently rejects a frame whose record_sha256 does not match its bytes, without raising" do
    tampered = 1 |> frame(record()) |> Map.put(:record_sha256, :binary.copy(<<0>>, 32))

    assert :ok =
             EdgeRecordIngestServer.stream(
               [client({:lane_open, lane_open()}), client({:delivery_frame, tampered})],
               stream()
             )

    assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:lane_open_ack, _}}}

    assert_receive {:edge_record_stream_reply,
                    %EdgeRecordServerMessage{
                      payload:
                        {:ack,
                         %EdgeDeliveryAckV1{
                           resolved_through_sequence: 1,
                           dispositions: [
                             %EdgeRecordDisposition{
                               sequence: 1,
                               kind: :EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT
                             }
                           ]
                         }}
                    }}

    refute_received {:edge_record_published, _}
  end

  test "publishes with the route the registry entry pins, not a hardcoded rule" do
    # StreamRoute evaluates only one rule today, so a sentinel the stub publisher records is what
    # distinguishes "taken from the entry" from the old hardcoded :network_scope_v1.
    Process.put(
      :edge_contract_registry_snapshot,
      {:ok, EdgeContractRegistryStub.snapshot_with(:active, %{partition_rule: :registry_pinned_rule})}
    )

    assert :ok = run_one_frame(record())

    assert_received {:edge_record_published, publication}
    assert publication.partition_rule == :registry_pinned_rule
  end

  test "withholds a contract the loaded snapshot does not contain: nothing published, nothing resolved" do
    unknown = %{EdgeContractRegistryStub.contract_ref() | contract_id: "serviceradar.test.unknown"}

    assert :ok = run_one_frame(%{record() | output_contract: unknown})

    refute_received {:edge_record_published, _}
    refute_received {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}
  end

  test "never acks past a withheld sequence, even for a later record that published durably" do
    stale = %{EdgeContractRegistryStub.contract_ref() | registry_epoch: 2}

    assert :ok =
             EdgeRecordIngestServer.stream(
               [
                 client({:lane_open, lane_open()}),
                 client({:delivery_frame, frame(1, %{record() | output_contract: stale})}),
                 client({:delivery_frame, frame(2, record())})
               ],
               stream()
             )

    assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:lane_open_ack, _}}}
    assert_received {:edge_record_published, %{slot: %{sequence: 2}}}
    refute_received {:edge_record_published, _}
    refute_received {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}
  end

  test "permanently rejects a record whose principal is not the authenticated agent" do
    assert :ok = run_one_frame(%{record() | producer_context: %EdgeProducerContext{origin_principal_id: "agent-2"}})

    refute_received {:edge_record_published, _}
    assert_permanent_ack(1)
  end

  test "withholds a record on a candidate bundle: nothing published, nothing resolved" do
    Process.put(:edge_contract_registry_snapshot, {:ok, EdgeContractRegistryStub.snapshot_with(:candidate)})

    assert :ok = run_one_frame(record())

    refute_received {:edge_record_published, _}
    refute_received {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}
  end

  test "holds a record on a security-revoked bundle: nothing published, nothing resolved" do
    Process.put(:edge_contract_registry_snapshot, {:ok, EdgeContractRegistryStub.snapshot_with(:security_revoked)})

    assert :ok = run_one_frame(record())

    refute_received {:edge_record_published, _}
    refute_received {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}
  end

  test "withholds every record while no registry is loaded" do
    Process.put(:edge_contract_registry_snapshot, {:error, :registry_not_configured})

    assert :ok = run_one_frame(record())

    refute_received {:edge_record_published, _}
    refute_received {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}
  end

  test "withholds a retryable publish outcome instead of acking it durable" do
    Process.put(:edge_record_publish_result, {:error, :capacity})

    assert :ok =
             EdgeRecordIngestServer.stream(
               [client({:lane_open, lane_open()}), client({:delivery_frame, frame(1, record())})],
               stream()
             )

    assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:lane_open_ack, _}}}
    refute_received {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:ack, _}}}
  end

  defmodule AddonIdentityResolverStub do
    @moduledoc false

    def resolve_from_cert(_cert_der) do
      {:ok, %{component_id: "addon-1", component_type: :addon, partition_id: "default"}}
    end
  end

  defp lane_open do
    %EdgeRecordLaneOpen{
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      spool_id: @spool_id,
      sequence_base: 1,
      first_unresolved_sequence: 1,
      session_nonce: @session_nonce,
      requested_byte_credits: 1024,
      requested_frame_credits: 4
    }
  end

  defp record do
    %EdgeRecordV1{
      event_id: @event_id,
      network_scope_id: @network_scope_id,
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      output_contract: EdgeContractRegistryStub.contract_ref(),
      producer_context: %EdgeProducerContext{origin_principal_id: "agent-1"},
      cost_model_version: 1,
      semantic_envelope_sha256: :binary.copy(<<0xAA>>, 32)
    }
  end

  defp run_one_frame(record) do
    result =
      EdgeRecordIngestServer.stream(
        [client({:lane_open, lane_open()}), client({:delivery_frame, frame(1, record)})],
        stream()
      )

    assert_receive {:edge_record_stream_reply, %EdgeRecordServerMessage{payload: {:lane_open_ack, _}}}
    result
  end

  defp assert_permanent_ack(sequence) do
    assert_receive {:edge_record_stream_reply,
                    %EdgeRecordServerMessage{
                      payload:
                        {:ack,
                         %EdgeDeliveryAckV1{
                           resolved_through_sequence: ^sequence,
                           dispositions: [
                             %EdgeRecordDisposition{
                               sequence: ^sequence,
                               event_id: @event_id,
                               kind: :EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT
                             }
                           ]
                         }}
                    }}
  end

  defp frame(sequence, record) do
    bytes = EdgeRecordV1.encode(record)

    %EdgeDeliveryFrameV1{
      spool_id: @spool_id,
      sequence: sequence,
      record_sha256: :crypto.hash(:sha256, bytes),
      record_bytes: bytes
    }
  end

  defp client(payload), do: %EdgeRecordClientMessage{payload: payload}

  defp stream, do: %{adapter: CameraMediaAdapterStub, payload: :test, test_pid: self()}

  # A real stream carries no test_pid, so replies go through GRPC.Server.send_reply/2.
  defp grpc_stream do
    %GRPC.Server.Stream{
      server: EdgeRecordIngestServer,
      grpc_type: :bidirectional_stream,
      adapter: __MODULE__.ReplyingAdapterStub,
      payload: self()
    }
  end

  defmodule ReplyingAdapterStub do
    @moduledoc false

    # Stands in for the Cowboy adapter; the stream payload is the test pid.
    def get_cert(pid) when is_pid(pid), do: <<1, 2, 3>>

    def send_reply(pid, data, _opts) do
      send(pid, {:grpc_adapter_reply, EdgeRecordServerMessage.decode(IO.iodata_to_binary(data))})
      :ok
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)
end
