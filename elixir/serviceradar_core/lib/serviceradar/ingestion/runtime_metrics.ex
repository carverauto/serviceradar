defmodule ServiceRadar.Ingestion.RuntimeMetrics do
  @moduledoc """
  Publishes bounded ingestion lane metrics through JetStream for EventWriter
  persistence.

  Producers update a fixed set of ETS slots; they never enqueue a metric message
  or wait for NATS. During an outage, gauges coalesce and event counts
  accumulate. Each frame reports gauges at their latest values and counters as
  deltas since the previous acknowledged frame; reporting watermarks advance
  only on PubAck. No agent, device, run, or payload identifier becomes a label.

  Two lanes describe work that continues after a result-ingestion lane has
  committed, and are published but not listed by `lane_stats/0`:

    * `topology_projection` - mapper graph projection jobs
      (`ServiceRadar.NetworkDiscovery.TopologyProjectionWorker`): scheduled
      (`admitted`), replaced by a newer result before running (`coalesced`),
      completed (`completion`, `accepted` or `not_accepted`), and exhausted or
      unschedulable (`failed`), with the last projection's `queue_wait_ms` and
      `duration_ms`. A job reads the current CNPG interfaces and links for its
      one device when it runs, so a retry applies that state.
    * `dgraph` - every Dgraph call, from the `[:serviceradar, :dgraph, :call, *]`
      telemetry of `ServiceRadar.Dgraph.Call`: replies (`completion`,
      `accepted` when the reply kind is `:ok`), backstop `timeout`s and
      `retry`s, with the last reply's `duration_ms` and `queue_wait_ms`.
  """
  use GenServer

  alias ServiceRadar.Admission.FlowLane
  alias ServiceRadar.Admission.RetainedPluginLane
  alias ServiceRadar.Ingestion.LaneSupervisor
  alias ServiceRadar.Ingestion.SweepQueue
  alias ServiceRadar.Inventory.SyncIngestorQueue
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias Serviceradar.Metric.V1.StringMapEntry
  alias ServiceRadar.NATS.JetStreamPublish

  require Logger

  @table __MODULE__
  @subject "metrics.ingestion_lanes"
  # Each frame becomes one platform.timeseries_metrics row per lane metric per
  # core node, so the cadence sets that table's volume. A 1-second cadence wrote
  # hundreds of thousands of rows an hour that nothing reads at that resolution.
  @default_interval_ms 30_000
  @publish_outage_reminder_ms 60_000
  @alert_health_ttl_ms 120_000
  @alert_lanes [:alert_log, :alert_event, :alert_metric, :alert_maintenance]
  @alert_health_gauges [
    :pending_count,
    :pending_bytes,
    :in_flight_count,
    :oldest_pending_ms,
    :retrying_count,
    :failed_count
  ]
  @result_ingestion_lanes [
    :flow_attribution,
    :retained_plugin_result,
    :sweep,
    :mapper,
    :bumblebee,
    :legacy_plugin,
    :endpoint,
    :other_results,
    :status,
    :sync,
    :service_state
  ]
  @continuation_lanes [:topology_projection, :dgraph]
  @lanes @result_ingestion_lanes ++ @alert_lanes ++ @continuation_lanes
  @dgraph_handler {__MODULE__, :dgraph_call}
  @dgraph_events [
    [:serviceradar, :dgraph, :call, :stop],
    [:serviceradar, :dgraph, :call, :timeout],
    [:serviceradar, :dgraph, :call, :retry]
  ]
  @events [
    :state,
    :admission,
    :admitted,
    :timeout,
    :rejected,
    :completion,
    :execution,
    :queue_timeout,
    :worker_timeout,
    :worker_crash,
    :caller_down,
    :coordinator_restart,
    :incomplete_run,
    :cancellation,
    :delivery,
    :publish_failure,
    :coalesced_interval,
    :coalesced,
    :expired,
    :crash,
    :retry,
    :failed,
    :attempt_recorded,
    :quarantined,
    :quarantine_acknowledged,
    :attempt_pruned,
    :attempt_store_failed,
    :other
  ]
  @reasons [
    :count_full,
    :configured_byte_full,
    :per_agent_full,
    :per_agent_byte_full,
    :wire_payload_too_large,
    :invalid_admission_descriptor,
    :admission_timeout,
    :lane_unavailable,
    :worker_unavailable,
    :queue_timeout,
    :worker_timeout,
    :worker_crash,
    :reservation_expired,
    :reservation_payload_mismatch,
    :sync_ingest_queue_full,
    :service_state_queue_full,
    :malformed_payload,
    :store_unavailable,
    :evaluation_failed,
    :rule_inventory_full,
    :other
  ]
  @gauges [
    :pending_count,
    :pending_bytes,
    :in_flight_count,
    :in_flight_bytes,
    :acknowledgement_ms,
    :queue_wait_ms,
    :execution_ms,
    :cancellation_ms,
    :worker_ms,
    :duration_ms,
    :payload_bytes,
    :oldest_pending_ms,
    :retrying_count,
    :failed_count
  ]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns the ordered list of result-ingestion lanes tracked by `RuntimeMetrics`.
  """
  def result_ingestion_lanes, do: @result_ingestion_lanes

  @doc """
  Returns a cheap, non-blocking snapshot of all result-ingestion lanes on this node
  directly from ETS without calling any lane GenServer or touching the database.
  """
  @spec lane_stats() :: {:ok, map()} | {:error, :unavailable}
  def lane_stats do
    if is_pid(Process.whereis(__MODULE__)) and :ets.whereis(@table) != :undefined do
      {:ok,
       %{
         node: to_string(node()),
         lanes: Enum.map(@result_ingestion_lanes, &lane_snapshot/1)
       }}
    else
      {:error, :unavailable}
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  def record(lane, event, measurements) when lane in @lanes and is_map(measurements) do
    event = if event in @events, do: event, else: :other

    count =
      case measurements[:count] do
        count when is_integer(count) and count > 0 and count <= 10_000 -> count
        _ -> 1
      end

    :ets.update_counter(@table, {:events, lane, event}, {2, count}, {{:events, lane, event}, 0})

    if event == :rejected do
      reason = if measurements[:reason] in @reasons, do: measurements[:reason], else: :other

      :ets.update_counter(
        @table,
        {:rejection, lane, reason},
        {2, count},
        {{:rejection, lane, reason}, 0}
      )
    end

    if event == :completion and measurements[:outcome] in [:accepted, :not_accepted] do
      outcome = measurements[:outcome]

      :ets.update_counter(
        @table,
        {:outcome, lane, outcome},
        {2, count},
        {{:outcome, lane, outcome}, 0}
      )
    end

    Enum.each(measurements, fn
      {name, value} when name in @gauges and is_number(value) and value >= 0 ->
        sample =
          if lane in @alert_lanes and name in @alert_health_gauges do
            {value, System.monotonic_time(:millisecond)}
          else
            value
          end

        :ets.insert(@table, {{:gauge, lane, name}, sample})

      _ ->
        :ok
    end)

    :ok
  rescue
    ArgumentError -> :ok
  end

  def record(_lane, _event, _measurements), do: :ok

  @doc false
  # Telemetry handler for `ServiceRadar.Dgraph.Call`; attached by init/1.
  def handle_dgraph_call([:serviceradar, :dgraph, :call, :stop], measurements, metadata, _) do
    outcome = if metadata[:kind] == :ok, do: :accepted, else: :not_accepted

    record(:dgraph, :completion, %{
      outcome: outcome,
      duration_ms: native_ms(measurements[:duration]),
      queue_wait_ms: native_ms(measurements[:queue_wait])
    })
  end

  def handle_dgraph_call([:serviceradar, :dgraph, :call, :timeout], measurements, _, _) do
    record(:dgraph, :timeout, %{duration_ms: native_ms(measurements[:duration])})
  end

  def handle_dgraph_call([:serviceradar, :dgraph, :call, :retry], _measurements, _, _) do
    record(:dgraph, :retry, %{})
  end

  defp native_ms(value) when is_integer(value),
    do: System.convert_time_unit(value, :native, :millisecond)

  defp native_ms(_value), do: nil

  @impl true
  def init(opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    configured =
      :serviceradar_core
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:interval_ms, @default_interval_ms)

    interval = Keyword.get(opts, :interval_ms, configured)

    if !(is_integer(interval) and interval > 0) do
      raise ArgumentError, "invalid metric cadence"
    end

    # A restarted process re-attaches; the handler only writes the public table.
    :telemetry.detach(@dgraph_handler)

    :ok =
      :telemetry.attach_many(
        @dgraph_handler,
        @dgraph_events,
        &__MODULE__.handle_dgraph_call/4,
        nil
      )

    Process.send_after(self(), :publish, interval)

    {:ok,
     %{
       interval: interval,
       publish_opts: Keyword.get(opts, :publish_opts, []),
       pending: nil,
       reported: %{},
       interval_start: System.system_time(:nanosecond),
       outage_failures: 0
     }}
  end

  @impl true
  def handle_info(:publish, state) do
    # While the PubAck-bound frame is pending, later cadence snapshots are
    # intentionally coalesced into latest gauges and cumulative counters.
    if state.pending, do: record(:service_state, :coalesced_interval, %{})

    now = System.system_time(:nanosecond)

    frame =
      state.pending ||
        frame(fresh_samples(), state.reported, state.interval_start, now)

    {pending, reported, interval_start, outage_failures} =
      case frame do
        nil ->
          {nil, state.reported, state.interval_start, state.outage_failures}

        {body, id, counters, frame_start} ->
          opts = Keyword.merge(state.publish_opts, timeout: 1_000, msg_id: id)

          case publish(body, opts) do
            :ok ->
              if state.outage_failures > 0 do
                Logger.info(
                  "Ingestion lane metrics publish recovered",
                  subject: @subject,
                  failures: state.outage_failures
                )
              end

              {nil, counters, frame_start, 0}

            {:error, reason} ->
              failures = state.outage_failures + 1
              log_publish_failure(failures, reason, state.interval)
              record(:service_state, :publish_failure, %{})
              held = {body, id, counters, frame_start}
              {held, state.reported, state.interval_start, failures}
          end
      end

    Process.send_after(self(), :publish, state.interval)

    {:noreply,
     %{
       state
       | pending: pending,
         reported: reported,
         interval_start: interval_start,
         outage_failures: outage_failures
     }}
  end

  # A single failed publish that the next cadence tick retries is what a JetStream
  # stall or leader election produces, so the first failure is info. The
  # outage warns from the second consecutive failure, then once per reminder
  # window while it lasts.
  defp log_publish_failure(1, reason, _interval) do
    Logger.info(
      "Ingestion lane metrics publish failed once; retrying the frame next interval",
      subject: @subject,
      failures: 1,
      reason: publish_error_class(reason)
    )
  end

  defp log_publish_failure(failures, reason, interval) do
    if failures == 2 or rem(failures, outage_reminder_every(interval)) == 0 do
      Logger.warning(
        "Ingestion lane metrics publish failing; buffering one frame",
        subject: @subject,
        failures: failures,
        reason: publish_error_class(reason)
      )
    end

    :ok
  end

  defp outage_reminder_every(interval), do: max(1, div(@publish_outage_reminder_ms, interval))

  # A recovery scan may move to a different core node. Stop refreshing that
  # former sampler's global health gauges indefinitely. A held PubAck frame is
  # already serialized and remains byte-identical despite sample expiration.
  defp fresh_samples do
    now = System.monotonic_time(:millisecond)

    Enum.flat_map(:ets.tab2list(@table), fn
      {key, {value, sampled_at}} ->
        if now - sampled_at <= @alert_health_ttl_ms, do: [{key, value}], else: []

      sample ->
        [sample]
    end)
  end

  defp frame([], _reported, _interval_start, _now), do: nil

  defp frame(samples, reported, interval_start, now) do
    metrics =
      Enum.map(samples, fn {{kind, lane, name}, value} ->
        prefix =
          case kind do
            :events -> "result_ingestion_events_"
            :rejection -> "result_ingestion_rejections_"
            :outcome -> "result_ingestion_terminals_"
            :gauge -> "result_ingestion_"
          end

        gauge? = kind == :gauge

        %Metric{
          name: prefix <> Atom.to_string(name),
          metric_type: "core.result_ingestion",
          kind: if(gauge?, do: :METRIC_KIND_GAUGE, else: :METRIC_KIND_SUM),
          temporality:
            if(gauge?,
              do: :METRIC_TEMPORALITY_UNSPECIFIED,
              else: :METRIC_TEMPORALITY_DELTA
            ),
          is_monotonic: not gauge?,
          unit: unit(kind, name),
          tags: [%StringMapEntry{key: "lane", value: Atom.to_string(lane)}],
          points: [
            %MetricPoint{
              value: delta(value, kind, lane, name, reported) * 1.0,
              observed_at_unix_nano: now,
              start_time_unix_nano: if(gauge?, do: 0, else: interval_start)
            }
          ]
        }
      end)

    body =
      MetricBatch.encode(%MetricBatch{
        schema_version: "serviceradar.metric.v1",
        emitted_at_unix_nano: now,
        resource: %MetricResource{
          gateway_id: "core:#{node()}",
          service_name: "core",
          service_type: "ingestion"
        },
        ingest_identity: %IngestIdentity{
          source: "core",
          payload_kind: "metrics",
          producer_kind: "core"
        },
        metrics: metrics
      })

    counters =
      samples
      |> Enum.reject(fn {{kind, _lane, _name}, _value} -> kind == :gauge end)
      |> Map.new(fn {{kind, lane, name}, value} -> {{kind, lane, name}, value} end)

    {body, Ecto.UUID.generate(), counters, now}
  end

  defp delta(value, :gauge, _lane, _name, _reported), do: value

  defp delta(value, kind, lane, name, reported),
    do: value - Map.get(reported, {kind, lane, name}, 0)

  defp publish_error_class({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp publish_error_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp publish_error_class(_reason), do: "unknown"

  defp publish(body, opts) do
    JetStreamPublish.publish(@subject, body, opts)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp unit(kind, _name) when kind in [:events, :rejection, :outcome], do: "events"

  defp unit(:gauge, name) when name in [:pending_bytes, :in_flight_bytes, :payload_bytes],
    do: "bytes"

  defp unit(:gauge, name)
       when name in [:pending_count, :in_flight_count, :retrying_count, :failed_count],
       do: "entries"

  defp unit(:gauge, _name), do: "ms"

  defp lane_snapshot(lane) do
    {max_items, max_bytes} = lane_capacity(lane)

    %{
      lane: lane,
      pending_count: lookup_int(:gauge, lane, :pending_count),
      pending_bytes: lookup_int(:gauge, lane, :pending_bytes),
      in_flight_count: lookup_int(:gauge, lane, :in_flight_count),
      in_flight_bytes: lookup_int(:gauge, lane, :in_flight_bytes),
      max_items: max_items,
      max_bytes: max_bytes,
      admitted_total: lookup_int(:events, lane, :admitted),
      rejected_total: lookup_int(:events, lane, :rejected),
      accepted_total: lookup_int(:outcome, lane, :accepted),
      not_accepted_total: lookup_int(:outcome, lane, :not_accepted),
      timeout_total:
        lookup_int(:events, lane, :timeout) +
          lookup_int(:events, lane, :worker_timeout) +
          lookup_int(:events, lane, :queue_timeout),
      crash_total:
        lookup_int(:events, lane, :crash) +
          lookup_int(:events, lane, :worker_crash),
      incomplete_run_total: lookup_int(:events, lane, :incomplete_run),
      coalesced_total: lookup_int(:events, lane, :coalesced),
      expired_total: lookup_int(:events, lane, :expired),
      queue_wait_ms: lookup_int(:gauge, lane, :queue_wait_ms),
      execution_ms:
        max(lookup_int(:gauge, lane, :duration_ms), lookup_int(:gauge, lane, :execution_ms)),
      acknowledgement_ms: lookup_int(:gauge, lane, :acknowledgement_ms)
    }
  end

  defp lane_capacity(:flow_attribution) do
    limits = FlowLane.limits()
    {Keyword.fetch!(limits, :max_items), Keyword.fetch!(limits, :max_bytes)}
  end

  defp lane_capacity(:retained_plugin_result) do
    limits = RetainedPluginLane.limits()
    {Keyword.fetch!(limits, :max_items), Keyword.fetch!(limits, :max_bytes)}
  end

  defp lane_capacity(:sweep) do
    limits = SweepQueue.limits()
    {Keyword.fetch!(limits, :max_items), Keyword.fetch!(limits, :max_bytes)}
  end

  defp lane_capacity(:sync) do
    opts = Application.get_env(:serviceradar_core, SyncIngestorQueue, [])
    {Keyword.get(opts, :max_items, 64), Keyword.get(opts, :max_bytes, 64 * 1_024 * 1_024)}
  end

  defp lane_capacity(:service_state) do
    {
      Application.get_env(:serviceradar_core, :results_router_max_buffer, 200),
      Application.get_env(:serviceradar_core, :results_router_max_bytes, 32 * 1_024 * 1_024)
    }
  end

  defp lane_capacity(lane) do
    limits = LaneSupervisor.limits(lane)
    {Keyword.fetch!(limits, :max_items), Keyword.fetch!(limits, :max_bytes)}
  end

  defp lookup_int(kind, lane, name) do
    case :ets.lookup(@table, {kind, lane, name}) do
      [{_key, {value, _sampled_at}}] when is_number(value) -> trunc(value)
      [{_key, value}] when is_number(value) -> trunc(value)
      _ -> 0
    end
  end
end
