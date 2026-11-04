defmodule ServiceRadar.EventWriter.ConsumerLagReporterTest do
  use ExUnit.Case, async: true

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
end
