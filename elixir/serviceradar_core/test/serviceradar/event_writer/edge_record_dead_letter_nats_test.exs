defmodule ServiceRadar.EventWriter.EdgeRecordDeadLetterNatsTest do
  @moduledoc """
  The edge-record dead-letter on a real, disposable JetStream broker, through the production
  producer, ack callback, stream shapes and replay.

  A record whose projection fails is copied to the dead-letter stream with its original bytes,
  transport headers and failure headers, and the source delivery is acknowledged only once the
  copy is stored. While the dead-letter stream cannot store it, the source stays unacknowledged
  and is redelivered. A replay republishes the record to its source subject and deletes the
  copy; a record that fails again is dead-lettered again rather than deduplicated away.
  """
  use ExUnit.Case, async: false

  alias Broadway.Message
  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.ConsumerReconciler
  alias ServiceRadar.EventWriter.EdgeRecordDeadLetter.Replay
  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.EventWriter.Producer
  alias ServiceRadar.TestSupport.ExposureBroker

  @moduletag :db_free
  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  @source_subject "telemetry.edge-record.v1.bulk.p07"
  @dlq_stream "TELEMETRY_EDGE_RECORD_DLQ_V1_BULK"
  @record <<0, 1, 2, 3, "synthetic edge record", 255>>
  @headers [
    {"Nats-Msg-Id", "synthetic-publication-0001"},
    {"Sr-Edge-Delivery-Id", "synthetic-delivery-0001"},
    {"Sr-Edge-Transport-Provenance", "synthetic-provenance"}
  ]

  defmodule FailingSink do
    @moduledoc false
    # Stands in for the edge-record batcher whose projector keeps failing: every delivery is
    # failed and handed to the pipeline's real ack callback.
    use GenStage

    def start_link({producer, owner}), do: GenStage.start_link(__MODULE__, {producer, owner})

    @impl true
    def init({producer, owner}) do
      {:consumer, owner, subscribe_to: [{producer, max_demand: 1, min_demand: 0}]}
    end

    @impl true
    def handle_events(events, _from, owner) do
      Enum.each(events, fn event ->
        ack = event.metadata.jetstream_ack
        send(owner, {:delivered, ack.stream_sequence, ack.delivery_count, event.data})

        event
        |> Pipeline.transform([])
        |> Message.failed(%RuntimeError{message: "synthetic projection failure"})
        |> then(&Pipeline.ack(:ack_ref, [], [&1]))
      end)

      {:noreply, [], owner}
    end
  end

  setup do
    parent = self()
    handler_id = "edge-dead-letter-nats-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:serviceradar, :event_writer, :edge_record, :dead_letter],
      fn _event, _measurements, metadata, _config ->
        send(parent, {:dead_letter, metadata.result})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "a failing record is held until its copy is stored, then replayed without loss", ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, port ->
      config = config(port)
      [source, dead_letter] = config.streams
      assert :ok = ConsumerReconciler.ensure_stream(conn, config, source)
      producer = start_supervised!({Producer, %{config | streams: [source]}})
      start_supervised!({FailingSink, {producer, self()}})
      await_ready(:edge_dead_letter_producer)

      publish!(conn)

      # No dead-letter stream yet: the copy is refused, so the source is NAKed, not dropped.
      assert_receive {:delivered, 1, 1, @record}, 20_000
      assert_receive {:dead_letter, "failed"}, 20_000
      assert %{"error" => %{"code" => 404}} = api(conn, "STREAM.INFO.#{@dlq_stream}", "")

      assert :ok = ConsumerReconciler.ensure_stream(conn, config, dead_letter)

      # The copy the reconciler just created keeps the production dead-letter shape:
      # MaxAge off, DiscardNew, and the source stream's 24h duplicate window.
      dlq_info = api(conn, "STREAM.INFO.#{@dlq_stream}", "")
      assert dlq_info["config"]["max_age"] == 0
      assert dlq_info["config"]["discard"] == "new"
      assert dlq_info["config"]["duplicate_window"] == dead_letter.stream_duplicate_window
      assert dlq_info["config"]["duplicate_window"] == 86_400_000_000_000

      # The redelivery is copied, and only then acknowledged.
      assert_receive {:delivered, 1, 2, @record}, 30_000
      assert_receive {:dead_letter, "stored"}, 10_000
      await_settled(conn)

      assert {:ok, %{entries: [held]}} = Replay.list()
      assert held.dlq_subject == "telemetry.edge-record-dlq.v1.bulk.p07.unknown.v0"
      assert held.bytes == byte_size(@record)

      assert %{
               "source-subject" => @source_subject,
               "source-stream" => "TELEMETRY_EDGE_RECORD_V1_BULK",
               "source-sequence" => "1",
               "source-msg-id" => "synthetic-publication-0001",
               "attempts" => "2",
               "reason" => "RuntimeError",
               "reason-detail" => "synthetic projection failure"
             } = held.failure

      assert %{data: @record, headers: stored_headers} = get_message(conn, held.dlq_sequence)
      assert {"sr-edge-delivery-id", "synthetic-delivery-0001"} in stored_headers
      assert {"sr-edge-transport-provenance", "synthetic-provenance"} in stored_headers

      # Replay republishes the original record to its source and deletes the copy. The record
      # still fails, so it is dead-lettered again from its new source sequence.
      assert {:ok, %{entries: [%{result: :replayed}]}} = Replay.replay()
      assert_receive {:delivered, 2, 1, @record}, 20_000
      assert_receive {:dead_letter, "stored"}, 10_000
      await_settled(conn)

      assert {:ok, %{entries: [again]}} = Replay.list()
      assert again.dlq_sequence > held.dlq_sequence
      assert again.failure["source-sequence"] == "2"
      assert %{"state" => %{"messages" => 1}} = api(conn, "STREAM.INFO.#{@dlq_stream}", "")
      refute_receive {:delivered, _, _, _}, 1_000
    end)
  end

  test "a source duplicate keeps the dead-letter copy, and a later copy waits for the next run",
       ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, port ->
      config = config(port, 60_000_000_000)
      [source, dead_letter] = config.streams
      assert :ok = ConsumerReconciler.ensure_stream(conn, config, source)
      assert :ok = ConsumerReconciler.ensure_stream(conn, config, dead_letter)
      publish!(conn)

      held = publish_dlq!(conn, "edge-dlq:held-for-duplicate")

      # Snapshot last_seq, then store another copy before the walk reads. That copy arrived
      # after the run started, so this replay must leave it in place.
      request = fn subject, body, opts ->
        result = Gnat.request(conn, subject, body, opts)

        # Once, on the snapshot that bounds this run. A later list() must not store another copy.
        if String.ends_with?(subject, "STREAM.INFO.#{@dlq_stream}") and
             Process.get(:injected_later_copy) != true do
          Process.put(:injected_later_copy, true)
          publish_dlq!(conn, "edge-dlq:arrived-after-start")
        end

        result
      end

      assert {:ok, %{entries: [entry]}} = Replay.replay(request: request)
      assert entry.dlq_sequence == held
      assert entry.result == {:error, :source_duplicate}

      assert {:ok, %{entries: [kept, later]}} = Replay.list()
      assert kept.dlq_sequence == held
      assert later.dlq_sequence > held
      assert kept.failure["source-msg-id"] == "synthetic-publication-0001"
      assert %{"state" => %{"messages" => 2}} = api(conn, "STREAM.INFO.#{@dlq_stream}", "")
    end)
  end

  test "a duplicate of a removed dead-letter sequence leaves the source NAKed, never ACKed",
       ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, port ->
      config = config(port)
      [_source, dead_letter] = config.streams
      assert :ok = ConsumerReconciler.ensure_stream(conn, config, dead_letter)

      removed = publish_dlq!(conn, "edge-dlq:TELEMETRY_EDGE_RECORD_V1_BULK:41")
      assert :ok = delete_message(conn, removed)

      parent = self()
      request = fn subject, body, opts -> Gnat.request(conn, subject, body, opts) end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Pipeline.ack(:ack_ref, [], [removed_delivery(parent, request)])
        end)

      assert_receive {:ack_action, {:nack, _delay}}, 5_000
      refute_received {:ack_action, :ack}
      assert log =~ "dead_letter_copy_missing"
      assert %{"state" => %{"messages" => 0}} = api(conn, "STREAM.INFO.#{@dlq_stream}", "")
    end)
  end

  defp config(port, source_duplicate_window \\ 1_000_000_000) do
    %Config{
      enabled: true,
      producer_name: :edge_dead_letter_producer,
      nats: %{
        host: "127.0.0.1",
        port: port,
        tls: false,
        user: nil,
        password: nil,
        jwt: nil,
        nkey_seed: nil,
        creds_file: nil
      },
      consumer_name: "synthetic-writer",
      max_ack_pending: 8,
      consumer_pull_batch_size: 1,
      workers: 1,
      retired_consumers: [],
      streams: [
        # One server, so R1; a 1s duplicate window so the replay is not deduplicated against
        # the original publish. Dead-letter on the first failure.
        Map.put(
          %{
            Config.edge_record_stream()
            | stream_replicas: 1,
              stream_max_bytes: 16_777_216,
              dead_letter_after_deliveries: 1
          },
          :stream_duplicate_window,
          source_duplicate_window
        ),
        %{
          Config.edge_record_dead_letter_stream()
          | stream_replicas: 1,
            stream_max_bytes: 16_777_216
        }
      ]
    }
  end

  defp removed_delivery(parent, request) do
    Message.failed(
      %Message{
        data: @record,
        metadata: %{
          subject: @source_subject,
          headers: @headers,
          jetstream_ack: %{
            stream: "TELEMETRY_EDGE_RECORD_V1_BULK",
            consumer: "synthetic-writer",
            delivery_count: 1,
            stream_sequence: 41,
            timestamp: 1_700_000_000_000_000_000
          },
          max_deliver: -1,
          dead_letter_after: 1
        },
        acknowledger:
          {Pipeline, :ack_ref,
           %{
             ack_fun: fn action ->
               send(parent, {:ack_action, action})
               :ok
             end,
             request_fun: request
           }}
      },
      %RuntimeError{message: "synthetic projection failure"}
    )
  end

  defp delete_message(conn, seq) do
    reply = api(conn, "STREAM.MSG.DELETE.#{@dlq_stream}", Jason.encode!(%{seq: seq}))
    assert reply["success"] == true
    :ok
  end

  defp header_value(headers, name) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  defp publish!(conn) do
    {:ok, %{body: body}} =
      Gnat.request(conn, @source_subject, @record, headers: @headers, receive_timeout: 5_000)

    assert %{"stream" => "TELEMETRY_EDGE_RECORD_V1_BULK", "seq" => 1} = Jason.decode!(body)
  end

  defp publish_dlq!(conn, msg_id) do
    headers = [
      {"Nats-Msg-Id", msg_id},
      {"Sr-Edge-Dlq-Source-Subject", @source_subject},
      {"Sr-Edge-Dlq-Source-Stream", "TELEMETRY_EDGE_RECORD_V1_BULK"},
      {"Sr-Edge-Dlq-Source-Sequence", "1"},
      {"Sr-Edge-Dlq-Source-Msg-Id", "synthetic-publication-0001"},
      {"Sr-Edge-Delivery-Id", "synthetic-delivery-0001"}
    ]

    {:ok, %{body: body}} =
      Gnat.request(conn, "telemetry.edge-record-dlq.v1.bulk.p07.unknown.v0", @record,
        headers: headers,
        receive_timeout: 5_000
      )

    assert %{"stream" => @dlq_stream, "seq" => seq} = Jason.decode!(body)
    seq
  end

  # The source durable holds nothing: not pending, not awaiting an ack.
  defp await_settled(conn, attempts \\ 50) do
    durable = Config.durable_name("synthetic-writer", "EDGE_RECORD")
    info = api(conn, "CONSUMER.INFO.TELEMETRY_EDGE_RECORD_V1_BULK.#{durable}", "")

    cond do
      match?(%{"num_pending" => 0, "num_ack_pending" => 0}, info) ->
        :ok

      attempts == 0 ->
        flunk("source never settled: #{inspect(info)}")

      true ->
        Process.sleep(100)
        await_settled(conn, attempts - 1)
    end
  end

  defp await_ready(name, attempts \\ 200) do
    cond do
      Producer.status(name).ready ->
        :ok

      attempts == 0 ->
        flunk("producer not ready: #{inspect(Producer.status(name))}")

      true ->
        Process.sleep(50)
        await_ready(name, attempts - 1)
    end
  end

  defp get_message(conn, seq) do
    %{"message" => message} =
      api(conn, "STREAM.MSG.GET.#{@dlq_stream}", Jason.encode!(%{seq: seq}))

    block = Base.decode64!(message["hdrs"])
    {:ok, _status, _description, headers} = Gnat.Parsec.parse_headers(block)
    %{data: Base.decode64!(message["data"]), headers: headers}
  end

  defp api(conn, api, body) do
    {:ok, %{body: reply}} = Gnat.request(conn, "$JS.API." <> api, body, receive_timeout: 5_000)
    Jason.decode!(reply)
  end
end
