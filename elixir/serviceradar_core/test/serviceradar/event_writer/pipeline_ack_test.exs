defmodule ServiceRadar.EventWriter.PipelineAckTest do
  use ExUnit.Case, async: false

  alias Broadway.Message
  alias ServiceRadar.Analytics.StarRocks.LoadSupervisor
  alias ServiceRadar.Analytics.StarRocks.StreamLoad
  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.EventWriter.Processors.AdhocScan
  alias ServiceRadar.EventWriter.Processors.Mtr
  alias ServiceRadar.NATS.PublishDeniedError

  @moduletag :db_free

  setup do
    handler_id = "pipeline-ack-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:serviceradar, :event_writer, :ack],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "ack/3 invokes ack and nack callbacks" do
    parent = self()

    ack_message = %Message{
      data: "",
      metadata: %{
        subject: "events.test",
        reply_to: "$JS.ACK.test",
        received_monotonic: System.monotonic_time()
      },
      acknowledger:
        {Pipeline, :ack_ref,
         %{
           ack_fun: fn
             :ack ->
               send(parent, :acked)
               :ok

             :nack ->
               send(parent, :nacked)
               :ok
           end
         }}
    }

    assert :ok == Pipeline.ack(:ack_ref, [ack_message], [ack_message])
    assert_receive :acked
    assert_receive :nacked

    assert_receive {:telemetry, [:serviceradar, :event_writer, :ack],
                    %{count: 1, duration: duration},
                    %{action: :ack, result: :ok, subject_class: "events"}}

    assert is_integer(duration) and duration >= 0

    assert_receive {:telemetry, [:serviceradar, :event_writer, :ack],
                    %{count: 1, duration: duration},
                    %{action: :nack, result: :ok, subject_class: "events"}}

    assert is_integer(duration) and duration >= 0
  end

  test "alert evaluation backpressure backs off and terminates at the delivery limit" do
    parent = self()

    for reason <- [:alert_evaluation_peer_not_ready, {:overloaded, :rule_bytes}],
        {delivery_count, action} <- [
          {1, {:nack, 10_000}},
          {2, {:nack, 20_000}},
          {3, {:nack, 40_000}},
          {4, {:nack, 80_000}},
          {5, :term}
        ],
        {publish_result, telemetry_result} <- [{:ok, :ok}, {{:error, :disconnected}, :error}] do
      message = %Message{
        data: "",
        status: {:failed, reason},
        metadata: %{
          subject: "signals.analytics.predictions.test",
          jetstream_ack: %{delivery_count: delivery_count},
          max_deliver: 5
        },
        acknowledger:
          {Pipeline, :ack_ref,
           %{
             ack_fun: fn received_action ->
               send(parent, {:ack_action, received_action})
               publish_result
             end
           }}
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Pipeline.ack(:ack_ref, [], [message])
        end)

      assert_receive {:ack_action, ^action}
      telemetry_action = if delivery_count == 5, do: :term, else: :nack

      assert_receive {:telemetry, [:serviceradar, :event_writer, :ack], %{count: 1},
                      %{action: ^telemetry_action, result: ^telemetry_result}}

      if delivery_count == 5 do
        assert log =~ "[error]"
        assert log =~ "terminal JetStream delivery"
      else
        refute log =~ "[error]"
      end
    end
  end

  test "ack/3 terminally acknowledges final failed JetStream delivery" do
    parent = self()
    handler_id = "pipeline-dead-letter-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:serviceradar, :event_writer, :dead_letter],
      fn event, measurements, metadata, _config ->
        send(parent, {:dead_letter_telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    failed_message =
      Message.failed(
        %Message{
          data: "",
          status: {:failed, :db_unavailable},
          metadata: %{
            subject: "signals.analytics.predictions.test",
            reply_to: "$JS.ACK.events.consumer.5.9.8.0.0",
            jetstream_ack: %{stream: "events", consumer: "consumer", delivery_count: 5},
            max_deliver: 5,
            received_monotonic: System.monotonic_time()
          },
          acknowledger:
            {Pipeline, :ack_ref,
             %{
               ack_fun: fn
                 :term ->
                   send(parent, :termed)
                   :ok

                 :nack ->
                   send(parent, :nacked)
                   :ok
               end
             }}
        },
        :db_unavailable
      )

    assert :ok == Pipeline.ack(:ack_ref, [], [failed_message])

    assert_receive :termed
    refute_receive :nacked, 50

    assert_receive {:dead_letter_telemetry, [:serviceradar, :event_writer, :dead_letter],
                    %{count: 1, delivery_count: 5, max_deliver: 5},
                    %{
                      subject_class: "analytics",
                      stream: "events",
                      consumer: "consumer",
                      reason_class: "db_unavailable"
                    }}

    assert_receive {:telemetry, [:serviceradar, :event_writer, :ack], %{count: 1},
                    %{action: :term, result: :ok, subject_class: "analytics"}}
  end

  test "ack/3 nacks failed messages before max_deliver" do
    parent = self()

    failed_message =
      Message.failed(
        %Message{
          data: "",
          status: {:failed, :transient},
          metadata: %{
            subject: "signals.analytics.predictions.test",
            reply_to: "$JS.ACK.events.consumer.4.9.8.0.0",
            jetstream_ack: %{stream: "events", consumer: "consumer", delivery_count: 4},
            max_deliver: 5
          },
          acknowledger:
            {Pipeline, :ack_ref,
             %{
               ack_fun: fn
                 :term ->
                   send(parent, :termed)
                   :ok

                 :nack ->
                   send(parent, :nacked)
                   :ok
               end
             }}
        },
        :transient
      )

    assert :ok == Pipeline.ack(:ack_ref, [], [failed_message])

    assert_receive :nacked
    refute_receive :termed, 50
  end

  describe "edge-record dead-letter" do
    @record_bytes <<0, 1, 2, 3, "synthetic record", 255>>
    @source_headers [
      {"nats-msg-id", "synthetic-publication-0001"},
      {"nats-expected-stream", "TELEMETRY_EDGE_RECORD_V1_BULK"},
      {"sr-edge-delivery-id", "synthetic-delivery-0001"},
      {"sr-edge-transport-provenance", "synthetic-provenance"}
    ]

    setup do
      parent = self()
      handler_id = "pipeline-edge-dead-letter-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:serviceradar, :event_writer, :edge_record, :dead_letter],
        fn _event, measurements, metadata, _config ->
          send(parent, {:dead_letter_event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    # A failed delivery of a record on the primary edge-record stream. `request` answers the
    # dead-letter publish; every call to it and to the ack callback is reported in order.
    defp failed_edge_record(delivery_count, dead_letter_after, max_deliver, request) do
      parent = self()

      Message.failed(
        %Message{
          data: @record_bytes,
          metadata: %{
            subject: "telemetry.edge-record.v1.bulk.p07",
            headers: @source_headers,
            jetstream_ack: %{
              stream: "TELEMETRY_EDGE_RECORD_V1_BULK",
              consumer: "synthetic-writer",
              delivery_count: delivery_count,
              stream_sequence: 41,
              timestamp: 1_700_000_000_000_000_000
            },
            max_deliver: max_deliver,
            dead_letter_after: dead_letter_after
          },
          acknowledger:
            {Pipeline, :ack_ref,
             %{
               ack_fun: fn action ->
                 send(parent, {:step, {:ack, action}})
                 :ok
               end,
               request_fun: fn subject, body, opts ->
                 send(parent, {:step, {:publish, subject, body, opts}})

                 if is_function(request, 3),
                   do: request.(subject, body, opts),
                   else: request.()
               end
             }}
        },
        %RuntimeError{message: "edge record publish failed: :timeout"}
      )
    end

    defp steps(acc \\ []) do
      receive do
        {:step, step} -> steps([step | acc])
      after
        50 -> Enum.reverse(acc)
      end
    end

    defp stored(seq),
      do: fn ->
        {:ok, %{body: ~s({"stream":"TELEMETRY_EDGE_RECORD_DLQ_V1_BULK","seq":#{seq}})}}
      end

    test "a failure before the threshold is NAKed with backoff and copies nothing" do
      for {delivery_count, dead_letter_after, max_deliver, delay} <- [
            {1, 2, -1, 10_000},
            {3, 20, 5, 40_000}
          ] do
        message = failed_edge_record(delivery_count, dead_letter_after, max_deliver, stored(1))
        assert :ok = Pipeline.ack(:ack_ref, [], [message])
        assert steps() == [{:ack, {:nack, delay}}]
      end

      refute_received {:dead_letter_event, _, _}
    end

    test "at the threshold the record is copied with its failure and ACKed only after the PubAck" do
      # The stream's own threshold, and max_deliver - 1 when the consumer's limit is lower.
      for {delivery_count, dead_letter_after, max_deliver} <- [{2, 2, -1}, {4, 20, 5}] do
        message = failed_edge_record(delivery_count, dead_letter_after, max_deliver, stored(9))

        log = ExUnit.CaptureLog.capture_log(fn -> Pipeline.ack(:ack_ref, [], [message]) end)

        assert [{:publish, subject, body, opts}, {:ack, :ack}] = steps()
        assert subject == "telemetry.edge-record-dlq.v1.bulk.p07.unknown.v0"
        assert body == @record_bytes

        headers = Map.new(opts[:headers])
        # Keyed on the source delivery, so a copy after a replay is not deduplicated against
        # one the replay deleted; the record's own id travels in a failure header.
        assert headers["Nats-Msg-Id"] == "edge-dlq:TELEMETRY_EDGE_RECORD_V1_BULK:41"
        assert headers["Sr-Edge-Dlq-Source-Msg-Id"] == "synthetic-publication-0001"
        refute Map.has_key?(headers, "nats-msg-id")
        assert headers["Nats-Expected-Stream"] == "TELEMETRY_EDGE_RECORD_DLQ_V1_BULK"
        refute Map.has_key?(headers, "nats-expected-stream")
        assert headers["sr-edge-delivery-id"] == "synthetic-delivery-0001"
        assert headers["sr-edge-transport-provenance"] == "synthetic-provenance"
        assert headers["Sr-Edge-Dlq-Source-Subject"] == "telemetry.edge-record.v1.bulk.p07"
        assert headers["Sr-Edge-Dlq-Source-Stream"] == "TELEMETRY_EDGE_RECORD_V1_BULK"
        assert headers["Sr-Edge-Dlq-Source-Sequence"] == "41"
        assert headers["Sr-Edge-Dlq-Stored-At"] == "2023-11-14T22:13:20.000000Z"
        assert headers["Sr-Edge-Dlq-Attempts"] == Integer.to_string(delivery_count)
        assert headers["Sr-Edge-Dlq-Reason"] == "RuntimeError"
        assert headers["Sr-Edge-Dlq-Reason-Detail"] == "edge record publish failed: :timeout"
        assert {:ok, _, _} = DateTime.from_iso8601(headers["Sr-Edge-Dlq-Last-Failed-At"])

        assert_received {:dead_letter_event, %{count: 1, attempts: ^delivery_count},
                         %{
                           contract: "undecodable",
                           reason_class: "RuntimeError",
                           result: "stored"
                         }}

        assert log =~ "Edge record dead-lettered:"
        assert log =~ "dlq_sequence=9"
        assert log =~ "source_sequence=41"
      end
    end

    # Redelivery cannot succeed until the broker's grant changes. A failure that may clear at
    # the same delivery count is NAKed: the first test in this block.
    test "a republish the broker denied is dead-lettered on its first delivery" do
      message =
        1
        |> failed_edge_record(20, -1, stored(3))
        |> Message.failed(%PublishDeniedError{subject: "metrics.sysmon.cpu.usage"})

      log = ExUnit.CaptureLog.capture_log(fn -> Pipeline.ack(:ack_ref, [], [message]) end)

      assert [
               {:publish, "telemetry.edge-record-dlq.v1.bulk.p07.unknown.v0", @record_bytes,
                opts},
               {:ack, :ack}
             ] = steps()

      assert header(opts, "Sr-Edge-Dlq-Reason") == "PublishDeniedError"
      assert header(opts, "Sr-Edge-Dlq-Attempts") == "1"

      assert_received {:dead_letter_event, %{count: 1, attempts: 1},
                       %{reason_class: "PublishDeniedError", result: "stored"}}

      # The broker's denial is logged once per subject, so its records are not each an error.
      refute log =~ ~r/\[error\][^\n]*Edge record dead-lettered/
    end

    test "a dead-letter that is not stored leaves the source unacknowledged and NAKs it" do
      for request <- [
            fn -> {:error, :timeout} end,
            fn ->
              {:ok,
               %{
                 body:
                   ~s({"error":{"code":503,"err_code":10077,"description":"maximum bytes exceeded"}})
               }}
            end,
            fn -> exit(:noproc) end
          ] do
        message = failed_edge_record(2, 2, -1, request)

        log = ExUnit.CaptureLog.capture_log(fn -> Pipeline.ack(:ack_ref, [], [message]) end)

        assert [{:publish, _subject, @record_bytes, _opts}, {:ack, {:nack, 20_000}}] = steps()

        assert_received {:dead_letter_event, %{count: 1},
                         %{contract: "undecodable", result: "failed"}}

        assert log =~ "the source delivery stays unacknowledged"
      end
    end

    test "a duplicate PubAck ACKs the source without a lookup and counts a duplicate" do
      duplicate = fn ->
        {:ok,
         %{body: ~s({"stream":"TELEMETRY_EDGE_RECORD_DLQ_V1_BULK","seq":9,"duplicate":true})}}
      end

      message = failed_edge_record(2, 2, -1, duplicate)

      log = ExUnit.CaptureLog.capture_log(fn -> Pipeline.ack(:ack_ref, [], [message]) end)

      assert [
               {:publish, "telemetry.edge-record-dlq.v1.bulk.p07.unknown.v0", @record_bytes,
                opts},
               {:ack, :ack}
             ] = steps()

      assert header(opts, "Nats-Msg-Id") == "edge-dlq:TELEMETRY_EDGE_RECORD_V1_BULK:41"

      assert_received {:dead_letter_event, %{count: 1},
                       %{contract: "undecodable", result: "duplicate"}}

      refute_received {:dead_letter_event, _, %{result: "failed"}}
      assert log =~ "Edge record already dead-lettered"
      assert log =~ "dlq_sequence=9"
      refute log =~ "stays unacknowledged"
    end

    test "a non-ASCII failure detail is bounded to 256 bytes at a character boundary" do
      message =
        2
        |> failed_edge_record(2, -1, stored(9))
        |> Message.failed(%RuntimeError{message: String.duplicate("é", 200)})

      ExUnit.CaptureLog.capture_log(fn -> Pipeline.ack(:ack_ref, [], [message]) end)

      assert [{:publish, _, _, opts}, {:ack, :ack}] = steps()
      detail = header(opts, "Sr-Edge-Dlq-Reason-Detail")
      assert byte_size(detail) <= 256
      assert String.valid?(detail)
      assert detail == String.duplicate("é", 126) <> "..."
    end
  end

  test "a full first-failure log evicts the earliest entry only to record a new delivery" do
    alias ServiceRadar.EventWriter.EdgeRecordDeadLetter.FailureLog

    start_supervised!(FailureLog)
    now = 1_800_000_000_000

    for seq <- 1..50_000, do: FailureLog.note({"S", seq}, now - 100_000 + rem(seq * 7, 50_000))
    assert :ets.info(FailureLog, :size) == 50_000

    earliest = 50_000
    assert FailureLog.first({"S", earliest}) == now - 100_000

    FailureLog.note({"S", 1}, now)
    assert :ets.info(FailureLog, :size) == 50_000
    assert FailureLog.first({"S", earliest}) == now - 100_000
    assert FailureLog.first({"S", 1}) == now - 100_000 + 7

    FailureLog.note({"S", :new}, now)
    assert :ets.info(FailureLog, :size) == 50_000
    assert FailureLog.first({"S", :new}) == now
    assert FailureLog.first({"S", earliest}) == nil

    FailureLog.forget({"S", :new})
    FailureLog.note({"S", :newer}, now + 1)
    assert FailureLog.first({"S", :newer}) == now + 1
    assert :ets.info(FailureLog, :size) == 50_000
  end

  defp header(opts, name), do: opts |> Keyword.fetch!(:headers) |> Map.new() |> Map.fetch!(name)

  test "ack/3 does not crash when ack callback exits" do
    message = %Message{
      data: "",
      metadata: %{subject: "falco.test", reply_to: "$JS.ACK.falco"},
      acknowledger:
        {Pipeline, :ack_ref,
         %{
           ack_fun: fn _action ->
             exit(:noprocess)
           end
         }}
    }

    assert :ok == Pipeline.ack(:ack_ref, [message], [message])

    assert_receive {:telemetry, [:serviceradar, :event_writer, :ack], %{count: 1},
                    %{action: :ack, result: :error, subject_class: "falco"}}

    assert_receive {:telemetry, [:serviceradar, :event_writer, :ack], %{count: 1},
                    %{action: :nack, result: :error, subject_class: "falco"}}
  end

  # A stream whose subject has no routing rule still gets a consumer, so its
  # messages arrive, fall through to the Default processor, and are acked and
  # dropped without an error anywhere. MTR and ad-hoc scan results shipped that
  # way.
  test "every default stream's subject reaches the processor its stream declares" do
    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      streams: Config.default_streams()
    }

    batchers = Pipeline.configured_batcher_names(config)

    for stream <- Config.default_streams(), not Config.flow_stream?(stream) do
      subject = String.replace(stream.subject, [">", "*"], "example")

      message = %Message{
        data: "",
        metadata: %{subject: subject},
        acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
      }

      %Message{batcher: batcher} = Pipeline.handle_message(:default, message, %{})

      assert batcher in batchers, "#{stream.name}: #{subject} routes to undeclared #{batcher}"

      assert Pipeline.processor_for_batcher(batcher) == stream.processor,
             "#{stream.name}: #{subject} runs #{inspect(Pipeline.processor_for_batcher(batcher))}"
    end
  end

  test "routes MTR and ad-hoc scan results to their own batchers" do
    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      streams: Config.default_streams()
    }

    routes = [
      {"mtr.results.ingest", :mtr_results, Mtr},
      {"scans.results.run01", :scan_results, AdhocScan}
    ]

    for {subject, batcher, processor} <- routes do
      message = %Message{
        data: "",
        metadata: %{subject: subject},
        acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
      }

      assert batcher in Pipeline.configured_batcher_names(config)
      assert %Message{batcher: ^batcher} = Pipeline.handle_message(:default, message, %{})
      assert Pipeline.processor_for_batcher(batcher) == processor
    end
  end

  test "routes metrics subjects to the declared metrics batcher" do
    message = %Message{
      data: <<10, 22, "serviceradar.metric.v1">>,
      metadata: %{subject: "metrics.sysmon.cpu"},
      acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
    }

    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      streams: Config.default_streams()
    }

    assert :metrics in Pipeline.configured_batcher_names(config)

    assert %Message{batcher: :metrics, metadata: %{base_subject: "metrics.sysmon.cpu"}} =
             Pipeline.handle_message(:default, message, %{})
  end

  test "routes analytics prediction subjects to the declared, configured batcher" do
    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      streams: Config.default_streams()
    }

    # The ANALYTICS_PREDICTIONS stream builds the `:analytics_predictions` batcher, so the
    # subject router must emit that same atom — otherwise Broadway dispatches to an unknown
    # batcher and crashes. Guards against the stale `:causal_predictions` routing name.
    assert :analytics_predictions in Pipeline.configured_batcher_names(config)

    message = %Message{
      data: Jason.encode!(%{"signal_type" => "prediction"}),
      metadata: %{subject: "signals.analytics.predictions.cpu-series"},
      acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
    }

    assert %Message{
             batcher: :analytics_predictions,
             metadata: %{base_subject: "signals.analytics.predictions.cpu-series"}
           } = Pipeline.handle_message(:default, message, %{})

    # The generic `signals.analytics.*` catch-all shares the (configured) bmp batcher.
    overlay = %Message{
      data: Jason.encode!(%{"signal_type" => "analytics"}),
      metadata: %{subject: "signals.analytics.overlay"},
      acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
    }

    assert :bmp_causal in Pipeline.configured_batcher_names(config)

    assert %Message{batcher: :bmp_causal, metadata: %{base_subject: "signals.analytics.overlay"}} =
             Pipeline.handle_message(:default, overlay, %{})
  end

  test "routes processed logs to the declared logs batcher" do
    message = %Message{
      data: Jason.encode!(%{"message" => "internal audit event"}),
      metadata: %{subject: "logs.internal.processed.audit"},
      acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
    }

    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      streams: Config.default_streams()
    }

    assert :logs in Pipeline.configured_batcher_names(config)

    assert %Message{batcher: :logs, metadata: %{base_subject: "logs.internal.processed.audit"}} =
             Pipeline.handle_message(:default, message, %{})
  end

  test "routes PowerDNS OCSF to the declared pdns batcher" do
    message = %Message{
      data: Jason.encode!(%{"class_uid" => 4003}),
      metadata: %{subject: "pdns.ocsf"},
      acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
    }

    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      streams: Config.default_streams()
    }

    assert :pdns_ocsf in Pipeline.configured_batcher_names(config)

    assert %Message{batcher: :pdns_ocsf, metadata: %{base_subject: "pdns.ocsf"}} =
             Pipeline.handle_message(:default, message, %{})
  end

  test "routes raw Zen log subjects to the declared logs batcher" do
    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      streams: Config.default_streams()
    }

    assert :logs in Pipeline.configured_batcher_names(config)

    for subject <- ["logs.syslog", "logs.snmp", "logs.otel"] do
      message = %Message{
        data: Jason.encode!(%{"body" => "test"}),
        metadata: %{subject: subject},
        acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
      }

      assert %Message{batcher: :logs, metadata: %{base_subject: ^subject}} =
               Pipeline.handle_message(:default, message, %{})
    end
  end

  test "events.flow.attribution uses the flow_attribution batcher even without a dedicated stream" do
    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      streams: [
        %{
          name: "EVENTS",
          stream_name: "events",
          subject: "events.>",
          processor: ServiceRadar.EventWriter.Processors.Events
        }
      ]
    }

    assert :flow_attribution in Pipeline.configured_batcher_names(config)

    message = %Message{
      data: ~s({"id":"flow-alpha-0001","attribution_version":1}),
      metadata: %{subject: "events.flow.attribution"},
      acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
    }

    assert %Message{batcher: :flow_attribution} = Pipeline.handle_message(:default, message, %{})
  end

  test "does not declare a flow.attributed read-back batcher" do
    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "test-consumer",
      streams: Config.default_streams()
    }

    refute :attributed_flow in Pipeline.configured_batcher_names(config)

    message = %Message{
      data: "",
      metadata: %{subject: "flow.attributed.default"},
      acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
    }

    assert %Message{batcher: :default} = Pipeline.handle_message(:default, message, %{})
  end

  test "flow pipeline configures :flows_raw batcher for all raw-flow streams" do
    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 500,
      consumer_name: "test-consumer",
      streams: [
        %{name: "SFLOW_RAW", stream_name: "flows", subject: "flows.raw.sflow"},
        %{name: "NETFLOW_RAW", stream_name: "flows", subject: "flows.raw.netflow"},
        %{name: "FLOW_RAW_IPFIX", stream_name: "flows", subject: "flows.raw.ipfix"},
        %{
          name: "NETFLOW_RAW_EVENTS_DRAIN",
          stream_name: "events",
          subject: "flows.raw.netflow",
          durable_source_name: "NETFLOW_RAW"
        }
      ]
    }

    names = Pipeline.configured_batcher_names(config)
    assert :flows_raw in names
    refute :sflow_raw in names
    refute :netflow_raw in names
    refute :flow_raw_ipfix in names

    message = %Message{
      data: "{}",
      metadata: %{subject: "flows.raw.netflow"},
      acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
    }

    assert %Message{batcher: :flows_raw} = Pipeline.handle_message(:default, message, %{})
  end

  # Streams that share a batcher share one pipeline, or each pipeline would feed its own copy of
  # that batcher; every other stream gets a demand domain of its own.
  test "consumer pipelines group the streams that share a batcher and split the processors" do
    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 500,
      consumer_name: "test-consumer",
      processor_concurrency: 10,
      streams: [
        %{name: "NETFLOW_RAW", stream_name: "flows", subject: "flows.raw.netflow"},
        %{
          name: "FLOW_ATTRIBUTION_OBSERVATIONS",
          stream_name: "flows",
          subject: "flows.attribution.observations"
        },
        %{
          name: "NETFLOW_RAW_EVENTS_DRAIN",
          stream_name: "events",
          subject: "flows.raw.netflow",
          durable_source_name: "NETFLOW_RAW"
        },
        %{name: "SFLOW_RAW", stream_name: "flows", subject: "flows.raw.sflow"}
      ]
    }

    groups = Pipeline.consumer_pipelines(config, ServiceRadar.EventWriter.FlowPipeline)

    assert [
             {ServiceRadar.EventWriter.FlowPipeline.FlowsRaw, raw},
             {ServiceRadar.EventWriter.FlowPipeline.FlowAttributionObservations, observations}
           ] = groups

    assert Enum.map(raw.streams, & &1.name) == [
             "NETFLOW_RAW",
             "NETFLOW_RAW_EVENTS_DRAIN",
             "SFLOW_RAW"
           ]

    assert Enum.map(observations.streams, & &1.name) == ["FLOW_ATTRIBUTION_OBSERVATIONS"]
    assert raw.processor_concurrency == 5
    assert observations.processor_concurrency == 5
  end

  # A subject without a routing rule falls to :default, whose processor acks and
  # drops it: observations would never reach the warehouse.
  test "flow pipeline routes attribution observations to their own processor" do
    config = %Config{
      enabled: true,
      nats: %{},
      batch_size: 100,
      batch_timeout: 500,
      consumer_name: "test-consumer",
      streams: [
        %{name: "NETFLOW_RAW", stream_name: "flows", subject: "flows.raw.netflow"},
        %{
          name: "FLOW_ATTRIBUTION_OBSERVATIONS",
          stream_name: "flows",
          subject: "flows.attribution.observations"
        }
      ]
    }

    assert :flow_attribution_observations in Pipeline.configured_batcher_names(config)

    message = %Message{
      data: "{}",
      metadata: %{subject: "flows.attribution.observations"},
      acknowledger: {Pipeline, :ack_ref, %{ack_fun: fn _ -> :ok end}}
    }

    assert %Message{batcher: :flow_attribution_observations} =
             Pipeline.handle_message(:default, message, %{})

    assert Pipeline.processor_for_batcher(:flow_attribution_observations) ==
             ServiceRadar.EventWriter.Processors.FlowAttributionObservations
  end

  test "the running OTel topology coalesces sparse spans, splits loads and ACKs after HTTP completion" do
    starrocks = ServiceRadar.Analytics.StarRocks
    previous = Application.get_env(:serviceradar_core, starrocks, [])
    on_exit(fn -> Application.put_env(:serviceradar_core, starrocks, previous) end)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()
    start_supervised!({Task, fn -> serve_loads(listener, parent) end})
    start_supervised!(LoadSupervisor)

    Application.put_env(:serviceradar_core, starrocks,
      enabled: true,
      fe_http: "http://127.0.0.1:#{port}",
      stream_load: [max_age_ms: 200, max_rows: 2]
    )

    config = %Config{
      enabled: true,
      producer_name: __MODULE__.Producer,
      nats: %{
        host: "127.0.0.1",
        port: 1,
        jwt: "synthetic-token",
        nkey_seed: nil,
        user: nil,
        password: nil,
        tls: false
      },
      batch_size: 100,
      batch_timeout: 1_000,
      max_ack_pending: 8,
      consumer_name: "synthetic-warehouse",
      streams: Config.default_streams()
    }

    start_supervised!({Pipeline, {config, [name: __MODULE__.Topology]}})

    spans =
      for n <- 1..3 do
        Jason.encode!(%{
          "timestamp" => "2000-01-01T00:00:00Z",
          "trace_id" => "00000000000000000000000000000001",
          "span_id" => n |> Integer.to_string(16) |> String.pad_leading(16, "0"),
          "name" => "synthetic"
        })
      end

    ref =
      Broadway.test_batch(__MODULE__.Topology, spans,
        metadata: %{subject: "otel.traces.synthetic"},
        batch_mode: :bulk
      )

    refute_receive {:warehouse_rows, _, _}, 75
    assert_receive {:warehouse_rows, first_http, first_rows}, 650
    assert_receive {:warehouse_rows, second_http, second_rows}, 650
    assert Enum.sort([length(first_rows), length(second_rows)]) == [1, 2]

    assert (first_rows ++ second_rows) |> Enum.map(& &1["span_id"]) |> Enum.sort() ==
             ["0000000000000001", "0000000000000002", "0000000000000003"]

    refute_receive {:ack, ^ref, _, _}, 50
    send(first_http, :commit)
    send(second_http, :commit)
    assert_receive {:ack, ^ref, successful, []}, 1_000
    assert length(successful) == 3

    # Sparse idle traffic must also flush at maxAge, independently of maxRows.
    idle =
      Broadway.test_batch(__MODULE__.Topology, [hd(spans)],
        metadata: %{subject: "otel.traces.synthetic"},
        batch_mode: :bulk
      )

    assert_receive {:warehouse_rows, idle_http, [_]}, 650
    send(idle_http, :commit)
    assert_receive {:ack, ^idle, [_], []}, 1_000
  end

  test "caller cancellation closes the default HTTP request and releases admission" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()
    start_supervised!({Task, fn -> serve_loads(listener, parent) end})
    start_supervised!({LoadSupervisor, max_in_flight: 1})
    config = %{fe_http: "http://127.0.0.1:#{port}"}
    rows = [%{"id" => "synthetic-cancellation"}]
    caller = spawn(fn -> StreamLoad.persist("logs", rows, config: config) end)
    assert_receive {:warehouse_rows, http, ^rows}, 1_000
    send(http, :observe_close)
    Process.exit(caller, :kill)
    assert_receive :load_connection_closed, 1_000

    next = Task.async(fn -> StreamLoad.persist("logs", rows, config: config) end)
    assert_receive {:warehouse_rows, next_http, ^rows}, 1_000
    send(next_http, :commit)
    assert {:ok, %{loaded: 1}} = Task.await(next)
  end

  defp serve_loads(listener, parent) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        # Accept the next chunk while this one is waiting for durable commit.
        Task.start_link(fn -> answer_load(socket, parent) end)
        serve_loads(listener, parent)

      {:error, :closed} ->
        :ok
    end
  end

  defp answer_load(socket, parent) do
    {:ok, _request_line} = :gen_tcp.recv(socket, 0, 5_000)
    bytes = load_headers(socket, 0)
    :ok = :gen_tcp.send(socket, "HTTP/1.1 100 Continue\r\n\r\n")
    :ok = :inet.setopts(socket, packet: :raw)
    {:ok, body} = :gen_tcp.recv(socket, bytes, 5_000)
    rows = Jason.decode!(body)
    send(parent, {:warehouse_rows, self(), rows})

    receive do
      :observe_close ->
        {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
        send(parent, :load_connection_closed)

      :commit ->
        response =
          Jason.encode!(%{
            "Status" => "Success",
            "NumberLoadedRows" => length(rows),
            "NumberFilteredRows" => 0
          })

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
            Integer.to_string(byte_size(response)),
            "\r\n\r\n",
            response
          ])
    after
      5_000 -> raise "synthetic HTTP load was never committed"
    end

    :gen_tcp.close(socket)
  end

  defp load_headers(socket, bytes) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)

    case String.split(String.trim(line), ":", parts: 2) do
      [""] ->
        bytes

      [key, value] ->
        if String.downcase(key) == "content-length",
          do: load_headers(socket, value |> String.trim() |> String.to_integer()),
          else: load_headers(socket, bytes)
    end
  end

  describe "warehouse batch sizing" do
    @batchers [
      metrics: [batch_size: 100, batch_timeout: 1_000],
      falco: [batch_size: 100, batch_timeout: 1_000],
      otel_traces: [batch_size: 100, batch_timeout: 1_000],
      otel_metrics: [batch_size: 100, batch_timeout: 1_000],
      logs: [batch_size: 500, batch_timeout: 10_000]
    ]

    @metrics_batchers [metrics: [batch_size: 500, batch_timeout: 500]]

    @sizing %{
      max_ack_pending: 256,
      max_age_ms: 2_000,
      max_rows: 50_000,
      max_bytes: 1,
      max_in_flight: 4
    }

    test "without the warehouse the batchers are left as configured" do
      assert Pipeline.size_warehouse_batchers(@batchers, %Config{streams: []}, nil) == @batchers
    end

    test "warehouse batchers flush on the load max age and fill to half of max_ack_pending" do
      sized = Pipeline.size_warehouse_batchers(@batchers, %Config{streams: []}, @sizing)

      assert sized[:metrics] == [batch_size: 128, batch_timeout: 2_000]
      assert sized[:falco] == [batch_size: 128, batch_timeout: 2_000]
      assert sized[:otel_traces] == [batch_size: 128, batch_timeout: 2_000]
      assert sized[:otel_metrics] == [batch_size: 128, batch_timeout: 2_000]
      # The maximum age also caps a longer CNPG timeout.
      assert sized[:logs] == [batch_size: 128, batch_timeout: 2_000]
    end

    test "a configured batch size the consumer cannot deliver is capped" do
      sized = Pipeline.size_warehouse_batchers(@metrics_batchers, %Config{streams: []}, @sizing)

      assert sized[:metrics] == [batch_size: 128, batch_timeout: 2_000]
    end

    test "batch size is left as configured when max_ack_pending is unknown" do
      sizing = %{@sizing | max_ack_pending: nil}
      sized = Pipeline.size_warehouse_batchers(@metrics_batchers, %Config{streams: []}, sizing)

      assert sized[:metrics] == [batch_size: 500, batch_timeout: 2_000]
    end

    test "a stream's own max_ack_pending bounds its batcher" do
      config = %Config{
        streams: [
          %{
            name: "METRICS",
            subject: "metrics.>",
            processor: nil,
            consumer_max_ack_pending: 2_048
          }
        ]
      }

      sized = Pipeline.size_warehouse_batchers(@batchers, config, @sizing)

      assert sized[:metrics][:batch_size] == 1_024
      assert sized[:falco][:batch_size] == 128
    end
  end
end
