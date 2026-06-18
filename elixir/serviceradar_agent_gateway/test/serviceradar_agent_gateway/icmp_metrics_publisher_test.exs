defmodule ServiceRadarAgentGateway.IcmpMetricsPublisherTest do
  use ExUnit.Case, async: false

  import ServiceRadarAgentGateway.MetricsPublisherTestHelpers

  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias Serviceradar.Metric.V1.StringMapEntry
  alias ServiceRadarAgentGateway.IcmpMetricsPublisher

  setup do
    previous_config = Application.get_env(:serviceradar_agent_gateway, :icmp_metrics_publisher)
    previous_pid = Application.get_env(:serviceradar_agent_gateway, :icmp_metrics_publisher_test_pid)

    on_exit(fn ->
      restore_env(:icmp_metrics_publisher, previous_config)
      restore_env(:icmp_metrics_publisher_test_pid, previous_pid)
    end)

    Application.put_env(:serviceradar_agent_gateway, :icmp_metrics_publisher_test_pid, self())

    :ok
  end

  test "publishes protobuf ICMP metric batch with gateway-attested identity" do
    Application.put_env(:serviceradar_agent_gateway, :icmp_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.icmp",
      connection: __MODULE__.ConnectionStub
    )

    payload = metric_batch_payload()

    assert :ok = IcmpMetricsPublisher.publish_icmp(icmp_status(payload))

    assert_receive {:published, "metrics.icmp.icmp.icmp_response_time_ns", published_payload, opts}

    refute published_payload == payload

    decoded = MetricBatch.decode(published_payload)
    metric = hd(decoded.metrics)
    point = hd(metric.points)

    assert decoded.schema_version == "serviceradar.metric.v1"

    assert Map.take(decoded.resource, [:agent_id, :gateway_id, :partition, :service_name, :service_type]) == %{
             agent_id: "agent-1",
             gateway_id: "gateway-1",
             partition: "default",
             service_name: "icmp_checks",
             service_type: "icmp"
           }

    assert Map.take(decoded.ingest_identity, [:source, :payload_kind, :producer_id, :producer_kind, :attested_by]) == %{
             source: "icmp-metrics",
             payload_kind: "serviceradar.metric.v1",
             producer_id: "agent-1",
             producer_kind: "agent",
             attested_by: "gateway-1"
           }

    assert decoded.ingress_id =~ uuidv8_pattern()
    assert decoded.ingress_timestamp_unix_nano > 0
    assert metric.kind == :METRIC_KIND_GAUGE
    assert metric.name == "icmp_response_time_ns"
    assert metric.metric_type == "icmp"
    assert point.raw_value == "12345678"
    assert point.raw_value_type == :METRIC_VALUE_TYPE_INT64
    assert assert_full_ingress_headers(opts)
  end

  test "rejects legacy JSON ICMP metric payloads" do
    Application.put_env(:serviceradar_agent_gateway, :icmp_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.icmp",
      connection: __MODULE__.ConnectionStub
    )

    assert {:error, :invalid_metric_batch_payload} =
             IcmpMetricsPublisher.publish_icmp(icmp_status(Jason.encode!(%{"results" => [%{"target" => "10.0.0.30"}]})))

    refute_receive {:published, _subject, _payload, _opts}
  end

  test "is disabled by default" do
    Application.put_env(:serviceradar_agent_gateway, :icmp_metrics_publisher,
      enabled: false,
      connection: __MODULE__.ConnectionStub
    )

    assert :disabled = IcmpMetricsPublisher.publish_icmp(icmp_status(metric_batch_payload()))
    refute_receive {:published, _subject, _payload, _opts}
  end

  test "reports publish failures without raising" do
    Application.put_env(:serviceradar_agent_gateway, :icmp_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.icmp",
      connection: __MODULE__.FailingConnectionStub
    )

    assert {:error, {:publish_failed, failures}} =
             IcmpMetricsPublisher.publish_icmp(icmp_status(metric_batch_payload()))

    assert {"metrics.icmp.icmp.icmp_response_time_ns", :nats_down} in failures
  end

  defmodule ConnectionStub do
    @moduledoc false
    def publish(subject, payload, opts) do
      send(Application.fetch_env!(:serviceradar_agent_gateway, :icmp_metrics_publisher_test_pid), {
        :published,
        subject,
        payload,
        opts
      })

      :ok
    end
  end

  defmodule FailingConnectionStub do
    @moduledoc false
    def publish(_subject, _payload, _opts), do: {:error, :nats_down}
  end

  defp icmp_status(payload) do
    %{
      service_name: "icmp_checks",
      service_type: "icmp",
      source: "icmp-metrics",
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
          name: "icmp_response_time_ns",
          metric_type: "icmp",
          kind: :METRIC_KIND_GAUGE,
          unit: "ns",
          points: [
            %MetricPoint{
              value: 12_345_678,
              raw_value: "12345678",
              raw_value_type: :METRIC_VALUE_TYPE_INT64,
              observed_at_unix_nano: 1_765_500_000_000_000_000,
              attributes: [
                %StringMapEntry{key: "check_id", value: "check-1"},
                %StringMapEntry{key: "target", value: "10.0.0.30"}
              ]
            }
          ]
        }
      ]
    })
  end
end
