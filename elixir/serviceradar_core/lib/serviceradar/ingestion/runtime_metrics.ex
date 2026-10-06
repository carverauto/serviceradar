defmodule ServiceRadar.Ingestion.RuntimeMetrics do
  @moduledoc """
  Publishes bounded ingestion lane metrics through JetStream for EventWriter
  persistence.

  Producers update a fixed set of ETS slots; they never enqueue a metric message
  or wait for NATS. During an outage, gauges coalesce and event counts
  accumulate. Each frame reports gauges at their latest values and counters as
  deltas since the previous acknowledged frame; reporting watermarks advance
  only on PubAck. No agent, device, run, or payload identifier becomes a label.
  """
  use GenServer

  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias Serviceradar.Metric.V1.StringMapEntry
  alias ServiceRadar.NATS.JetStreamPublish

  @table __MODULE__
  @subject "metrics.ingestion_lanes"
  @lanes [
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
    :cancellation,
    :delivery,
    :publish_failure,
    :coalesced_interval,
    :crash,
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
    :payload_bytes
  ]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

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
        :ets.insert(@table, {{:gauge, lane, name}, value})

      _ ->
        :ok
    end)

    :ok
  rescue
    ArgumentError -> :ok
  end

  def record(_lane, _event, _measurements), do: :ok

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    interval = Keyword.get(opts, :interval_ms, 1_000)

    if !(is_integer(interval) and interval > 0) do
      raise ArgumentError, "invalid metric cadence"
    end

    Process.send_after(self(), :publish, interval)

    {:ok,
     %{
       interval: interval,
       publish_opts: Keyword.get(opts, :publish_opts, []),
       pending: nil,
       reported: %{},
       interval_start: System.system_time(:nanosecond)
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
        frame(:ets.tab2list(@table), state.reported, state.interval_start, now)

    {pending, reported, interval_start} =
      case frame do
        nil ->
          {nil, state.reported, state.interval_start}

        {body, id, counters, frame_start} ->
          opts = Keyword.merge(state.publish_opts, timeout: 1_000, msg_id: id)

          case publish(body, opts) do
            :ok ->
              {nil, counters, frame_start}

            {:error, _} ->
              record(:service_state, :publish_failure, %{})
              {{body, id, counters, frame_start}, state.reported, state.interval_start}
          end
      end

    Process.send_after(self(), :publish, state.interval)
    {:noreply, %{state | pending: pending, reported: reported, interval_start: interval_start}}
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
  defp delta(value, kind, lane, name, reported), do: value - Map.get(reported, {kind, lane, name}, 0)

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

  defp unit(:gauge, name) when name in [:pending_count, :in_flight_count], do: "entries"
  defp unit(:gauge, _name), do: "ms"
end
