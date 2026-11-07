defmodule ServiceRadar.Edge.PipelineStatsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Edge.PipelineStats
  alias Serviceradar.Edge.V1.EdgeOutputContractRef
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadar.EventWriter.ConsumerLagReporter
  alias ServiceRadar.EventWriter.Processors.EdgeRecord

  @sweep {"serviceradar.sweep.observation", 1}

  setup do
    if Process.whereis(PipelineStats), do: stop_supervised!(PipelineStats)
    :ok
  end

  test "counts are kept under bounded contract labels, and nothing is kept without the owner" do
    assert :ok = PipelineStats.record(:projected, @sweep)
    assert {:error, :unavailable} = PipelineStats.snapshot()

    start_supervised!(PipelineStats)

    PipelineStats.record(:gateway_admitted, @sweep, 3)
    PipelineStats.record(:projected, @sweep, 2)
    PipelineStats.record(:gateway_refused, {"serviceradar.invented.contract", 9})
    PipelineStats.record(:gateway_refused, {"serviceradar.other.invented", 4})
    PipelineStats.record(:gateway_withheld, nil)

    assert {:ok, %{node: node_name, contracts: contracts, consumers: []}} =
             PipelineStats.snapshot()

    assert node_name == to_string(node())

    by_label = Map.new(contracts, &{&1.contract, &1})

    assert by_label |> Map.keys() |> Enum.sort() == [
             "serviceradar.sweep.observation/1",
             "unattributed",
             "uncataloged"
           ]

    assert %{gateway_admitted: 3, projected: 2, failed: 0, last_admitted_at_ms: admitted_at} =
             by_label["serviceradar.sweep.observation/1"]

    assert is_integer(admitted_at)
    assert %{gateway_refused: 2, last_projected_at_ms: nil} = by_label["uncataloged"]
    assert %{gateway_withheld: 1} = by_label["unattributed"]
  end

  test "the edge-record processor counts a refused record under the contract it names" do
    start_supervised!(PipelineStats)

    record =
      EdgeRecordV1.encode(%EdgeRecordV1{
        output_contract: %EdgeOutputContractRef{
          contract_id: "serviceradar.sweep.observation",
          contract_version: 1
        }
      })

    # Neither carries the gateway's transport headers, so both are refused before any write.
    capture_log(fn ->
      assert {:ok, 0} =
               EdgeRecord.process_batch([
                 %{data: record, metadata: %{headers: %{}}},
                 %{data: <<255, 255, 255>>, metadata: %{headers: %{}}}
               ])
    end)

    assert {:ok, %{contracts: contracts}} = PipelineStats.snapshot()
    by_label = Map.new(contracts, &{&1.contract, &1})

    assert %{projector_refused: 1, projected: 0, failed: 0} =
             by_label["serviceradar.sweep.observation/1"]

    assert %{projector_refused: 1} = by_label["unattributed"]
  end

  test "a record's contract is read only from bytes the edge wire boundary accepts" do
    contract = %EdgeOutputContractRef{
      contract_id: "serviceradar.sweep.observation",
      contract_version: 1
    }

    assert PipelineStats.contract_of(
             EdgeRecordV1.encode(%EdgeRecordV1{output_contract: contract})
           ) == @sweep

    # 512 KiB is the edge record's frozen physical bound; a larger body is refused before decode.
    oversized =
      EdgeRecordV1.encode(%EdgeRecordV1{
        output_contract: contract,
        payload: :binary.copy(<<0>>, 512 * 1024)
      })

    assert PipelineStats.contract_of(oversized) == nil
    assert PipelineStats.contract_of(<<255, 255, 255>>) == nil
  end

  test "the lag reporter keeps the latest state of each edge-record durable and its stream depth" do
    start_supervised!(PipelineStats)

    dlq = %{
      stream: "TELEMETRY_EDGE_RECORD_DLQ_V1_BULK",
      durable: "serviceradar-event-writer-edge-record-dlq",
      subject_class: "edge_record_dlq"
    }

    metrics = %{
      stream: "events",
      durable: "serviceradar-event-writer-metrics",
      subject_class: "metrics"
    }

    info = %{num_pending: 2, num_ack_pending: 1, num_redelivered: 4, delivered: %{stream_seq: 9}}

    streams = %{
      dlq.stream => %{state: %{messages: 6, first_seq: 1}},
      metrics.stream => %{state: %{messages: 50}}
    }

    state = %ConsumerLagReporter{}
    state = ConsumerLagReporter.report_consumer(state, dlq, info, streams)
    _state = ConsumerLagReporter.report_consumer(state, metrics, info, streams)

    assert {:ok, %{consumers: [consumer]}} = PipelineStats.snapshot()

    assert %{
             subject_class: "edge_record_dlq",
             stream: "TELEMETRY_EDGE_RECORD_DLQ_V1_BULK",
             pending: 2,
             ack_pending: 1,
             redelivered: 4,
             stream_messages: 6
           } = consumer

    # A failed stream poll leaves the depth unknown rather than reporting an empty stream.
    _state = ConsumerLagReporter.report_consumer(state, dlq, %{info | num_pending: 3}, %{})

    assert {:ok, %{consumers: [%{pending: 3, stream_messages: nil}]}} = PipelineStats.snapshot()
  end
end
