defmodule ServiceRadarAgentGateway.SysmonMetricsPublisherTest do
  use ExUnit.Case, async: false

  import ServiceRadarAgentGateway.MetricsPublisherTestHelpers

  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias ServiceRadarAgentGateway.SysmonMetricsPublisher

  setup do
    previous_config = Application.get_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher)
    previous_pid = Application.get_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher_test_pid)

    on_exit(fn ->
      restore_env(:sysmon_metrics_publisher, previous_config)
      restore_env(:sysmon_metrics_publisher_test_pid, previous_pid)
    end)

    Application.put_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher_test_pid, self())

    :ok
  end

  test "publishes protobuf sysmon metric batch with gateway-attested identity" do
    Application.put_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.sysmon",
      connection: __MODULE__.ConnectionStub
    )

    payload = metric_batch_payload()

    assert :ok = SysmonMetricsPublisher.publish_sysmon(sysmon_status(payload))

    assert_receive {:published, "metrics.sysmon.sysmon_cpu.cpu_usage_percent", published_payload, opts}

    refute published_payload == payload

    decoded = MetricBatch.decode(published_payload)
    assert decoded.schema_version == "serviceradar.metric.v1"
    assert decoded.resource.agent_id == "agent-1"
    assert decoded.resource.gateway_id == "gateway-1"
    assert decoded.resource.partition == "default"
    assert decoded.resource.service_name == "sysmon"
    assert decoded.resource.service_type == "sysmon"
    assert decoded.resource.host_id == "host-1"
    assert decoded.ingest_identity.source == "sysmon-metrics"
    assert decoded.ingest_identity.payload_kind == "serviceradar.metric.v1"
    assert decoded.ingest_identity.producer_id == "agent-1"
    assert decoded.ingest_identity.producer_kind == "agent"
    assert decoded.ingest_identity.attested_by == "gateway-1"
    assert decoded.ingress_id =~ uuidv8_pattern()
    assert decoded.ingress_timestamp_unix_nano > 0
    assert decoded.metrics |> hd() |> Map.fetch!(:kind) == :METRIC_KIND_GAUGE
    assert assert_full_ingress_headers(opts)
  end

  test "rejects legacy JSON sysmon metric payloads" do
    Application.put_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.sysmon",
      connection: __MODULE__.ConnectionStub
    )

    assert {:error, :invalid_metric_batch_payload} =
             SysmonMetricsPublisher.publish_sysmon(
               sysmon_status(Jason.encode!(%{"status" => %{"cpus" => [%{"usage_percent" => 12.5}]}}))
             )

    refute_receive {:published, _subject, _payload, _opts}
  end

  test "is disabled by default" do
    Application.put_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher,
      enabled: false,
      connection: __MODULE__.ConnectionStub
    )

    assert :disabled = SysmonMetricsPublisher.publish_sysmon(sysmon_status(metric_batch_payload()))
    refute_receive {:published, _subject, _payload, _opts}
  end

  test "reports publish failures without raising" do
    Application.put_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.sysmon",
      connection: __MODULE__.FailingConnectionStub
    )

    assert {:error, {:publish_failed, failures}} =
             SysmonMetricsPublisher.publish_sysmon(sysmon_status(metric_batch_payload()))

    assert {"metrics.sysmon.sysmon_cpu.cpu_usage_percent", :nats_down} in failures
  end

  defmodule ConnectionStub do
    @moduledoc false
    def publish(subject, payload, opts) do
      send(Application.fetch_env!(:serviceradar_agent_gateway, :sysmon_metrics_publisher_test_pid), {
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

  defp sysmon_status(payload) do
    %{
      service_name: "sysmon",
      service_type: "sysmon",
      source: "sysmon-metrics",
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
        service_type: "spoofed-type",
        host_id: "host-1",
        host_ip: "10.0.0.10"
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
          name: "cpu.usage_percent",
          metric_type: "sysmon.cpu",
          kind: :METRIC_KIND_GAUGE,
          unit: "%",
          points: [
            %MetricPoint{
              value: 12.5,
              observed_at_unix_nano: 1_765_500_000_000_000_000
            }
          ]
        }
      ]
    })
  end
end
