defmodule ServiceRadarAgentGateway.SnmpMetricsPublisherTest do
  use ExUnit.Case, async: false

  import ServiceRadarAgentGateway.MetricsPublisherTestHelpers

  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias Serviceradar.Metric.V1.StringMapEntry
  alias ServiceRadarAgentGateway.SnmpMetricsPublisher

  setup do
    previous_config = Application.get_env(:serviceradar_agent_gateway, :snmp_metrics_publisher)
    previous_pid = Application.get_env(:serviceradar_agent_gateway, :snmp_metrics_publisher_test_pid)

    on_exit(fn ->
      restore_env(:snmp_metrics_publisher, previous_config)
      restore_env(:snmp_metrics_publisher_test_pid, previous_pid)
    end)

    Application.put_env(:serviceradar_agent_gateway, :snmp_metrics_publisher_test_pid, self())

    :ok
  end

  test "publishes protobuf SNMP metric batch with gateway-attested identity" do
    Application.put_env(:serviceradar_agent_gateway, :snmp_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.snmp",
      connection: __MODULE__.ConnectionStub
    )

    payload = metric_batch_payload()

    assert :ok = SnmpMetricsPublisher.publish_snmp(snmp_status(payload))

    assert_receive {:published, "metrics.snmp.snmp.ifhcinoctets", published_payload, opts}

    refute published_payload == payload

    decoded = MetricBatch.decode(published_payload)
    counter = hd(decoded.metrics)
    assert decoded.schema_version == "serviceradar.metric.v1"

    assert Map.take(decoded.resource, [
             :agent_id,
             :gateway_id,
             :partition,
             :service_name,
             :service_type,
             :target_device_ip
           ]) == %{
             agent_id: "agent-1",
             gateway_id: "gateway-1",
             partition: "default",
             service_name: "snmp",
             service_type: "snmp",
             target_device_ip: "10.0.0.20"
           }

    assert Map.take(decoded.ingest_identity, [
             :source,
             :payload_kind,
             :producer_id,
             :producer_kind,
             :attested_by
           ]) == %{
             source: "snmp-metrics",
             payload_kind: "serviceradar.metric.v1",
             producer_id: "agent-1",
             producer_kind: "agent",
             attested_by: "gateway-1"
           }

    assert decoded.ingress_id =~ uuidv8_pattern()
    assert decoded.ingress_timestamp_unix_nano > 0
    assert counter.kind == :METRIC_KIND_SUM
    assert counter.temporality == :METRIC_TEMPORALITY_CUMULATIVE
    assert counter.is_monotonic
    assert counter.counter_width == 64
    assert hd(counter.points).raw_value == "1234"
    assert assert_full_ingress_headers(opts)
  end

  test "rejects legacy JSON SNMP metric payloads" do
    Application.put_env(:serviceradar_agent_gateway, :snmp_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.snmp",
      connection: __MODULE__.ConnectionStub
    )

    assert {:error, :invalid_metric_batch_payload} =
             SnmpMetricsPublisher.publish_snmp(
               snmp_status(Jason.encode!(%{"results" => [%{"metric" => "ifHCInOctets", "value" => 1234}]}))
             )

    refute_receive {:published, _subject, _payload, _opts}
  end

  test "is disabled by default" do
    Application.put_env(:serviceradar_agent_gateway, :snmp_metrics_publisher,
      enabled: false,
      connection: __MODULE__.ConnectionStub
    )

    assert :disabled = SnmpMetricsPublisher.publish_snmp(snmp_status(metric_batch_payload()))
    refute_receive {:published, _subject, _payload, _opts}
  end

  test "reports publish failures without raising" do
    Application.put_env(:serviceradar_agent_gateway, :snmp_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.snmp",
      connection: __MODULE__.FailingConnectionStub
    )

    assert {:error, {:publish_failed, failures}} =
             SnmpMetricsPublisher.publish_snmp(snmp_status(metric_batch_payload()))

    assert {"metrics.snmp.snmp.ifhcinoctets", :nats_down} in failures
  end

  defmodule ConnectionStub do
    @moduledoc false
    def publish(subject, payload, opts) do
      send(Application.fetch_env!(:serviceradar_agent_gateway, :snmp_metrics_publisher_test_pid), {
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

  defp snmp_status(payload) do
    %{
      service_name: "snmp",
      service_type: "snmp",
      source: "snmp-metrics",
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
        target_device_ip: "10.0.0.20"
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
          name: "ifHCInOctets",
          metric_type: "snmp",
          kind: :METRIC_KIND_SUM,
          temporality: :METRIC_TEMPORALITY_CUMULATIVE,
          is_monotonic: true,
          counter_width: 64,
          points: [
            %MetricPoint{
              value: 1234,
              raw_value: "1234",
              raw_value_type: :METRIC_VALUE_TYPE_UINT64,
              observed_at_unix_nano: 1_765_500_000_000_000_000,
              if_index: 7,
              interface_uid: "ifindex:7"
            }
          ],
          tags: [
            %StringMapEntry{key: "target", value: "10.0.0.20"},
            %StringMapEntry{key: "interface_uid", value: "ifindex:7"}
          ],
          metadata: [
            %StringMapEntry{key: "oid", value: ".1.3.6.1.2.1.31.1.1.1.6.7"},
            %StringMapEntry{key: "data_type", value: "counter"}
          ]
        }
      ]
    })
  end
end
