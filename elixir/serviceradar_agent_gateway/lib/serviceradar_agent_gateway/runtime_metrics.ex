defmodule ServiceRadarAgentGateway.RuntimeMetrics do
  @moduledoc """
  Publishes the gateway's own core-call latency, status-buffer depth and status refusals.

  Samples are queued here, bounded, and published as a ServiceRadar metric
  envelope on `metrics.agent_gateway`. EventWriter's metrics consumer
  persists that subject. A full queue drops the sample. PushStatus never
  waits on this GenServer, and a failed publish does not fail delivery.

  Refused statuses are published as `agent_gateway_status_retired_source_refused_count`, a
  monotonic delta sum per refusal family. Refusals reported while a publish is pending are
  added together, so one sample per family covers them and the pending state stays bounded
  by the number of families. A count the gateway has not yet published is lost if it
  restarts; a published one is not.
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
  @refused_metric "agent_gateway_status_retired_source_refused_count"
  @max_pending 100
  @publish_timeout_ms 5_000

  # The depth gauge, the core-call queue and the refusal counts take turns, so a steady
  # stream of one cannot keep the others from being published.
  @turns [:depth, :queue, :refused]

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

  @doc false
  @spec report_refused_statuses(%{optional(String.t()) => pos_integer()}) :: :ok
  def report_refused_statuses(counts) when is_map(counts) do
    if map_size(counts) == 0, do: :ok, else: cast({:refused, counts})
  end

  # A cast, not a call: reporting runs on the PushStatus path and must never
  # block it. A call with a short timeout silently dropped samples whenever the
  # BEAM was busy (CI runners under memory pressure, a loaded gateway), which is
  # exactly when the metric matters. The queue stays bounded by @max_pending.
  defp enqueue(sample), do: cast({:enqueue, sample})

  defp cast(message) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.cast(pid, message)
      _missing -> :ok
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{queue: :queue.new(), depth: nil, refused: %{}, publishing: false, turn: :depth}}
  end

  @impl true
  def handle_cast({:refused, counts}, state) do
    refused = Map.merge(state.refused, counts, fn _family, pending, count -> pending + count end)
    {:noreply, schedule_publish(%{state | refused: refused})}
  end

  def handle_cast({:enqueue, %{name: "agent_gateway_status_buffer_depth"} = sample}, state) do
    {:noreply, schedule_publish(%{state | depth: sample})}
  end

  def handle_cast({:enqueue, sample}, state) do
    if :queue.len(state.queue) >= @max_pending do
      Logger.warning("Gateway runtime metric queue full; dropping core-call sample")
      {:noreply, state}
    else
      {:noreply, schedule_publish(%{state | queue: :queue.in(sample, state.queue)})}
    end
  end

  @impl true
  def handle_info(:publish, state) do
    state = %{state | publishing: false}

    case next_sample(state) do
      {:empty, state} ->
        {:noreply, state}

      {samples, state} ->
        publish_sample(samples)
        {:noreply, schedule_publish(state)}
    end
  end

  defp schedule_publish(%{publishing: true} = state), do: state

  defp schedule_publish(state) do
    send(self(), :publish)
    %{state | publishing: true}
  end

  defp next_sample(state) do
    {before, from_turn} = Enum.split_while(@turns, &(&1 != state.turn))
    Enum.find_value(from_turn ++ before, {:empty, state}, &take_sample(&1, state))
  end

  defp take_sample(:depth, %{depth: nil}), do: nil
  defp take_sample(:depth, state), do: {[state.depth], %{state | depth: nil, turn: :queue}}

  defp take_sample(:queue, state) do
    case :queue.out(state.queue) do
      {:empty, _queue} -> nil
      {{:value, sample}, rest} -> {[sample], %{state | queue: rest, turn: :refused}}
    end
  end

  defp take_sample(:refused, %{refused: refused}) when map_size(refused) == 0, do: nil

  defp take_sample(:refused, state) do
    samples =
      state.refused
      |> Enum.sort()
      |> Enum.map(fn {family, count} ->
        %{name: @refused_metric, value: count, unit: "statuses", tags: %{"source" => family}, kind: :sum}
      end)

    {samples, %{state | refused: %{}, turn: :depth}}
  end

  defp publish_sample(samples) do
    body = samples |> batch() |> MetricBatch.encode()

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

  defp batch(samples) do
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
      metrics: Enum.map(samples, &metric(&1, observed_at))
    }
  end

  defp metric(%{kind: :sum} = sample, observed_at) do
    %{
      metric(Map.delete(sample, :kind), observed_at)
      | kind: :METRIC_KIND_SUM,
        temporality: :METRIC_TEMPORALITY_DELTA,
        is_monotonic: true
    }
  end

  defp metric(sample, observed_at) do
    %Metric{
      name: sample.name,
      kind: :METRIC_KIND_GAUGE,
      unit: sample.unit,
      tags: Enum.map(sample.tags, fn {key, value} -> %StringMapEntry{key: key, value: value} end),
      points: [%MetricPoint{value: sample.value * 1.0, observed_at_unix_nano: observed_at}]
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

  defp metric_source(%{source: source}) when source in ["status", "plugin-telemetry"], do: source
  defp metric_source(_status), do: "other"
end
