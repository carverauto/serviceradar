defmodule ServiceRadar.Inventory.ExposureTransitionRelay do
  @moduledoc """
  Relays exposure transitions from the transactional outbox to JetStream
  (OpenSpec `add-srql-exposure-intelligence`, *Assessment Transitions Are
  Published On JetStream*).

  Triggers on `platform.endpoint_vulnerability_assessments` write one row to
  `platform.exposure_transition_outbox` per transition, in the transaction that
  changed the assessment, so a rolled-back change never reaches the outbox. This
  process publishes those rows and deletes each one only after the stream
  acknowledged it: delivery is at least once. Each message carries the
  `Nats-Msg-Id` `exposure-transition-<transition_seq>`, so the stream's
  duplicate window stores a repeated publish once, and a consumer applies a
  transition only when its `transition_seq` is greater than the one it holds.

  Messages go to `vulnerability.assessment.transitions.<bucket>`, where the
  bucket (0-15) is a hash of the device uid, in the `EXPOSURE_TRANSITIONS`
  stream: limits retention, file storage, one replica, `max_age` 7 days and a
  `max_bytes` from the JetStream sizing profile
  (`SERVICERADAR_JS_EXPOSURE_TRANSITIONS_MAX_BYTES`). The relay creates the
  stream, or reconciles an existing stream's `max_bytes` to the configured
  size, when it starts and whenever a publish fails.

  Health: every report interval the relay publishes
  `exposure_transition_outbox_oldest_age_seconds`,
  `exposure_transition_outbox_pending` (counted up to a cap) and
  `exposure_transitions_relayed` on `metrics.exposure_transitions`, and records
  a health state change for `exposure_transition_outbox` when the oldest
  unrelayed row crosses the age bound (default 10 minutes) in either direction.

  It runs as a coordinator child, so one relay is active per cluster. A second
  one would only repeat publishes the stream deduplicates.
  """

  use GenServer

  import Ecto.Query

  alias ServiceRadar.Infrastructure.HealthTracker
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.NATS.JetstreamConsumer
  alias ServiceRadar.NATS.JetStreamPublish
  alias ServiceRadar.Repo

  require Logger

  @stream_name "EXPOSURE_TRANSITIONS"
  @subject_prefix "vulnerability.assessment.transitions"
  @subject_wildcard "#{@subject_prefix}.>"
  @buckets 16
  @metrics_subject "metrics.exposure_transitions"
  @health_entity "exposure_transition_outbox"

  @default_batch_size 500
  @default_max_concurrency 16
  @default_poll_interval_ms 1_000
  @default_report_interval_ms 60_000
  @default_age_bound_seconds 600
  @default_max_bytes 1_073_741_824
  @max_age_ns 7 * 86_400 * 1_000_000_000
  @duplicate_window_ns 120_000_000_000
  @pending_count_cap 100_000

  @type relay_result :: %{relayed: non_neg_integer(), failed: non_neg_integer(), full?: boolean()}

  @doc "The stream that captures exposure transitions."
  @spec stream_name() :: String.t()
  def stream_name, do: @stream_name

  @doc "The subject a transition for `device_uid` is published on."
  @spec subject(String.t()) :: String.t()
  def subject(device_uid) when is_binary(device_uid),
    do: "#{@subject_prefix}.#{:erlang.phash2(device_uid, @buckets)}"

  @doc "The stream's `max_bytes` when the sizing variable is unset (1 GiB)."
  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    opts = Keyword.merge(Application.get_env(:serviceradar_core, __MODULE__, []), opts)
    send(self(), :relay)
    Process.send_after(self(), :report, report_interval(opts))
    {:ok, %{opts: opts, relayed: 0, degraded?: false, stream_ready?: false}}
  end

  @impl GenServer
  def handle_info(:relay, state) do
    state = %{state | stream_ready?: state.stream_ready? or stream_ready?(state.opts)}

    {result, state} =
      case relay_once(state.opts) do
        {:ok, result} -> {result, %{state | relayed: state.relayed + result.relayed}}
        {:error, _reason} -> {%{full?: false}, state}
      end

    delay =
      if result.full?,
        do: 0,
        else: Keyword.get(state.opts, :poll_interval_ms, @default_poll_interval_ms)

    Process.send_after(self(), :relay, delay)
    {:noreply, state}
  end

  def handle_info(:report, state) do
    Process.send_after(self(), :report, report_interval(state.opts))
    {:noreply, report(state)}
  end

  @doc """
  Publishes one batch of outbox rows, oldest first, and deletes the ones the
  stream acknowledged. A row whose publish failed stays for the next attempt.
  When a publish finds no stream, the stream is created and the rest wait for
  the next batch.

  Options (tests): `:batch_size`, `:max_concurrency`, `:publish`
  (`(subject, body, opts) -> :ok | {:error, term}`) and `:ensure_stream`
  (`(opts) -> :ok | {:error, term}`).
  """
  @spec relay_once(keyword()) :: {:ok, relay_result()} | {:error, term()}
  def relay_once(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    rows =
      Repo.all(
        from(o in "exposure_transition_outbox",
          order_by: [asc: o.id],
          limit: ^batch_size,
          select: %{
            id: o.id,
            transition_seq: o.transition_seq,
            device_uid: o.device_uid,
            payload: fragment("?::text", o.payload)
          }
        ),
        prefix: "platform"
      )

    {acked, failures} = publish_rows(rows, opts)
    delete_acked(acked)
    maybe_ensure_stream(failures, opts)

    {:ok,
     %{
       relayed: length(acked),
       failed: length(failures),
       full?: length(rows) == batch_size and failures == []
     }}
  rescue
    error ->
      Logger.warning("Exposure transition relay failed: #{Exception.message(error)}")
      {:error, error}
  end

  defp publish_rows([], _opts), do: {[], []}

  defp publish_rows(rows, opts) do
    publish = Keyword.get(opts, :publish, &JetStreamPublish.publish/3)

    rows
    |> Task.async_stream(
      fn row ->
        {row.id,
         publish.(subject(row.device_uid), row.payload,
           msg_id: "exposure-transition-#{row.transition_seq}"
         )}
      end,
      max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce({[], []}, fn
      {:ok, {id, :ok}}, {acked, failures} -> {[id | acked], failures}
      {:ok, {_id, {:error, reason}}}, {acked, failures} -> {acked, [reason | failures]}
      {:exit, reason}, {acked, failures} -> {acked, [reason | failures]}
    end)
  end

  defp delete_acked([]), do: :ok

  defp delete_acked(ids) do
    Repo.delete_all(
      from(o in "exposure_transition_outbox", where: o.id in ^ids),
      prefix: "platform"
    )

    :ok
  end

  defp stream_ready?(opts) do
    case ensure_stream(opts) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning("Exposure transition stream could not be ensured", reason: inspect(reason))
        false
    end
  end

  defp maybe_ensure_stream([], _opts), do: :ok

  defp maybe_ensure_stream([reason | _rest], opts) do
    ensure = Keyword.get(opts, :ensure_stream, &ensure_stream/1)

    case ensure.(opts) do
      :ok ->
        Logger.info("Exposure transition publish failed; stream ensured", reason: inspect(reason))

      {:error, ensure_reason} ->
        Logger.warning("Exposure transition publish failed and the stream could not be ensured",
          reason: inspect(reason),
          ensure_reason: inspect(ensure_reason)
        )
    end
  end

  @doc """
  Creates the `EXPOSURE_TRANSITIONS` stream when it is absent, or reconciles
  the existing stream's `max_bytes` to the configured size (`:max_bytes`,
  default 1 GiB). A stream of this name that does not capture
  `vulnerability.assessment.transitions.>` is reported as
  `{:stream_config_conflict, _}`.
  """
  @spec ensure_stream(keyword()) :: :ok | {:error, term()}
  def ensure_stream(opts \\ []) do
    domain = Keyword.get(opts, :domain)

    case JetstreamConsumer.stream_info(&request/2, @stream_name, domain) do
      {:ok, config, stored} -> reconcile_stream(config, stored, opts)
      :absent -> create_stream(opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_stream(config, stored, opts) do
    if @subject_wildcard in List.wrap(Map.get(config, "subjects")) do
      configured = Map.put(config, "max_bytes", max_bytes(opts))

      payload =
        JetstreamConsumer.hold_discard_new_max_bytes(@stream_name, config, configured, stored)

      JetstreamConsumer.update_stream_if_changed(
        &request/2,
        @stream_name,
        config,
        payload,
        stored,
        Keyword.get(opts, :domain)
      )
    else
      {:error,
       {:stream_config_conflict,
        "stream #{@stream_name} does not capture #{@subject_wildcard}: " <>
          inspect(Map.get(config, "subjects"))}}
    end
  end

  defp create_stream(opts) do
    payload =
      Jason.encode!(%{
        name: @stream_name,
        subjects: [@subject_wildcard],
        retention: "limits",
        storage: "file",
        discard: "old",
        num_replicas: 1,
        max_age: @max_age_ns,
        max_bytes: max_bytes(opts),
        duplicate_window: @duplicate_window_ns
      })

    subject =
      JetstreamConsumer.js_api(Keyword.get(opts, :domain)) <> ".STREAM.CREATE." <> @stream_name

    case request(subject, payload) do
      {:ok, _created} -> :ok
      {:error, reason} -> {:error, {:jetstream, reason}}
    end
  end

  defp request(subject, payload) do
    with {:ok, conn} <- Connection.get(),
         {:ok, %{body: body}} <- Gnat.request(conn, subject, payload, receive_timeout: 5_000),
         {:ok, decoded} <- Jason.decode(body) do
      case decoded do
        %{"error" => error} -> {:error, error}
        decoded -> {:ok, decoded}
      end
    end
  end

  defp max_bytes(opts), do: Keyword.get(opts, :max_bytes, @default_max_bytes)

  @doc "Seconds since the oldest unrelayed outbox row was written, or 0 when the outbox is empty."
  @spec oldest_age_seconds(DateTime.t()) :: non_neg_integer()
  def oldest_age_seconds(%DateTime{} = now) do
    case Repo.one(
           from(o in "exposure_transition_outbox",
             order_by: [asc: o.id],
             limit: 1,
             select: o.inserted_at
           ),
           prefix: "platform"
         ) do
      nil ->
        0

      %NaiveDateTime{} = inserted_at ->
        max(0, NaiveDateTime.diff(DateTime.to_naive(now), inserted_at, :second))
    end
  end

  defp report(state) do
    now = DateTime.utc_now()
    age = oldest_age_seconds(now)
    bound = Keyword.get(state.opts, :age_bound_seconds, @default_age_bound_seconds)
    pending = pending_count()

    publish_metrics(now, [
      {"exposure_transition_outbox_oldest_age_seconds", age},
      {"exposure_transition_outbox_pending", pending},
      {"exposure_transitions_relayed", state.relayed}
    ])

    %{state | relayed: 0, degraded?: record_health(state.degraded?, age > bound, age, bound)}
  rescue
    error ->
      Logger.warning("Exposure transition outbox report failed: #{Exception.message(error)}")
      state
  end

  defp pending_count do
    Repo.one(
      from(
        o in subquery(
          from(o in "exposure_transition_outbox", limit: ^@pending_count_cap, select: o.id)
        ),
        select: count()
      ),
      prefix: "platform"
    )
  end

  # Edge-triggered: one health event when the bound is crossed, one when the
  # outbox recovers.
  defp record_health(degraded?, degraded?, _age, _bound), do: degraded?

  defp record_health(was_degraded?, degraded?, age, bound) do
    HealthTracker.record_state_change(:custom, @health_entity,
      old_state: health_state(was_degraded?),
      new_state: health_state(degraded?),
      reason: if(degraded?, do: :outbox_relay_lagging, else: :outbox_relay_caught_up),
      metadata: %{"oldest_age_seconds" => age, "age_bound_seconds" => bound}
    )

    if degraded? do
      Logger.warning("Exposure transition outbox is behind",
        oldest_age_seconds: age,
        age_bound_seconds: bound
      )
    end

    degraded?
  end

  defp health_state(true), do: :degraded
  defp health_state(false), do: :healthy

  defp publish_metrics(now, metrics) do
    observed_at = DateTime.to_unix(now, :nanosecond)

    body =
      MetricBatch.encode(%MetricBatch{
        schema_version: "serviceradar.metric.v1",
        resource: %MetricResource{service_name: "core", service_type: "exposure_transitions"},
        ingest_identity: %IngestIdentity{
          source: "exposure-transition-relay",
          payload_kind: "metrics",
          producer_kind: "core"
        },
        emitted_at_unix_nano: observed_at,
        metrics:
          Enum.map(metrics, fn {name, value} ->
            %Metric{
              name: name,
              kind: :METRIC_KIND_GAUGE,
              tags: [],
              points: [%MetricPoint{value: value * 1.0, observed_at_unix_nano: observed_at}]
            }
          end)
      })

    case JetStreamPublish.publish(@metrics_subject, body, timeout: 1_000) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("Exposure transition metrics publish failed", reason: inspect(reason))
    end
  end

  defp report_interval(opts),
    do: Keyword.get(opts, :report_interval_ms, @default_report_interval_ms)
end
