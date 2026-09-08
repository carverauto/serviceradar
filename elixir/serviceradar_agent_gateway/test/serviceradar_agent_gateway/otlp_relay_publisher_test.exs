defmodule ServiceRadarAgentGateway.OtlpRelayPublisherTest do
  use ExUnit.Case, async: false

  alias Serviceradar.Agent.Addon.V1.TelemetryBatch
  alias Serviceradar.Agent.Addon.V1.TelemetryCounters
  alias Serviceradar.Agent.Addon.V1.TelemetryRecord
  alias Serviceradar.Agent.Addon.V1.TelemetrySource
  alias ServiceRadarAgentGateway.OtlpRelayPublisher

  setup do
    previous_config = Application.get_env(:serviceradar_agent_gateway, :otlp_relay_publisher)

    previous_pid =
      Application.get_env(:serviceradar_agent_gateway, :otlp_relay_publisher_test_pid)

    on_exit(fn ->
      restore_env(:otlp_relay_publisher, previous_config)
      restore_env(:otlp_relay_publisher_test_pid, previous_pid)
    end)

    Application.put_env(:serviceradar_agent_gateway, :otlp_relay_publisher_test_pid, self())
    :ok
  end

  test "publishes relayed OTLP records to canonical subjects with gateway-derived headers" do
    Application.put_env(:serviceradar_agent_gateway, :otlp_relay_publisher,
      enabled: true,
      connection: __MODULE__.TestConnection
    )

    traces_payload = <<0xDE, 0xAD, 0x01>>
    logs_payload = <<0xBE, 0xEF, 0x02>>
    metrics_payload = <<0xCA, 0xFE, 0x03>>
    derived_payload = <<0xF0, 0x0D, 0x04>>

    assert :ok =
             OtlpRelayPublisher.publish_relay(
               relay_status([
                 %TelemetryRecord{
                   event_id: "traces-1",
                   payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
                   payload: traces_payload
                 },
                 %TelemetryRecord{
                   event_id: "logs-1",
                   payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_LOGS,
                   payload: logs_payload
                 },
                 %TelemetryRecord{
                   event_id: "metrics-1",
                   payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_METRICS,
                   payload: metrics_payload
                 },
                 %TelemetryRecord{
                   event_id: "derived-1",
                   payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_DERIVED_METRIC,
                   payload: derived_payload
                 }
               ])
             )

    assert_receive {:published, "otel.traces.raw", ^traces_payload, traces_opts}
    assert_relay_headers(traces_opts)

    assert_receive {:published, "logs.otel", ^logs_payload, logs_opts}
    assert_relay_headers(logs_opts)

    assert_receive {:published, "otel.metrics.raw", ^metrics_payload, metrics_opts}
    assert_relay_headers(metrics_opts)

    assert_receive {:published, "otel.metrics.derived", ^derived_payload, derived_opts}
    assert_relay_headers(derived_opts)

    refute_receive {:published, _subject, _payload, _opts}
  end

  test "uses configured local NATS subjects" do
    Application.put_env(:serviceradar_agent_gateway, :otlp_relay_publisher,
      enabled: true,
      connection: __MODULE__.TestConnection,
      traces_subject: "leaf.otel.traces.raw"
    )

    assert :ok =
             OtlpRelayPublisher.publish_relay(
               relay_status([
                 %TelemetryRecord{
                   event_id: "traces-1",
                   payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
                   payload: <<1>>
                 }
               ])
             )

    assert_receive {:published, "leaf.otel.traces.raw", <<1>>, _opts}
  end

  test "returns disabled without publishing when disabled" do
    Application.put_env(:serviceradar_agent_gateway, :otlp_relay_publisher,
      enabled: false,
      connection: __MODULE__.TestConnection
    )

    assert :disabled =
             OtlpRelayPublisher.publish_relay(
               relay_status([
                 %TelemetryRecord{
                   event_id: "traces-1",
                   payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
                   payload: <<1>>
                 }
               ])
             )

    refute_receive {:published, _subject, _payload, _opts}
  end

  test "skips unknown payload kinds without failing the relay frame" do
    Application.put_env(:serviceradar_agent_gateway, :otlp_relay_publisher,
      enabled: true,
      connection: __MODULE__.TestConnection
    )

    assert :ok =
             OtlpRelayPublisher.publish_relay(
               relay_status([
                 %TelemetryRecord{
                   event_id: "unknown-1",
                   payload_kind: :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
                   payload: <<1>>
                 }
               ])
             )

    refute_receive {:published, _subject, _payload, _opts}
  end

  test "reports publish failure" do
    Application.put_env(:serviceradar_agent_gateway, :otlp_relay_publisher,
      enabled: true,
      connection: __MODULE__.FailingConnection
    )

    assert {:error, {:otlp_relay_publish_failed, :nats_down}} =
             OtlpRelayPublisher.publish_relay(
               relay_status([
                 %TelemetryRecord{
                   event_id: "traces-1",
                   payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
                   payload: <<1>>
                 }
               ])
             )
  end

  defp relay_status(records) do
    batch =
      TelemetryBatch.encode(%TelemetryBatch{
        source: %TelemetrySource{
          source_type: "otel-collector",
          source_instance: "edge-1",
          metadata: %{"agent_id" => "spoofed", "partition" => "spoofed"}
        },
        counters: %TelemetryCounters{received: length(records), emitted: length(records)},
        records: records
      })

    %{
      service_name: "otlp-relay",
      service_type: "otlp-relay",
      source: "otlp-relay",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "prod-east",
      message: batch
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)

  defp assert_relay_headers(opts) do
    headers =
      opts
      |> Keyword.fetch!(:headers)
      |> Map.new()

    assert headers["Sr-Agent-Id"] == "agent-1"
    assert headers["Sr-Gateway-Id"] == "gateway-1"
    assert headers["Sr-Partition"] == "prod-east"
    assert headers["Sr-Ingest-Identity"] == "agent:agent-1"
    assert headers["Sr-Ingress-Id"] =~ uuidv8_pattern()
    assert Integer.parse(headers["Sr-Ingress-Time-Unix-Nano"]) != :error
  end

  defp uuidv8_pattern do
    ~r/^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  end

  defmodule TestConnection do
    @moduledoc false
    def publish(subject, payload, opts) do
      send(Application.fetch_env!(:serviceradar_agent_gateway, :otlp_relay_publisher_test_pid), {
        :published,
        subject,
        payload,
        opts
      })

      :ok
    end
  end

  defmodule FailingConnection do
    @moduledoc false
    def publish(_subject, _payload, _opts), do: {:error, :nats_down}
  end
end
