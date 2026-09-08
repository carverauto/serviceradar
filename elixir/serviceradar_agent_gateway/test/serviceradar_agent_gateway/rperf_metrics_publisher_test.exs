defmodule ServiceRadarAgentGateway.RperfMetricsPublisherTest do
  use ExUnit.Case, async: false

  import ServiceRadarAgentGateway.MetricsPublisherTestHelpers

  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias ServiceRadarAgentGateway.RperfMetricsPublisher

  setup do
    previous_config = Application.get_env(:serviceradar_agent_gateway, :rperf_metrics_publisher)
    previous_pid = Application.get_env(:serviceradar_agent_gateway, :rperf_metrics_publisher_test_pid)

    on_exit(fn ->
      restore_env(:rperf_metrics_publisher, previous_config)
      restore_env(:rperf_metrics_publisher_test_pid, previous_pid)
    end)

    Application.put_env(:serviceradar_agent_gateway, :rperf_metrics_publisher_test_pid, self())

    :ok
  end

  test "publishes protobuf rperf metric batch with gateway-attested identity" do
    Application.put_env(:serviceradar_agent_gateway, :rperf_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.rperf",
      connection: __MODULE__.ConnectionStub
    )

    payload = metric_batch_payload()

    assert :ok = RperfMetricsPublisher.publish_rperf(rperf_status(payload))

    assert_receive {:published, "metrics.rperf.rperf.rperf_bits_per_second", published_payload, opts}

    decoded = MetricBatch.decode(published_payload)
    metric = hd(decoded.metrics)
    point = hd(metric.points)

    assert published_payload != payload
    assert decoded.schema_version == "serviceradar.metric.v1"

    assert Map.take(decoded.resource, [:agent_id, :gateway_id, :partition, :service_name, :service_type]) == %{
             agent_id: "agent-1",
             gateway_id: "gateway-1",
             partition: "default",
             service_name: "rperf",
             service_type: "rperf"
           }

    assert Map.take(decoded.ingest_identity, [:source, :payload_kind, :producer_id, :producer_kind, :attested_by]) == %{
             source: "rperf-metrics",
             payload_kind: "serviceradar.metric.v1",
             producer_id: "agent-1",
             producer_kind: "rperf-checker",
             attested_by: "gateway-1"
           }

    assert decoded.ingress_id =~ uuidv8_pattern()
    assert decoded.ingress_timestamp_unix_nano > 0
    assert metric.kind == :METRIC_KIND_GAUGE
    assert metric.name == "rperf.bits_per_second"
    assert metric.metric_type == "rperf"
    assert point.value == 1_600.0
    assert assert_nats_msg_id_header(opts)
  end

  test "rejects legacy JSON rperf metric payloads" do
    Application.put_env(:serviceradar_agent_gateway, :rperf_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.rperf",
      connection: __MODULE__.ConnectionStub
    )

    assert {:error, :invalid_metric_batch_payload} =
             RperfMetricsPublisher.publish_rperf(
               rperf_status(Jason.encode!(%{"status" => %{"results" => [%{"target" => "wan"}]}}))
             )

    refute_receive {:published, _subject, _payload, _opts}
  end

  test "is disabled by default" do
    Application.put_env(:serviceradar_agent_gateway, :rperf_metrics_publisher,
      enabled: false,
      connection: __MODULE__.ConnectionStub
    )

    assert :disabled = RperfMetricsPublisher.publish_rperf(rperf_status(metric_batch_payload()))
    refute_receive {:published, _subject, _payload, _opts}
  end

  defmodule ConnectionStub do
    @moduledoc false
    def publish(subject, payload, opts) do
      send(Application.fetch_env!(:serviceradar_agent_gateway, :rperf_metrics_publisher_test_pid), {
        :published,
        subject,
        payload,
        opts
      })

      :ok
    end
  end

  defp rperf_status(payload) do
    %{
      service_name: "rperf",
      service_type: "rperf",
      source: "rperf-metrics",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      timestamp: 1_765_500_000_000_000_000,
      agent_timestamp: 1_765_499_999_000_000_000,
      message: payload
    }
  end

  defp metric_batch_payload do
    MetricBatch.encode(%MetricBatch{
      schema_version: "serviceradar.metric.v1",
      resource: %MetricResource{
        agent_id: "spoofed-agent",
        gateway_id: "spoofed-gateway",
        partition: "spoofed-partition",
        service_name: "spoofed-service",
        service_type: "spoofed-type"
      },
      ingest_identity: %IngestIdentity{
        source: "spoofed-source",
        payload_kind: "spoofed-payload",
        producer_kind: "spoofed-kind",
        producer_id: "spoofed-producer",
        attested_by: "spoofed-attestor"
      },
      emitted_at_unix_nano: 1_765_500_000_000_000_000,
      metrics: [
        %Metric{
          name: "rperf.bits_per_second",
          metric_type: "rperf",
          kind: :METRIC_KIND_GAUGE,
          unit: "bit/s",
          points: [
            %MetricPoint{
              value: 1_600.0,
              raw_value: "1600",
              raw_value_type: :METRIC_VALUE_TYPE_DOUBLE,
              observed_at_unix_nano: 1_765_500_000_000_000_000
            }
          ]
        }
      ]
    })
  end
end
