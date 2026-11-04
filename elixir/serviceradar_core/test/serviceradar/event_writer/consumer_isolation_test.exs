defmodule ServiceRadar.EventWriter.ConsumerIsolationTest do
  @moduledoc """
  One consumer's stalled batcher must not take another consumer's demand.

  Broadway routes processor output to batchers through `GenStage.PartitionDispatcher`. Events
  for a batcher that stopped asking queue in its partition and keep the demand they used until
  that batcher drains, so in one shared pipeline a stalled batcher eventually leaves the
  producer asking for nothing at all. This runs the real worker supervision tree with an
  edge-record consumer and an events consumer, stalls the edge-record batcher, floods it, and
  requires the events consumer to keep delivering.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Producer

  @moduletag :db_free
  @moduletag :capture_log

  # Every batcher asks each processor for `batch_size` events, so with a batch size of 1 a
  # pipeline holds at most (batchers x processors) events in flight, a few hundred: the flood
  # outnumbers that many times over.
  @flood 2_000

  setup do
    previous = Application.get_env(:serviceradar_core, ServiceRadar.EventWriter)

    Application.put_env(:serviceradar_core, ServiceRadar.EventWriter,
      nats: [host: "127.0.0.1", port: closed_port(), tls: false],
      streams: [Config.edge_record_stream(), events_stream()],
      batch_size: 1,
      batch_timeout: 50
    )

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:serviceradar_core, ServiceRadar.EventWriter),
        else: Application.put_env(:serviceradar_core, ServiceRadar.EventWriter, previous)
    end)
  end

  test "a stalled edge-record batcher does not stop another consumer's deliveries" do
    start_supervised!(ServiceRadar.EventWriter.Supervisor)

    edge = pipeline_consuming("EDGE_RECORD")
    events = pipeline_consuming("EVENTS")
    batcher = batcher_process(edge, :edge_record)
    :ok = :sys.suspend(batcher)

    flood =
      Broadway.test_batch(edge, List.duplicate("synthetic edge record", @flood),
        metadata: %{subject: "telemetry.edge-record.v1.bulk.p01"}
      )

    try do
      # The stall is real: behind the flood, the stalled pipeline delivers nothing, even to
      # its other batchers.
      stuck = Broadway.test_message(edge, "behind the flood", metadata: syslog())
      refute_receive {:ack, ^stuck, _successful, _failed}, 500

      # Another consumer's message is still delivered and acknowledged.
      delivered = Broadway.test_message(events, "another consumer", metadata: syslog())
      assert_receive {:ack, ^delivered, [_], []}, 2_000
    after
      :sys.resume(batcher)
    end

    # Released, the flood drains (each record is refused: it carries no edge headers).
    assert drained(flood, @flood) == @flood
  end

  defp drained(ref, remaining, acked \\ 0)
  defp drained(_ref, 0, acked), do: acked

  defp drained(ref, remaining, acked) do
    receive do
      {:ack, ^ref, successful, failed} ->
        count = length(successful) + length(failed)
        drained(ref, remaining - count, acked + count)
    after
      10_000 -> acked
    end
  end

  # The running pipeline whose producer binds `stream`'s durable.
  defp pipeline_consuming(stream) do
    Enum.find(Broadway.all_running(), fn name ->
      case Broadway.producer_names(name) do
        [producer] ->
          case :sys.get_state(producer).state.module_state do
            %Producer{config: %Config{streams: streams}} ->
              Enum.any?(streams, &(&1.name == stream))

            _other ->
              false
          end

        _other ->
          false
      end
    end) || flunk("no running pipeline consumes #{stream}")
  end

  defp batcher_process(pipeline, key) do
    pipeline
    |> Broadway.topology()
    |> Keyword.fetch!(:batchers)
    |> Enum.find(&(&1.batcher_key == key))
    |> Map.fetch!(:batcher_name)
  end

  # `events.syslog` routes to the `:default` batcher, whose processor acknowledges without
  # writing anything.
  defp syslog, do: %{subject: "events.syslog"}

  defp events_stream do
    %{
      name: "EVENTS",
      stream_name: "events",
      subject: "events.>",
      processor: ServiceRadar.EventWriter.Processors.Events
    }
  end

  # The producers retry their connection in the background; nothing listens here.
  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
