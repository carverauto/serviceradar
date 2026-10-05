defmodule ServiceRadarAgentGateway.RuntimeMetrics do
  @moduledoc """
  Publishes the gateway's own core-call latency and status-buffer depth.

  Samples are queued here, bounded, and published as a ServiceRadar metric
  envelope on `metrics.agent_gateway`. EventWriter's metrics consumer
  persists that subject. A full queue or a publisher that does not answer
  drops the sample. PushStatus never waits on this GenServer for more than
  a short enqueue timeout, and a failed publish does not fail delivery.
  """

  use GenServer

  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias Serviceradar.Metric.V1.StringMapEntry
  alias ServiceRadar.NATS.JetStreamPublish
  alias ServiceRadarAgentGateway.Config

  require Logger

  @subject "metrics.agent_gateway"
  @max_pending 100
  @enqueue_timeout_ms 50
  @publish_timeout_ms 1_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec subject() :: String.t()
  def subject, do: @subject

  @doc false
  @spec report_core_call(non_neg_integer(), atom(), map()) :: :ok
  def report_core_call(duration_ms, result, status) when is_integer(duration_ms) and is_map(status) do
    enqueue(%{
      name: "agent_gateway_core_call_duration_ms",
      value: duration_ms,
      unit: "ms",
      tags: %{"result" => metric_token(result), "source" => metric_source(status)}
    })
  end

  @doc false
  @spec report_buffer_depth(non_neg_integer()) :: :ok
  def report_buffer_depth(depth) when is_integer(depth) and depth >= 0 do
    enqueue(%{name: "agent_gateway_status_buffer_depth", value: depth, unit: "entries", tags: %{}})
  end

  defp enqueue(sample) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, {:enqueue, sample}, @enqueue_timeout_ms)
        catch
          :exit, _reason -> :ok
        end

      _missing ->
        :ok
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{queue: :queue.new(), depth: nil, publishing: false, turn: :depth}}
  end

  @impl true
  def handle_call({:enqueue, %{name: "agent_gateway_status_buffer_depth"} = sample}, _from, state) do
    {:reply, :ok, schedule_publish(%{state | depth: sample})}
  end

  def handle_call({:enqueue, sample}, _from, state) do
    if :queue.len(state.queue) >= @max_pending do
      Logger.warning("Gateway runtime metric queue full; dropping core-call sample")
      {:reply, :ok, state}
    else
      {:reply, :ok, schedule_publish(%{state | queue: :queue.in(sample, state.queue)})}
    end
  end

  @impl true
  def handle_info(:publish, state) do
    state = %{state | publishing: false}

    case next_sample(state) do
      {:empty, state} ->
        {:noreply, state}

      {sample, state} ->
        publish_sample(sample)
        {:noreply, schedule_publish(state)}
    end
  end

  defp schedule_publish(%{publishing: true} = state), do: state

  defp schedule_publish(state) do
    send(self(), :publish)
    %{state | publishing: true}
  end

  defp next_sample(%{depth: sample, queue: queue} = state)
       when not is_nil(sample) do
    if :queue.is_empty(queue) or Map.get(state, :turn, :depth) == :depth do
      {sample, %{state | depth: nil, turn: :queue}}
    else
      {{:value, queued}, rest} = :queue.out(queue)
      {queued, %{state | queue: rest, turn: :depth}}
    end
  end

  defp next_sample(state) do
    case :queue.out(state.queue) do
      {:empty, queue} -> {:empty, %{state | queue: queue}}
      {{:value, sample}, queue} -> {sample, %{state | queue: queue}}
    end
  end

  defp publish_sample(sample) do
    body = sample |> batch() |> MetricBatch.encode()

    case publish_body(body) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Gateway runtime metric publish failed: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("Gateway runtime metric publish failed: #{Exception.message(error)}")
      :ok
  end

  defp publish_body(body) do
    case Application.get_env(:serviceradar_agent_gateway, :runtime_metrics_publish) do
      publish when is_function(publish, 2) -> publish.(@subject, body)
      _default -> JetStreamPublish.publish(@subject, body, timeout: @publish_timeout_ms)
    end
  end

  defp batch(sample) do
    observed_at = System.system_time(:nanosecond)

    %MetricBatch{
      schema_version: "serviceradar.metric.v1",
      resource: %MetricResource{
        gateway_id: gateway_id(),
        service_name: "agent-gateway",
        service_type: "runtime"
      },
      ingest_identity: %IngestIdentity{
        source: "agent-gateway",
        payload_kind: "metrics",
        producer_kind: "gateway"
      },
      emitted_at_unix_nano: observed_at,
      metrics: [
        %Metric{
          name: sample.name,
          kind: :METRIC_KIND_GAUGE,
          unit: sample.unit,
          tags: Enum.map(sample.tags, fn {key, value} -> %StringMapEntry{key: key, value: value} end),
          points: [%MetricPoint{value: sample.value * 1.0, observed_at_unix_nano: observed_at}]
        }
      ]
    }
  end

  defp gateway_id do
    Config.gateway_id()
  rescue
    _error -> "unknown"
  end

  defp metric_token(value) when is_atom(value), do: Atom.to_string(value)
  defp metric_token(value) when is_binary(value), do: value
  defp metric_token(_value), do: "other"

  defp metric_source(%{source: source}) when source in ["flow-attribution", :flow_attribution], do: "flow-attribution"

  defp metric_source(%{source: source}) when source in ["plugin-result", :plugin_result], do: "plugin-result"

  defp metric_source(%{source: source}) when source in ["otlp-relay", :otlp_relay], do: "otlp-relay"

  defp metric_source(%{source: source}) when source in ["results", :results], do: "results"

  defp metric_source(%{source: source}) when source in ["status", :status], do: "status"

  defp metric_source(%{source: "addon:" <> _rest}), do: "addon"

  defp metric_source(%{source: "plugin:" <> _rest}), do: "plugin"

  defp metric_source(_status), do: "other"
end
