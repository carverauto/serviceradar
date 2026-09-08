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

  test "retention stream INFO polling is limited to unique flow streams" do
    consumers = [
      %{stream: "flows", durable: "netflow", subject_class: "flows"},
      %{stream: "flows", durable: "sflow", subject_class: "flows"},
      %{stream: "events", durable: "netflow-drain", subject_class: "flows"},
      %{stream: "events", durable: "otel", subject_class: "otel_metrics"}
    ]

    assert ConsumerLagReporter.retention_stream_names(consumers) == ["flows", "events"]
  end
end
