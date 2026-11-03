defmodule ServiceRadar.EventWriter.Processors.EdgeRecordQuarantineTest do
  @moduledoc """
  The security-quarantine consumer only reports: it must succeed for every message, so JetStream
  never redelivers a quarantined record forever, and its log line must carry the coordinates an
  operator needs to fetch the record from the stream.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Edge.PublicationIdentity
  alias Serviceradar.Edge.V1.EdgeOutputContractRef
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadar.EventWriter.Processors.EdgeRecordQuarantine

  @network_scope_id <<0x01, 0x92, 0, 0, 0, 0, 0x70, 1, 0x80, 0, 0, 0, 0, 0, 0, 1>>
  @spool_id <<0x01, 0x92, 0, 0, 0, 0, 0x70, 2, 0x80, 0, 0, 0, 0, 0, 0, 2>>
  @event_id <<0x01, 0x92, 0, 0, 0, 0, 0x70, 3, 0x80, 0, 0, 0, 0, 0, 0, 3>>

  setup do
    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:serviceradar, :event_writer, :edge_record, :quarantined],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:quarantined, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "reports a quarantined record with its stream coordinates and writes nothing" do
    record_bytes =
      EdgeRecordV1.encode(%EdgeRecordV1{
        event_id: @event_id,
        output_contract: %EdgeOutputContractRef{
          contract_id: "serviceradar.test.contract",
          contract_version: 1
        }
      })

    message = message(record_bytes, headers(record_bytes), 42)

    log = capture_log(fn -> assert {:ok, 1} = EdgeRecordQuarantine.process_batch([message]) end)

    assert log =~ "Edge record held in security quarantine"
    assert log =~ "stream_sequence=42"
    assert log =~ "stream=TELEMETRY_EDGE_RECORD_SECURITY_QUARANTINE_V1_BULK"
    assert log =~ "authenticated_agent_id=agent-1"
    assert log =~ "event_id=" <> Base.encode16(@event_id, case: :lower)
    assert log =~ "contract_id=serviceradar.test.contract"

    assert_received {:quarantined, %{count: 1},
                     %{publication: "security_quarantine", described: true}}
  end

  test "a contract id with a line break cannot forge a second inspection line" do
    forged =
      "ok\r\nEdge record held in security quarantine: stream=TELEMETRY_EDGE_RECORD_SECURITY_QUARANTINE_V1_BULK stream_sequence=1\u2028Edge record held in security quarantine: stream_sequence=9"

    record_bytes =
      EdgeRecordV1.encode(%EdgeRecordV1{
        event_id: @event_id,
        output_contract: %EdgeOutputContractRef{contract_id: forged, contract_version: 1}
      })

    message = message(record_bytes, headers(record_bytes), 42)

    log = capture_log(fn -> assert {:ok, 1} = EdgeRecordQuarantine.process_batch([message]) end)

    inspection =
      log
      |> String.split(["\r\n", "\r", "\n", "\u2028"], trim: true)
      |> Enum.filter(&String.contains?(&1, "Edge record held in security quarantine"))

    assert length(inspection) == 1
    assert hd(inspection) =~ "stream_sequence=42"
    assert hd(inspection) =~ "contract_id=ok\\r\\nEdge record held in security quarantine:"
    assert hd(inspection) =~ "stream_sequence=1\\u2028Edge record held in security quarantine:"
    refute log =~ "contract_id=ok\r"
    refute log =~ "contract_id=ok\n"
  end

  test "an undescribable message is still reported, and still acknowledged" do
    message = message(<<0xFF, 0xFF, 0xFF>>, %{}, 7)

    log = capture_log(fn -> assert {:ok, 1} = EdgeRecordQuarantine.process_batch([message]) end)

    assert log =~ "Edge record held in security quarantine"
    assert log =~ "stream_sequence=7"
    assert_received {:quarantined, %{count: 1}, %{described: false}}
  end

  defp headers(record_bytes) do
    record_sha = :crypto.hash(:sha256, record_bytes)

    slot = %{
      network_scope_id: @network_scope_id,
      authenticated_agent_id: "agent-1",
      spool_id: @spool_id,
      sequence: 5
    }

    {:ok, msg_id} = PublicationIdentity.nats_msg_id(slot, :binary.copy(<<0xAA>>, 32), record_sha)
    {:ok, delivery_id} = PublicationIdentity.delivery_id(slot)

    {:ok, provenance} =
      PublicationIdentity.transport_provenance(%{
        edge: slot,
        delivery_mode: PublicationIdentity.mode_fresh(),
        delivery_proof: nil,
        record_sha256: record_sha,
        route_map_version: 1
      })

    %{
      "Nats-Msg-Id" => msg_id,
      "Sr-Edge-Delivery-Id" => delivery_id,
      "Sr-Edge-Transport-Provenance" => provenance
    }
  end

  defp message(data, headers, stream_sequence) do
    %Broadway.Message{
      data: data,
      metadata: %{
        subject: "telemetry.edge-record-security-quarantine.v1.bulk.p07",
        headers: headers,
        jetstream_ack: %{
          stream: "TELEMETRY_EDGE_RECORD_SECURITY_QUARANTINE_V1_BULK",
          stream_sequence: stream_sequence
        }
      },
      acknowledger: {Broadway.NoopAcknowledger, nil, nil}
    }
  end
end
