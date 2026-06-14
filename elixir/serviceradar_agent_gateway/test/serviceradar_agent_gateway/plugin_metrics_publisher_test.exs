defmodule ServiceRadarAgentGateway.PluginMetricsPublisherTest do
  use ExUnit.Case, async: false

  alias Serviceradar.Agent.Addon.V1.TelemetryBatch
  alias Serviceradar.Agent.Addon.V1.TelemetryRecord
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias ServiceRadarAgentGateway.PluginMetricsPublisher

  setup do
    previous_config = Application.get_env(:serviceradar_agent_gateway, :plugin_metrics_publisher)

    previous_pid =
      Application.get_env(:serviceradar_agent_gateway, :plugin_metrics_publisher_test_pid)

    on_exit(fn ->
      restore_env(:plugin_metrics_publisher, previous_config)
      restore_env(:plugin_metrics_publisher_test_pid, previous_pid)
    end)

    Application.put_env(:serviceradar_agent_gateway, :plugin_metrics_publisher_test_pid, self())

    :ok
  end

  test "publishes native add-on metric batches with gateway-attested identity" do
    Application.put_env(:serviceradar_agent_gateway, :plugin_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.timeseries",
      connection: __MODULE__.ConnectionStub
    )

    payload = metric_batch_payload()
    assert :ok = PluginMetricsPublisher.publish_plugin_metrics(addon_status(payload))

    assert_receive {:published, "metrics.timeseries.cpu.proxmox_guest_cpu_ratio_max", published_payload, opts}

    refute published_payload == payload

    decoded = MetricBatch.decode(published_payload)
    assert decoded.schema_version == "serviceradar.metric.v1"
    assert decoded.resource.agent_id == "agent-1"
    assert decoded.resource.gateway_id == "gateway-1"
    assert decoded.resource.partition == "default"
    assert decoded.resource.service_name == "proxmox-inventory"
    assert decoded.resource.service_type == "native-addon"
    assert decoded.ingest_identity.source == "native-addon"
    assert decoded.ingest_identity.payload_kind == "serviceradar.metric.v1"
    assert decoded.ingest_identity.producer_id == "proxmox-inventory"
    assert decoded.ingest_identity.producer_kind == "native-addon"
    assert decoded.ingest_identity.attested_by == "gateway-1"
    assert decoded.ingress_id =~ uuidv8_pattern()
    assert decoded.ingress_timestamp_unix_nano > 0
    assert decoded.metrics |> hd() |> Map.get(:kind) == :METRIC_KIND_GAUGE
    assert decoded.metrics |> hd() |> Map.get(:points) |> hd() |> Map.get(:value) == 0.91
    assert ingress_headers(opts)
  end

  test "publishes wasm plugin metric batches with plugin attestation" do
    Application.put_env(:serviceradar_agent_gateway, :plugin_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.timeseries",
      connection: __MODULE__.ConnectionStub
    )

    assert :ok = PluginMetricsPublisher.publish_plugin_metrics(plugin_status(metric_batch_payload()))

    assert_receive {:published, "metrics.timeseries.cpu.proxmox_guest_cpu_ratio_max", published_payload, _opts}

    decoded = MetricBatch.decode(published_payload)
    assert decoded.resource.service_name == "proxmox-inventory"
    assert decoded.resource.service_type == "wasm-plugin"
    assert decoded.ingest_identity.source == "wasm-plugin"
    assert decoded.ingest_identity.producer_kind == "wasm-plugin"
  end

  test "skips non-metric native add-on telemetry records" do
    Application.put_env(:serviceradar_agent_gateway, :plugin_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.timeseries",
      connection: __MODULE__.ConnectionStub
    )

    message =
      TelemetryBatch.encode(%TelemetryBatch{
        records: [
          %TelemetryRecord{
            event_id: "event-1",
            payload_kind: :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
            payload: "{}"
          }
        ]
      })

    assert :ok = PluginMetricsPublisher.publish_plugin_metrics(addon_status(message))

    refute_receive {:published, _subject, _payload, _opts}
  end

  test "rejects legacy JSON plugin metric payloads" do
    Application.put_env(:serviceradar_agent_gateway, :plugin_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.timeseries",
      connection: __MODULE__.ConnectionStub
    )

    assert {:error, :invalid_plugin_metric_telemetry} =
             PluginMetricsPublisher.publish_plugin_metrics(
               addon_status(Jason.encode!(%{"metrics" => [%{"name" => "cpu", "value" => 1}]}))
             )

    refute_receive {:published, _subject, _payload, _opts}
  end

  test "is disabled by default" do
    Application.put_env(:serviceradar_agent_gateway, :plugin_metrics_publisher,
      enabled: false,
      connection: __MODULE__.ConnectionStub
    )

    assert :disabled = PluginMetricsPublisher.publish_plugin_metrics(addon_status(metric_batch_payload()))
    refute_receive {:published, _subject, _payload, _opts}
  end

  test "reports publish failures without raising" do
    Application.put_env(:serviceradar_agent_gateway, :plugin_metrics_publisher,
      enabled: true,
      subject_prefix: "metrics.timeseries",
      connection: __MODULE__.FailingConnectionStub
    )

    assert {:error, {:publish_failed, failures}} =
             PluginMetricsPublisher.publish_plugin_metrics(plugin_status(metric_batch_payload()))

    assert {"metrics.timeseries.cpu.proxmox_guest_cpu_ratio_max", :nats_down} in failures
  end

  defmodule ConnectionStub do
    @moduledoc false
    def publish(subject, payload, opts) do
      send(
        Application.fetch_env!(:serviceradar_agent_gateway, :plugin_metrics_publisher_test_pid),
        {
          :published,
          subject,
          payload,
          opts
        }
      )

      :ok
    end
  end

  defmodule FailingConnectionStub do
    @moduledoc false
    def publish(_subject, _payload, _opts), do: {:error, :nats_down}
  end

  defp addon_status(message) do
    %{
      service_name: "proxmox-inventory",
      service_type: "native-addon",
      source: "addon:proxmox-inventory",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      timestamp: 1_765_500_000_000_000_000,
      agent_timestamp: 1_765_499_999_000_000_000,
      message: message
    }
  end

  defp plugin_status(message) do
    %{
      service_name: "proxmox-inventory",
      service_type: "wasm-plugin",
      source: "plugin:proxmox-inventory",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      timestamp: 1_765_500_000_000_000_000,
      agent_timestamp: 1_765_499_999_000_000_000,
      message: message
    }
  end

  defp metric_batch_payload do
    metric_payload =
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
          producer_id: "spoofed-producer",
          producer_kind: "spoofed-kind",
          attested_by: "spoofed-attestor"
        },
        metrics: [
          %Metric{
            name: "proxmox_guest_cpu_ratio_max",
            metric_type: "cpu",
            kind: :METRIC_KIND_GAUGE,
            unit: "ratio",
            points: [
              %MetricPoint{
                value: 0.91,
                observed_at_unix_nano: 1_765_500_000_000_000_000
              }
            ]
          }
        ]
      })

    TelemetryBatch.encode(%TelemetryBatch{
      records: [
        %TelemetryRecord{
          event_id: "event-1",
          event_time_unix_nano: 1_765_500_000_000_000_000,
          observed_time_unix_nano: 1_765_500_000_000_000_000,
          payload_kind: :TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS,
          payload: metric_payload
        }
      ]
    })
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)

  defp ingress_headers(opts) do
    headers =
      opts
      |> Keyword.fetch!(:headers)
      |> Map.new()

    assert headers["Sr-Ingress-Id"] =~ uuidv8_pattern()
    assert Integer.parse(headers["Sr-Ingress-Time-Unix-Nano"]) != :error
    assert headers["Sr-Agent-Id"] == "agent-1"
    assert headers["Sr-Gateway-Id"] == "gateway-1"
    assert headers["Sr-Partition"] == "default"
    assert headers["Sr-Ingest-Identity"] == "agent:agent-1"
    assert headers["Nats-Msg-Id"] == "event-1"
  end

  defp uuidv8_pattern do
    ~r/^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  end
end
