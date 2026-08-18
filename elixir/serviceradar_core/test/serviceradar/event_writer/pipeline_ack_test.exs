defmodule ServiceRadar.EventWriter.PipelineAckTest do
  use ExUnit.Case, async: true

  alias Broadway.Message
  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Pipeline

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
end
