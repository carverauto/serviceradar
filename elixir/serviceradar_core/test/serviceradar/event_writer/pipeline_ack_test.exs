defmodule ServiceRadar.EventWriter.PipelineAckTest do
  use ExUnit.Case, async: true

  alias Broadway.Message
  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Pipeline

  setup do
    handler_id = "pipeline-ack-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:serviceradar, :event_writer, :ack],
        [:serviceradar, :event_writer, :consumer, :max_deliver_exhausted]
      ],
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

  test "ack/3 emits an alert before NAKing a final JetStream delivery" do
    parent = self()

    message = %Message{
      data: "",
      metadata: %{
        subject: "signals.causal.predictions",
        reply_to: "$JS.ACK.CAUSAL_PREDICTIONS.event_writer.5.42.9.0.0",
        received_monotonic: System.monotonic_time()
      },
      acknowledger:
        {Pipeline, :ack_ref,
         %{
           max_deliver: 5,
           jetstream_ack: %{
             stream: "CAUSAL_PREDICTIONS",
             consumer: "event_writer",
             delivery_count: 5,
             stream_sequence: 42,
             consumer_sequence: 9,
             pending: 0
           },
           ack_fun: fn
             :nack ->
               send(parent, :nacked_final_delivery)
               :ok

             :ack ->
               :ok
           end
         }}
    }

    assert :ok == Pipeline.ack(:ack_ref, [], [message])

    assert_receive {:telemetry, [:serviceradar, :event_writer, :consumer, :max_deliver_exhausted],
                    %{
                      count: 1,
                      delivery_count: 5,
                      max_deliver: 5,
                      stream_sequence: 42,
                      consumer_sequence: 9,
                      pending_messages: 0
                    },
                    %{
                      stream: "CAUSAL_PREDICTIONS",
                      durable: "event_writer",
                      subject_class: "other"
                    }}

    assert_receive :nacked_final_delivery
  end

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
end
