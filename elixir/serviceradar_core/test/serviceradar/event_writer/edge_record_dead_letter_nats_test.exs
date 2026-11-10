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
  alias ServiceRadar.Edge.PipelineStats
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
    start_supervised!(PipelineStats)

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
      # A copy the dead-letter stream refused is not counted as dead-lettered.
      assert dead_lettered() == 0

      assert :ok = ConsumerReconciler.ensure_stream(conn, config, dead_letter)

      # The copy the reconciler just created keeps the production dead-letter shape:
      # MaxAge off, DiscardNew, and the explicit 72h duplicate window (no longer
      # derived from the source stream's MaxAge, which is disabled).
      dlq_info = api(conn, "STREAM.INFO.#{@dlq_stream}", "")
      assert dlq_info["config"]["max_age"] == 0
      assert dlq_info["config"]["discard"] == "new"
      assert dlq_info["config"]["duplicate_window"] == dead_letter.stream_duplicate_window
      assert dlq_info["config"]["duplicate_window"] == 259_200_000_000_000

      # The redelivery is copied, and only then acknowledged.
      assert_receive {:delivered, 1, 2, @record}, 30_000
      assert_receive {:dead_letter, "stored"}, 10_000
      await_settled(conn)
      # The record does not decode, so its contract is not known.
      assert dead_lettered() == 1

      assert {:ok,
              %{
                dead_letter_reasons: [
                  %{contract: "unattributed", reason: "RuntimeError", count: 1}
                ]
              }} =
               PipelineStats.snapshot()

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

      # Replaying another reason leaves this record held and is not counted against the limit.
      assert {:ok, %{entries: []}} = Replay.replay(reason: "output_grant_not_current", limit: 1)
      assert {:ok, %{entries: [^held]}} = Replay.list(reason: "RuntimeError")

      # Replay republishes the original record to its source and deletes the copy. The record
      # still fails, so it is dead-lettered again from its new source sequence.
      assert {:ok, %{entries: [%{result: :replayed}]}} = Replay.replay(reason: "RuntimeError")
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

  test "the inventory groups held dead letters, and a purge scoped to one group deletes only it",
       ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, port ->
      [_source, dead_letter] = config(port).streams
      assert :ok = ConsumerReconciler.ensure_stream(conn, config(port), dead_letter)

      superseded = [
        {"Sr-Edge-Dlq-Contract", "serviceradar.plugin_results.batch/1"},
        {"Sr-Edge-Dlq-Reason", "missing_synthetic_capability"},
        {"Sr-Edge-Dlq-Reason-Detail", "synthetic capability refusal"},
        {"Sr-Edge-Dlq-Agent-Id", "agent-synthetic-01"}
      ]

      transient = [
        {"Sr-Edge-Dlq-Contract", "serviceradar.sync.page.batch/1"},
        {"Sr-Edge-Dlq-Reason", "RuntimeError"},
        {"Sr-Edge-Dlq-Agent-Id", "agent-synthetic-02"}
      ]

      undecoded = [{"Sr-Edge-Dlq-Reason", "missing_synthetic_capability"}]

      first = publish_dlq!(conn, "edge-dlq:superseded-1", superseded)
      kept = publish_dlq!(conn, "edge-dlq:transient-1", transient)
      unattributed = publish_dlq!(conn, "edge-dlq:undecoded-1", undecoded)
      last = publish_dlq!(conn, "edge-dlq:superseded-2", superseded)

      assert {:ok, %{scanned: 4, complete: true, through_sequence: ^last, groups: groups}} =
               Replay.inventory()

      assert [plugin, sync] =
               Enum.filter(groups, &is_binary(&1.contract))

      # A dead letter without a contract header is its own group, not part of its reason's.
      assert [%{contract: nil, reason: "missing_synthetic_capability", count: 1}] =
               Enum.filter(groups, &is_nil(&1.contract))

      assert %{
               contract: "serviceradar.plugin_results.batch/1",
               reason: "missing_synthetic_capability",
               count: 2,
               first_sequence: ^first,
               last_sequence: ^last,
               agents: ["agent-synthetic-01"],
               agent_count: 1,
               reason_detail: "synthetic capability refusal"
             } = plugin

      assert %{contract: "serviceradar.sync.page.batch/1", reason: "RuntimeError", count: 1} =
               sync

      # A bounded read says it saw only part of what is held, and where it stopped.
      assert {:ok, %{scanned: 2, complete: false, through_sequence: ^kept}} =
               Replay.inventory(limit: 2)

      # An action bounded to that read leaves a matching record past it held.
      assert {:ok, %{entries: [%{dlq_sequence: ^first, result: :purged}], complete: true}} =
               Replay.purge(reason: "missing_synthetic_capability", through_sequence: kept)

      assert {:ok, %{entries: [%{dlq_sequence: ^unattributed, result: :purged}], complete: true}} =
               Replay.purge(contract: :missing, reason: "missing_synthetic_capability")

      assert {:ok, %{entries: purged, complete: true}} =
               Replay.purge(reason: "missing_synthetic_capability")

      assert Enum.map(purged, &{&1.dlq_sequence, &1.result}) == [{last, :purged}]

      assert {:ok, %{entries: [%{dlq_sequence: ^kept}]}} = Replay.list()
      assert %{"state" => %{"messages" => 1}} = api(conn, "STREAM.INFO.#{@dlq_stream}", "")

      # Only deleted sequences remain above the one held record, so a read of exactly one
      # message has seen everything held.
      assert {:ok, %{scanned: 1, complete: true}} = Replay.inventory(limit: 1)
    end)
  end

  test "an operator purge is audited from the walking process when it starts and when it ends",
       ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, port ->
      [_source, dead_letter] = config(port).streams
      assert :ok = ConsumerReconciler.ensure_stream(conn, config(port), dead_letter)

      superseded = [
        {"Sr-Edge-Dlq-Contract", "serviceradar.plugin_results.batch/1"},
        {"Sr-Edge-Dlq-Reason", "missing_synthetic_capability"}
      ]

      seq = publish_dlq!(conn, "edge-dlq:operator-1", superseded)

      # Without a repo the audit publish cannot complete, so each attempted event is reported on
      # the AuditWriter's publish-failure telemetry, in the order it was written.
      previous = Application.get_env(:serviceradar_core, :repo_enabled)
      Application.put_env(:serviceradar_core, :repo_enabled, false)
      test_pid = self()
      handler_id = "dead-letter-operator-audit-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:serviceradar, :audit, :publish_failed],
        fn _event, _measurements, metadata, _config -> send(test_pid, {:audit, metadata}) end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
        Application.put_env(:serviceradar_core, :repo_enabled, previous)
      end)

      actor = %{id: "00000000-0000-0000-0000-000000000001", email: "operator@example.com"}

      assert {:ok, %{entries: [%{dlq_sequence: ^seq, result: :purged}], complete: true}} =
               Replay.operator_action(
                 :purge,
                 [
                   reason: "missing_synthetic_capability",
                   contract: "serviceradar.plugin_results.batch/1"
                 ],
                 actor
               )

      audited =
        for _event <- 1..2 do
          assert_received {:audit, %{resource_type: "edge_record_dead_letters", action: action}}
          action
        end

      assert audited == [:purge_started, :delete]
      assert %{"state" => %{"messages" => 0}} = api(conn, "STREAM.INFO.#{@dlq_stream}", "")
    end)
  end

  test "a redelivery of a dead-lettered record whose copy was removed is ACKed, not re-stored",
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

      assert_receive {:ack_action, :ack}, 5_000
      refute_received {:ack_action, {:nack, _delay}}
      assert log =~ "Edge record already dead-lettered"
      assert %{"state" => %{"messages" => 0}} = api(conn, "STREAM.INFO.#{@dlq_stream}", "")
    end)
  end

  test "a full primary edge-record stream refuses a publish under DiscardNew without evicting stored records, and stores the redelivered record once space frees up",
       ctx do
    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, port ->
      config = config(port)
      source = %{Config.edge_record_stream() | stream_replicas: 1, stream_max_bytes: 512}

      # Simulate an existing deployment whose primary stream was created with DiscardOld and 24h MaxAge,
      # then prove ConsumerReconciler.ensure_stream upgrades it in place to DiscardNew and no MaxAge.
      legacy = %{source | stream_discard: "old", stream_max_age: 86_400_000_000_000}
      assert :ok = ConsumerReconciler.ensure_stream(conn, config, legacy)

      assert %{"config" => %{"discard" => "old", "max_age" => 86_400_000_000_000}} =
               api(conn, "STREAM.INFO.TELEMETRY_EDGE_RECORD_V1_BULK", "")

      assert :ok = ConsumerReconciler.ensure_stream(conn, config, source)

      assert %{
               "config" => %{
                 "discard" => "new",
                 "max_bytes" => 512,
                 "max_age" => 0
               }
             } = api(conn, "STREAM.INFO.TELEMETRY_EDGE_RECORD_V1_BULK", "")

      first_payload = String.duplicate("a", 128)
      second_payload = String.duplicate("b", 128)
      third_payload = String.duplicate("c", 128)

      {:ok, %{body: body1}} =
        Gnat.request(conn, @source_subject, first_payload,
          headers: [{"Nats-Msg-Id", "synthetic-pub-0001"}],
          receive_timeout: 5_000
        )

      assert %{"stream" => "TELEMETRY_EDGE_RECORD_V1_BULK", "seq" => 1} = Jason.decode!(body1)

      {:ok, %{body: body2}} =
        Gnat.request(conn, @source_subject, second_payload,
          headers: [{"Nats-Msg-Id", "synthetic-pub-0002"}],
          receive_timeout: 5_000
        )

      assert %{"stream" => "TELEMETRY_EDGE_RECORD_V1_BULK", "seq" => 2} = Jason.decode!(body2)

      # Stream is now near its 512-byte cap; publishing the third record must be refused with
      # err_code 10077 (maximum bytes exceeded), never evicting seq 1 or seq 2.
      {:ok, %{body: refused_body}} =
        Gnat.request(conn, @source_subject, third_payload,
          headers: [{"Nats-Msg-Id", "synthetic-pub-0003"}],
          receive_timeout: 5_000
        )

      assert %{
               "error" => %{
                 "err_code" => 10_077,
                 "description" => "maximum bytes exceeded"
               }
             } = Jason.decode!(refused_body)

      assert %{
               "state" => %{
                 "messages" => 2,
                 "first_seq" => 1,
                 "last_seq" => 2
               }
             } = api(conn, "STREAM.INFO.TELEMETRY_EDGE_RECORD_V1_BULK", "")

      # Once EventWriter drains or space frees up (delete seq 1), the redelivered third record is stored.
      reply =
        api(
          conn,
          "STREAM.MSG.DELETE.TELEMETRY_EDGE_RECORD_V1_BULK",
          Jason.encode!(%{seq: 1})
        )

      assert reply["success"] == true

      {:ok, %{body: body3}} =
        Gnat.request(conn, @source_subject, third_payload,
          headers: [{"Nats-Msg-Id", "synthetic-pub-0003"}],
          receive_timeout: 5_000
        )

      assert %{"stream" => "TELEMETRY_EDGE_RECORD_V1_BULK", "seq" => 3} = Jason.decode!(body3)

      assert %{
               "state" => %{
                 "messages" => 2,
                 "first_seq" => 2,
                 "last_seq" => 3
               }
             } = api(conn, "STREAM.INFO.TELEMETRY_EDGE_RECORD_V1_BULK", "")
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

  defp publish!(conn) do
    {:ok, %{body: body}} =
      Gnat.request(conn, @source_subject, @record, headers: @headers, receive_timeout: 5_000)

    assert %{"stream" => "TELEMETRY_EDGE_RECORD_V1_BULK", "seq" => 1} = Jason.decode!(body)
  end

  defp publish_dlq!(conn, msg_id, failure \\ []) do
    headers =
      failure ++
        [
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

  defp dead_lettered do
    {:ok, %{contracts: contracts}} = PipelineStats.snapshot()

    case Enum.find(contracts, &(&1.contract == "unattributed")) do
      nil -> 0
      counts -> counts.dead_lettered
    end
  end
end
