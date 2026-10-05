defmodule ServiceRadar.ResultIngestion.LaneMetrics do
  @moduledoc """
  Ingestion lane metrics: aggregated from `:telemetry`, published on JetStream
  once per interval, and readable as a snapshot for operator views.

  Lanes are the admission lanes (`flow_attribution`, `retained_plugin_result`),
  the per-class result ingestion queues (`sweep`, `mapper`, ...) and the sync
  ingestion queue (`sync`).

  Every interval (`:ingestion_lane_metrics_interval_ms`, default one minute) one
  `serviceradar.metric.v1` MetricBatch is published on `metrics.ingestion_lanes`,
  exactly as `ServiceRadar.FlowAttribution.PassMetrics` publishes its own; the
  EventWriter `Metrics` processor persists it to the active telemetry backend,
  where it is queryable through `timeseries_metrics`:

    * `ingestion_lane_depth`, `ingestion_lane_in_flight`, `ingestion_lane_bytes`,
      `ingestion_lane_capacity` -- gauges at publish time
    * `ingestion_lane_admitted`, `ingestion_lane_rejected` (tagged `reason`),
      `ingestion_lane_nacked`, `ingestion_lane_timeouts`, `ingestion_lane_crashes`,
      `ingestion_lane_incomplete_runs` -- counts for the interval

  Every metric is tagged `lane`; there are no per-agent tags. `nacked` counts the
  admission-lane outcomes that negatively acknowledge a gateway call (rejections,
  timeouts, crashes).

  Telemetry handlers only update counters in a public ETS table, so they cost
  the emitting process almost nothing, and publishing happens per interval, never
  per result. A failed publish is logged and never affects ingestion.
  """

  use GenServer

  alias ServiceRadar.Admission.FlowLane
  alias ServiceRadar.Admission.RetainedPluginLane
  alias ServiceRadar.Inventory.SyncIngestorQueue
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias Serviceradar.Metric.V1.StringMapEntry
  alias ServiceRadar.NATS.JetStreamPublish
  alias ServiceRadar.ResultIngestion

  require Logger

  @subject "metrics.ingestion_lanes"
  @table __MODULE__
  @default_interval_ms to_timeout(minute: 1)

  @events [
    [:serviceradar, :admission_lane, :state],
    [:serviceradar, :admission_lane, :admission],
    [:serviceradar, :admission_lane, :rejected],
    [:serviceradar, :admission_lane, :timeout],
    [:serviceradar, :admission_lane, :crash],
    [:serviceradar, :result_ingestion, :state],
    [:serviceradar, :result_ingestion, :admitted],
    [:serviceradar, :result_ingestion, :rejected],
    [:serviceradar, :result_ingestion, :timeout],
    [:serviceradar, :result_ingestion, :crash],
    [:serviceradar, :sync_ingestion, :state],
    [:serviceradar, :sync_ingestion, :admitted],
    [:serviceradar, :sync_ingestion, :rejected],
    [:serviceradar, :sync_ingestion, :incomplete_run]
  ]

  @metric_names ~w(
    ingestion_lane_depth ingestion_lane_in_flight ingestion_lane_bytes ingestion_lane_capacity
    ingestion_lane_admitted ingestion_lane_rejected ingestion_lane_nacked
    ingestion_lane_timeouts ingestion_lane_crashes ingestion_lane_incomplete_runs
  )

  @spec subject() :: String.t()
  def subject, do: @subject

  @doc "Every metric name this module publishes, for consumers that query them."
  @spec metric_names() :: [String.t()]
  def metric_names, do: @metric_names

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Per-lane depth, in-flight count, capacity and the counts of the last completed
  interval plus the current one. Reads ETS only; `{:error, :unavailable}` when
  this node is not collecting lane metrics.
  """
  @spec snapshot() :: {:ok, [map()]} | {:error, :unavailable}
  def snapshot do
    if :ets.whereis(@table) == :undefined do
      {:error, :unavailable}
    else
      {:ok, Enum.map(lanes(), &lane_snapshot/1)}
    end
  end

  @doc "Publishes the current interval now (tests and shutdown)."
  @spec publish_now(GenServer.server()) :: :ok | {:error, term()}
  def publish_now(server \\ __MODULE__), do: GenServer.call(server, :publish_now)

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    record(event, measurements, metadata)
  rescue
    # A handler that raises is detached by :telemetry; never let that happen.
    _error -> :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    # One handler per node: a previous instance that died without terminate/2 must
    # not keep counting into this table.
    handler_id = __MODULE__
    _ = :telemetry.detach(handler_id)
    :ok = :telemetry.attach_many(handler_id, @events, &__MODULE__.handle_event/4, nil)

    state = %{
      handler_id: handler_id,
      interval_ms: Keyword.get(opts, :interval_ms, interval_ms()),
      publish: Keyword.get(opts, :publish, &JetStreamPublish.publish/2),
      now: Keyword.get(opts, :now, &DateTime.utc_now/0)
    }

    schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:publish_now, _from, state), do: {:reply, publish_interval(state), state}

  @impl true
  def handle_info(:publish, state) do
    _ = publish_interval(state)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
  end

  # --- recording (runs in the emitting process) ---

  defp record([_, :admission_lane, :state], m, %{lane: lane}), do: gauges(lane, m)
  defp record([_, :admission_lane, :admission], _m, %{lane: lane}), do: count(lane, :admitted)

  defp record([_, :admission_lane, :rejected], _m, %{lane: lane} = meta) do
    count(lane, :rejected, reason(meta))
    count(lane, :nacked)
  end

  defp record([_, :admission_lane, :timeout], _m, %{lane: lane}) do
    count(lane, :timeouts)
    count(lane, :nacked)
  end

  defp record([_, :admission_lane, :crash], _m, %{lane: lane}) do
    count(lane, :crashes)
    count(lane, :nacked)
  end

  defp record([_, :result_ingestion, :state], m, %{class: class}), do: gauges(class, m)
  defp record([_, :result_ingestion, :admitted], _m, %{class: class}), do: count(class, :admitted)

  defp record([_, :result_ingestion, :rejected], _m, %{class: class} = meta),
    do: count(class, :rejected, reason(meta))

  defp record([_, :result_ingestion, :timeout], _m, %{class: class}), do: count(class, :timeouts)
  defp record([_, :result_ingestion, :crash], _m, %{class: class}), do: count(class, :crashes)
  defp record([_, :sync_ingestion, :state], m, _meta), do: gauges(:sync, m)
  defp record([_, :sync_ingestion, :admitted], _m, _meta), do: count(:sync, :admitted)

  defp record([_, :sync_ingestion, :rejected], _m, meta),
    do: count(:sync, :rejected, reason(meta))

  defp record([_, :sync_ingestion, :incomplete_run], _m, _meta),
    do: count(:sync, :incomplete_runs)

  defp record(_event, _measurements, _metadata), do: :ok

  defp gauges(lane, measurements) do
    lane = to_string(lane)
    depth = Map.get(measurements, :pending_count, 0)
    in_flight = Map.get(measurements, :in_flight_count, 0)
    bytes = Map.get(measurements, :pending_bytes, 0) + Map.get(measurements, :in_flight_bytes, 0)
    :ets.insert(@table, {{:gauge, lane}, depth, in_flight, bytes})
  end

  defp count(lane, name, reason \\ nil) do
    key = {:count, to_string(lane), name, reason}
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
  end

  defp reason(%{reason: reason}) when is_atom(reason) or is_binary(reason), do: to_string(reason)
  defp reason(_meta), do: "other"

  # --- publishing ---

  defp publish_interval(state) do
    counts = take_counts()
    :ets.insert(@table, {:last_counts, counts})

    body =
      lanes()
      |> Enum.flat_map(&lane_metrics(&1, counts))
      |> batch(state.now.())
      |> MetricBatch.encode()

    case state.publish.(@subject, body) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("Ingestion lane metrics publish failed: #{inspect(reason)}")
        error
    end
  rescue
    error ->
      Logger.warning("Ingestion lane metrics failed: #{Exception.message(error)}")
      {:error, error}
  end

  # Interval counts are taken out of the table, so each is published once.
  defp take_counts do
    @table
    |> :ets.match_object({{:count, :_, :_, :_}, :_})
    |> Enum.flat_map(fn {key, _value} -> :ets.take(@table, key) end)
    |> Enum.reduce(%{}, fn {{:count, lane, name, reason}, value}, acc ->
      Map.update(acc, {lane, name, reason}, value, &(&1 + value))
    end)
  end

  defp lane_metrics(lane, counts) do
    {depth, in_flight, bytes} = gauge(lane)
    tags = %{"lane" => lane}

    gauges =
      [
        {"ingestion_lane_depth", depth, tags},
        {"ingestion_lane_in_flight", in_flight, tags},
        {"ingestion_lane_bytes", bytes, tags}
      ] ++ capacity_metric(lane, tags)

    interval =
      for {{^lane, name, reason}, value} <- counts do
        tags = if reason, do: Map.put(tags, "reason", reason), else: tags
        {"ingestion_lane_#{name}", value, tags}
      end

    gauges ++ interval
  end

  defp capacity_metric(lane, tags) do
    case capacity(lane) do
      nil -> []
      capacity -> [{"ingestion_lane_capacity", capacity, tags}]
    end
  end

  defp batch(metrics, now) do
    observed_at = DateTime.to_unix(now, :nanosecond)

    %MetricBatch{
      schema_version: "serviceradar.metric.v1",
      resource: %MetricResource{service_name: "core", service_type: "ingestion_lanes"},
      ingest_identity: %IngestIdentity{
        source: "ingestion-lanes",
        payload_kind: "metrics",
        producer_kind: "core"
      },
      emitted_at_unix_nano: observed_at,
      metrics:
        Enum.map(metrics, fn {name, value, tags} ->
          %Metric{
            name: name,
            kind: :METRIC_KIND_GAUGE,
            tags: Enum.map(tags, fn {k, v} -> %StringMapEntry{key: k, value: v} end),
            points: [%MetricPoint{value: value * 1.0, observed_at_unix_nano: observed_at}]
          }
        end)
    }
  end

  # --- snapshot ---

  defp lanes do
    seen =
      :ets.select(@table, [
        {{{:gauge, :"$1"}, :_, :_, :_}, [], [:"$1"]},
        {{{:count, :"$1", :_, :_}, :_}, [], [:"$1"]}
      ])

    known =
      ["flow_attribution", "retained_plugin_result", "sync"] ++
        Enum.map(ResultIngestion.classes(), &to_string/1)

    Enum.uniq(known ++ seen)
  end

  defp lane_snapshot(lane) do
    {depth, in_flight, bytes} = gauge(lane)
    current = current_counts(lane)
    last = last_counts(lane)

    %{
      lane: lane,
      depth: depth,
      in_flight: in_flight,
      bytes: bytes,
      capacity: capacity(lane),
      rejected: sum(current, last, :rejected),
      nacked: sum(current, last, :nacked),
      incomplete_runs: sum(current, last, :incomplete_runs)
    }
  end

  defp gauge(lane) do
    case :ets.lookup(@table, {:gauge, lane}) do
      [{_key, depth, in_flight, bytes}] -> {depth, in_flight, bytes}
      [] -> {0, 0, 0}
    end
  end

  defp current_counts(lane) do
    @table
    |> :ets.match_object({{:count, lane, :_, :_}, :_})
    |> Enum.reduce(%{}, fn {{:count, _lane, name, _reason}, value}, acc ->
      Map.update(acc, name, value, &(&1 + value))
    end)
  end

  defp last_counts(lane) do
    case :ets.lookup(@table, :last_counts) do
      [{:last_counts, counts}] ->
        Enum.reduce(counts, %{}, fn
          {{^lane, name, _reason}, value}, acc -> Map.update(acc, name, value, &(&1 + value))
          _other, acc -> acc
        end)

      [] ->
        %{}
    end
  end

  defp sum(current, last, name), do: Map.get(current, name, 0) + Map.get(last, name, 0)

  defp capacity("flow_attribution"), do: FlowLane.limits()[:max_items]
  defp capacity("retained_plugin_result"), do: RetainedPluginLane.limits()[:max_items]
  defp capacity("sync"), do: SyncIngestorQueue.max_pending_chunks()

  defp capacity(lane) do
    class = Enum.find(ResultIngestion.classes(), &(to_string(&1) == lane))
    if class, do: ResultIngestion.max_items(class)
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :publish, interval_ms)

  defp interval_ms do
    Application.get_env(
      :serviceradar_core,
      :ingestion_lane_metrics_interval_ms,
      @default_interval_ms
    )
  end
end
