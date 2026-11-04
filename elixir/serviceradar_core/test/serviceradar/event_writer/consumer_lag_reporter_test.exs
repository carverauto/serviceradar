defmodule ServiceRadar.EventWriter.ConsumerLagReporterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.ConsumerLagReporter

  test "builds one bounded consumer reference per configured stream" do
    config = %Config{
      enabled: true,
      nats: %{host: "localhost", port: 4222, tls: false},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "serviceradar-event-writer",
      producer_name: nil,
      streams: [
        %{
          name: "METRICS",
          stream_name: "metrics",
          subject: "metrics.>",
          processor: ServiceRadar.EventWriter.Processors.Metrics
        },
        %{
          name: "OTEL_METRICS",
          stream_name: "events",
          subject: "otel.metrics.>",
          processor: ServiceRadar.EventWriter.Processors.OtelMetrics
        }
      ],
      consumer_pull_batch_size: 16,
      max_ack_pending: 256,
      processor_concurrency: 10,
      ack_wait_ns: 120_000_000_000,
      max_deliver: 5,
      consumer_lag_poll_interval_ms: 30_000
    }

    assert ConsumerLagReporter.consumer_refs(config) == [
             %{
               stream: "metrics",
               durable: "serviceradar-event-writer-metrics",
               subject_class: "metrics"
             },
             %{
               stream: "events",
               durable: "serviceradar-event-writer-otel-metrics",
               subject_class: "otel_metrics"
             }
           ]
  end

  test "drain streams poll the legacy durable_source_name" do
    config = %Config{
      enabled: true,
      nats: %{host: "localhost", port: 4222, tls: false},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "serviceradar-event-writer",
      producer_name: nil,
      streams: [
        %{
          name: "NETFLOW_RAW_EVENTS_DRAIN",
          stream_name: "events",
          subject: "flows.raw.netflow",
          durable_source_name: "NETFLOW_RAW",
          processor: ServiceRadar.EventWriter.Processors.Flows
        }
      ],
      consumer_pull_batch_size: 16,
      max_ack_pending: 256,
      processor_concurrency: 10,
      ack_wait_ns: 120_000_000_000,
      max_deliver: 5,
      consumer_lag_poll_interval_ms: 30_000
    }

    assert ConsumerLagReporter.consumer_refs(config) == [
             %{
               stream: "events",
               durable: "serviceradar-event-writer-netflow-raw",
               subject_class: "flows"
             }
           ]
  end

  # Every consumer's stream is polled once: its first sequence is what shows a durable losing
  # messages before delivery, whatever the durable consumes.
  test "stream INFO is polled once for each stream any consumer reads" do
    consumers = [
      %{stream: "flows", durable: "netflow", subject_class: "flows"},
      %{stream: "flows", durable: "sflow", subject_class: "flows"},
      %{stream: "events", durable: "netflow-drain", subject_class: "flows"},
      %{stream: "events", durable: "otel", subject_class: "otel_metrics"},
      %{stream: "metrics", durable: "metrics", subject_class: "metrics"}
    ]

    assert ConsumerLagReporter.polled_stream_names(consumers) == ["flows", "events", "metrics"]
  end

  # The security-quarantine alert reads this stream's retained bytes, and its consumer only reports,
  # so stream INFO is the only place its depth appears.
  test "stream INFO polling covers every configured edge-record route" do
    config = %Config{
      enabled: true,
      nats: %{host: "localhost", port: 4222, tls: false},
      batch_size: 100,
      batch_timeout: 1_000,
      consumer_name: "serviceradar-event-writer",
      producer_name: nil,
      streams: [
        Config.edge_record_stream(),
        Config.edge_record_audit_stream(),
        Config.edge_record_security_quarantine_stream(),
        Config.edge_record_dead_letter_stream()
      ]
    }

    consumers = ConsumerLagReporter.consumer_refs(config)

    assert Enum.map(consumers, & &1.subject_class) == [
             "edge_record",
             "edge_record_audit",
             "edge_record_quarantine",
             "edge_record_dlq"
           ]

    assert ConsumerLagReporter.polled_stream_names(consumers) == [
             "TELEMETRY_EDGE_RECORD_V1_BULK",
             "TELEMETRY_EDGE_RECORD_AUDIT_V1_BULK",
             "TELEMETRY_EDGE_RECORD_SECURITY_QUARANTINE_V1_BULK",
             "TELEMETRY_EDGE_RECORD_DLQ_V1_BULK"
           ]
  end

  # The events drain reuses the live raw-flow durable name on another stream. A trailing live
  # durable is logged once while its caught-up drain namesake is polled beside it every interval.
  test "a durable losing messages is logged once although a drain on another stream shares its name" do
    durable = "durable-#{System.unique_integer([:positive])}"
    live = %{stream: "flows", durable: durable, subject_class: "flows"}
    drain = %{stream: "events", durable: durable, subject_class: "flows"}

    stream_info = %{
      "flows" => %{config: %{}, state: %{first_seq: 151, messages: 50}},
      "events" => %{config: %{}, state: %{first_seq: 10, messages: 50}}
    }

    trailing = %{num_pending: 40, delivered: %{stream_seq: 100}}
    caught_up = %{num_pending: 0, delivered: %{stream_seq: 200}}

    log =
      capture_log([level: :info], fn ->
        Enum.reduce(1..3, %ConsumerLagReporter{}, fn _poll, state ->
          state
          |> ConsumerLagReporter.report_consumer(live, trailing, stream_info)
          |> ConsumerLagReporter.report_consumer(drain, caught_up, stream_info)
        end)
      end)

    assert length(String.split(log, "durable is losing messages")) == 2
    refute log =~ "no longer trails"
  end

  # A MaxAge stream's oldest message stays near MaxAge, so its age says nothing about risk for a
  # class outside the retention poll; one in-flight ack must not read as critical. Its first
  # sequence still reports loss.
  test "stream age feeds retention risk only for flow and edge-record classes" do
    attach_consumer_state()
    now = DateTime.utc_now()

    stream_info = %{
      "metrics" => %{
        config: %{max_bytes: -1, max_age: 1_800_000_000_000},
        state: %{
          bytes: 1_000,
          messages: 500,
          first_seq: 51,
          first_ts: DateTime.shift(now, second: -1_790)
        }
      }
    }

    info = %{num_pending: 0, num_ack_pending: 1, delivered: %{stream_seq: 600}}
    trailing = %{num_pending: 5, num_ack_pending: 0, delivered: %{stream_seq: 20}}

    for {class, info, risk, available, expired} <- [
          {"metrics", info, 0, 0, 0},
          {"metrics", trailing, 0, 0, 30},
          {"flows", info, 2, 1, 0}
        ] do
      durable = "durable-#{System.unique_integer([:positive])}"
      consumer = %{stream: "metrics", durable: durable, subject_class: class}

      ConsumerLagReporter.report_consumer(%ConsumerLagReporter{}, consumer, info, stream_info)

      assert_receive {:consumer_state,
                      %{
                        retention_risk_level: ^risk,
                        stream_info_available: ^available,
                        expired_before_delivery: ^expired
                      }, %{durable: ^durable}}
    end
  end

  defp attach_consumer_state do
    handler_id = "consumer-lag-reporter-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:serviceradar, :event_writer, :consumer, :state],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:consumer_state, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
