defmodule ServiceRadarAgentGateway.SweepMetricsPublisherTest do
  use ExUnit.Case, async: false

  import ServiceRadarAgentGateway.MetricsPublisherTestHelpers

  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias ServiceRadarAgentGateway.SweepMetricsPublisher

  setup do
    previous_config = Application.get_env(:serviceradar_agent_gateway, :sweep_metrics_publisher)
    previous_pid = Application.get_env(:serviceradar_agent_gateway, :sweep_metrics_publisher_test_pid)

    on_exit(fn ->
      restore_env(:sweep_metrics_publisher, previous_config)
      restore_env(:sweep_metrics_publisher_test_pid, previous_pid)
    end)

    Application.put_env(:serviceradar_agent_gateway, :sweep_metrics_publisher_test_pid, self())

    :ok
  end

  test "publishes protobuf sweep metric batch with gateway-attested identity" do
    Application.put_env(:serviceradar_agent_gateway, :sweep_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.sweep",
      connection: __MODULE__.ConnectionStub
    )

    payload = metric_batch_payload()

    assert :ok = SweepMetricsPublisher.publish_sweep(sweep_status(payload))

    assert_receive {:published, "metrics.sweep.sweep.sweep_total_hosts", published_payload, opts}

    decoded = MetricBatch.decode(published_payload)
    metric = hd(decoded.metrics)
    point = hd(metric.points)

    assert published_payload != payload
    assert decoded.schema_version == "serviceradar.metric.v1"

    assert Map.take(decoded.resource, [:agent_id, :gateway_id, :partition, :service_name, :service_type]) == %{
             agent_id: "agent-1",
             gateway_id: "gateway-1",
             partition: "default",
             service_name: "network_sweep",
             service_type: "sweep"
           }

    assert Map.take(decoded.ingest_identity, [:source, :payload_kind, :producer_id, :producer_kind, :attested_by]) == %{
             source: "sweep-metrics",
             payload_kind: "serviceradar.metric.v1",
             producer_id: "agent-1",
             producer_kind: "sweep",
             attested_by: "gateway-1"
           }

    assert decoded.ingress_id =~ uuidv8_pattern()
    assert decoded.ingress_timestamp_unix_nano > 0
    assert metric.kind == :METRIC_KIND_GAUGE
    assert metric.name == "sweep.total_hosts"
    assert metric.metric_type == "sweep"
    assert point.value == 2.0
    assert assert_nats_msg_id_header(opts)
  end

  test "rejects legacy JSON sweep metric payloads" do
    Application.put_env(:serviceradar_agent_gateway, :sweep_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.sweep",
      connection: __MODULE__.ConnectionStub
    )

    assert {:error, :invalid_metric_batch_payload} =
             SweepMetricsPublisher.publish_sweep(sweep_status(Jason.encode!(%{"total_hosts" => 2})))

    refute_receive {:published, _subject, _payload, _opts}
  end

  test "is disabled by default" do
    Application.put_env(:serviceradar_agent_gateway, :sweep_metrics_publisher,
      enabled: false,
      connection: __MODULE__.ConnectionStub
    )

    assert :disabled = SweepMetricsPublisher.publish_sweep(sweep_status(metric_batch_payload()))
    refute_receive {:published, _subject, _payload, _opts}
  end

  defmodule ConnectionStub do
    @moduledoc false
    def publish(subject, payload, opts) do
      send(Application.fetch_env!(:serviceradar_agent_gateway, :sweep_metrics_publisher_test_pid), {
        :published,
        subject,
        payload,
        opts
      })

      :ok
    end
  end

  defp sweep_status(payload) do
    %{
      service_name: "network_sweep",
      service_type: "sweep",
      source: "sweep-metrics",
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
          name: "sweep.total_hosts",
          metric_type: "sweep",
          kind: :METRIC_KIND_GAUGE,
          unit: "{host}",
          points: [
            %MetricPoint{
              value: 2.0,
              raw_value: "2",
              raw_value_type: :METRIC_VALUE_TYPE_DOUBLE,
              observed_at_unix_nano: 1_765_500_000_000_000_000
            }
          ]
        }
      ]
    })
  end
end
