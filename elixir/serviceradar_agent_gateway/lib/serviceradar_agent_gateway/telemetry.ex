defmodule ServiceRadarAgentGateway.Telemetry do
  @moduledoc """
  Prometheus telemetry reporter for the agent gateway runtime.
  """

  use Supervisor

  import Telemetry.Metrics

  @prometheus_reporter :serviceradar_agent_gateway_prometheus_metrics
  @duration_buckets_ms [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]

  @spec prometheus_reporter() :: atom()
  def prometheus_reporter, do: @prometheus_reporter

  @spec metrics() :: list(Telemetry.Metrics.t())
  def metrics do
    [
      counter("serviceradar.agent_gateway.push.complete.count",
        event_name: [:serviceradar, :agent_gateway, :push, :complete],
        tags: [:gateway_id, :domain],
        tag_values: &push_tag_values/1
      ),
      sum("serviceradar.agent_gateway.push.services.count",
        event_name: [:serviceradar, :agent_gateway, :push, :complete],
        measurement: :service_count,
        tags: [:gateway_id, :domain],
        tag_values: &push_tag_values/1
      ),
      counter("serviceradar.agent_gateway.results.forward.count",
        event_name: [:serviceradar, :agent_gateway, :results, :forward],
        measurement: :count,
        tags: [:result, :from_buffer, :service_type, :gateway_id, :partition],
        tag_values: &forward_tag_values/1
      ),
      distribution("serviceradar.agent_gateway.results.forward.duration",
        event_name: [:serviceradar, :agent_gateway, :results, :forward],
        measurement: :duration_ms,
        unit: {:native, :millisecond},
        tags: [:result, :from_buffer, :service_type, :gateway_id, :partition],
        tag_values: &forward_tag_values/1,
        reporter_options: [buckets: @duration_buckets_ms]
      ),
      counter("serviceradar.agent_gateway.results.buffer.dropped.count",
        event_name: [:serviceradar, :agent_gateway, :results, :buffer, :dropped],
        tags: [:reason, :source, :service_type, :gateway_id, :partition],
        tag_values: &buffer_tag_values/1
      ),
      sum("serviceradar.agent_gateway.results.buffer.dropped.bytes",
        event_name: [:serviceradar, :agent_gateway, :results, :buffer, :dropped],
        measurement: :bytes,
        tags: [:reason, :source, :service_type, :gateway_id, :partition],
        tag_values: &buffer_tag_values/1
      ),
      last_value("serviceradar.agent_gateway.results.buffer.depth",
        event_name: [:serviceradar, :agent_gateway, :results, :buffer, :depth],
        measurement: :depth,
        tags: [:gateway_id],
        tag_values: &buffer_tag_values/1
      ),
      last_value("serviceradar.agent_gateway.results.buffer.bytes",
        event_name: [:serviceradar, :agent_gateway, :results, :buffer, :depth],
        measurement: :bytes,
        tags: [:gateway_id],
        tag_values: &buffer_tag_values/1
      ),
      counter("serviceradar.agent_gateway.control_stream.established.count",
        event_name: [:serviceradar, :agent_gateway, :control_stream, :established],
        tags: [:gateway_id],
        tag_values: &control_stream_tag_values/1
      ),
      counter("serviceradar.agent_gateway.control_stream.closed.count",
        event_name: [:serviceradar, :agent_gateway, :control_stream, :closed],
        tags: [:gateway_id],
        tag_values: &control_stream_tag_values/1
      ),
      last_value("serviceradar.agent_gateway.control_stream.active.count",
        event_name: [:serviceradar, :agent_gateway, :control_stream, :active],
        measurement: :count,
        tags: [:gateway_id],
        tag_values: &control_stream_tag_values/1
      )
    ]
  end

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {TelemetryMetricsPrometheus.Core, metrics: metrics(), name: @prometheus_reporter, start_async: false}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp push_tag_values(metadata) do
    %{
      gateway_id: stringify(metadata[:gateway_id], "unknown"),
      domain: stringify(metadata[:domain], "default")
    }
  end

  defp forward_tag_values(metadata) do
    %{
      result: stringify(metadata[:result], "unknown"),
      from_buffer: stringify(metadata[:from_buffer], "false"),
      service_type: stringify(metadata[:service_type], "unknown"),
      gateway_id: stringify(metadata[:gateway_id], "unknown"),
      partition: stringify(metadata[:partition], "default")
    }
  end

  defp buffer_tag_values(metadata) do
    %{
      reason: stringify(metadata[:reason], "unknown"),
      source: stringify(metadata[:source], "unknown"),
      service_type: stringify(metadata[:service_type], "unknown"),
      gateway_id: stringify(metadata[:gateway_id], "unknown"),
      partition: stringify(metadata[:partition], "default")
    }
  end

  defp control_stream_tag_values(metadata) do
    %{gateway_id: stringify(metadata[:gateway_id], "unknown")}
  end

  defp stringify(nil, default), do: default
  defp stringify("", default), do: default
  defp stringify(value, _default) when is_binary(value), do: value
  defp stringify(value, _default), do: to_string(value)
end
