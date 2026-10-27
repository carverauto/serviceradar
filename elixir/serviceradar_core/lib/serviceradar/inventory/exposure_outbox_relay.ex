defmodule ServiceRadar.Inventory.ExposureOutboxRelay do
  @moduledoc """
  Shared acknowledged-outbox transport for exposure transitions and dimensions.
  Each owner supplies its table, routing field, stream subjects and metric family.
  Immutable rows are deleted only after PubAck; retries keep payloads and ids.
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

  @default_batch_size 500
  @default_max_concurrency 16
  @default_poll_interval_ms 1_000
  @default_report_interval_ms 60_000
  @default_age_bound_seconds 600
  @max_age_ns 7 * 86_400 * 1_000_000_000
  @duplicate_window_ns 120_000_000_000
  @pending_count_cap 100_000

  @type relay_result :: %{relayed: non_neg_integer(), failed: non_neg_integer(), full?: boolean()}

  def start_link(owner, opts) do
    opts = opts |> Keyword.put(:owner, owner) |> Keyword.put(:spec, owner.spec())
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, owner))
  end

  @impl GenServer
  def init(opts) do
    send(self(), :relay)
    Process.send_after(self(), :report, report_interval(opts))

    {:ok,
     %{opts: opts, relayed: 0, degraded?: false, stream_degraded?: false, stream_ready?: false}}
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
  def relay_once(opts) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    spec = Keyword.fetch!(opts, :spec)

    rows =
      spec.table
      |> eligible_rows()
      |> then(fn query ->
        Repo.all(
          from(o in query,
            order_by: [asc: o.id],
            limit: ^batch_size,
            select: %{
              id: o.id,
              transition_seq: o.transition_seq,
              route: field(o, ^spec.routing_field),
              payload: fragment("?::text", o.payload)
            }
          ),
          prefix: "platform"
        )
      end)

    {acked, failures} = publish_rows(rows, opts)
    delete_acked(acked, spec.table)
    maybe_ensure_stream(failures, opts)

    {:ok,
     %{
       relayed: length(acked),
       failed: length(failures),
       full?: length(rows) == batch_size and failures == []
     }}
  rescue
    error ->
      Logger.warning("Exposure outbox relay failed: #{Exception.message(error)}")
      {:error, error}
  end

  # PubAck the lifecycle marker before its facts can occupy the consumer's
  # bounded pending window; otherwise deferred facts could hide their marker.
  defp eligible_rows("exposure_transition_outbox" = table) do
    from(o in table,
      where:
        fragment(
          """
          NOT EXISTS (
            SELECT 1 FROM platform.exposure_transition_outbox marker
            WHERE marker.transition_seq = (?->>'device_lifecycle_seq')::bigint
              AND marker.transition_seq <> ?
          )
          """,
          o.payload,
          o.transition_seq
        )
    )
  end

  defp eligible_rows(table), do: table

  defp publish_rows([], _opts), do: {[], []}

  defp publish_rows(rows, opts) do
    publish = Keyword.get(opts, :publish, &JetStreamPublish.publish/3)
    owner = Keyword.fetch!(opts, :owner)
    spec = Keyword.fetch!(opts, :spec)

    rows
    |> Task.async_stream(
      fn row ->
        {row.id,
         publish.(owner.subject(row.route), row.payload,
           msg_id: "#{spec.message_prefix}-#{row.transition_seq}"
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

  defp delete_acked([], _table), do: :ok

  defp delete_acked(ids, table) do
    Repo.delete_all(
      from(o in table, where: o.id in ^ids),
      prefix: "platform"
    )

    :ok
  end

  defp stream_ready?(opts) do
    case ensure_stream(opts) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning("Exposure outbox stream could not be ensured", reason: inspect(reason))
        false
    end
  end

  defp maybe_ensure_stream([], _opts), do: :ok

  defp maybe_ensure_stream([reason | _rest], opts) do
    ensure = Keyword.get(opts, :ensure_stream, &ensure_stream/1)

    case ensure.(opts) do
      :ok ->
        Logger.info("Exposure outbox publish failed; stream ensured", reason: inspect(reason))

      {:error, ensure_reason} ->
        Logger.warning("Exposure outbox publish failed and the stream could not be ensured",
          reason: inspect(reason),
          ensure_reason: inspect(ensure_reason)
        )
    end
  end

  def ensure_stream(opts) do
    spec = Keyword.fetch!(opts, :spec)
    domain = Keyword.get(opts, :domain)

    case JetstreamConsumer.stream_info(&request/2, spec.stream, domain) do
      {:ok, config, stored} -> reconcile_stream(config, stored, opts)
      :absent -> create_stream(opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_stream(config, stored, opts) do
    spec = Keyword.fetch!(opts, :spec)

    if Enum.sort(List.wrap(Map.get(config, "subjects"))) == Enum.sort(spec.subjects) do
      configured = Map.put(config, "max_bytes", max_bytes(opts))

      payload =
        JetstreamConsumer.hold_discard_new_max_bytes(spec.stream, config, configured, stored)

      JetstreamConsumer.update_stream_if_changed(
        &request/2,
        spec.stream,
        config,
        payload,
        stored,
        Keyword.get(opts, :domain)
      )
    else
      {:error, {:stream_config_conflict, "unexpected subjects for #{spec.stream}"}}
    end
  end

  defp create_stream(opts) do
    spec = Keyword.fetch!(opts, :spec)

    payload =
      Jason.encode!(%{
        name: spec.stream,
        subjects: spec.subjects,
        retention: "limits",
        storage: "file",
        discard: "old",
        num_replicas: 1,
        max_age: @max_age_ns,
        max_bytes: max_bytes(opts),
        duplicate_window: @duplicate_window_ns
      })

    subject =
      JetstreamConsumer.js_api(Keyword.get(opts, :domain)) <> ".STREAM.CREATE." <> spec.stream

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

  defp max_bytes(opts), do: Keyword.get(opts, :max_bytes, 1_073_741_824)

  defp oldest_age_seconds(now, spec) do
    case Repo.one(
           from(o in spec.table,
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
    spec = Keyword.fetch!(state.opts, :spec)
    age = oldest_age_seconds(now, spec)
    bound = Keyword.get(state.opts, :age_bound_seconds, @default_age_bound_seconds)
    pending = pending_count(spec)
    {stream_metrics, reason, metadata} = stream_report(now, spec, state.opts)

    publish_metrics(
      now,
      spec,
      [
        {"#{spec.table}_oldest_age_seconds", age},
        {"#{spec.table}_pending", pending},
        {"#{spec.metrics}_relayed", state.relayed}
      ] ++ stream_metrics
    )

    %{
      state
      | relayed: 0,
        degraded?: record_health(spec, state.degraded?, age > bound, age, bound),
        stream_degraded?: record_stream_health(spec, state.stream_degraded?, reason, metadata)
    }
  rescue
    error ->
      Logger.warning("Exposure outbox report failed: #{Exception.message(error)}")
      state
  end

  defp stream_report(now, spec, opts) do
    subject =
      JetstreamConsumer.js_api(Keyword.get(opts, :domain)) <> ".STREAM.INFO." <> spec.stream

    bound = div(@max_age_ns, 1_000_000_000)

    with {:ok, %{"config" => %{"max_age" => retention}, "state" => stream}} <-
           request(subject, "{}"),
         true <- is_integer(retention) and retention >= 0,
         {:ok, age} <- stream_age(stream, now) do
      reason =
        cond do
          age > bound -> :stream_age_exceeded
          retention == 0 or retention > @max_age_ns -> :stream_retention_unbounded
          true -> nil
        end

      metadata = %{
        "oldest_age_seconds" => age,
        "max_age_seconds" => retention / 1_000_000_000,
        "age_bound_seconds" => bound
      }

      metrics = [
        {"#{spec.metrics}_stream_oldest_age_seconds", age},
        {"#{spec.metrics}_stream_max_age_seconds", metadata["max_age_seconds"]}
      ]

      {metrics, reason, metadata}
    else
      # Missing or malformed status is unknown, never evidence of an empty stream.
      _ -> {[], :stream_health_unavailable, %{"age_bound_seconds" => bound}}
    end
  end

  defp stream_age(%{"messages" => 0}, _now), do: {:ok, 0}

  defp stream_age(%{"messages" => count, "first_ts" => timestamp}, now)
       when is_integer(count) and count > 0 and is_binary(timestamp) do
    with {:ok, first, _offset} <- DateTime.from_iso8601(timestamp) do
      {:ok, max(0, DateTime.diff(now, first, :second))}
    end
  end

  defp stream_age(_stream, _now), do: :error

  defp record_stream_health(spec, was_degraded?, reason, metadata) do
    degraded? = not is_nil(reason)

    if degraded? == was_degraded? do
      was_degraded?
    else
      case HealthTracker.record_state_change(:custom, spec.metrics <> "_stream",
             old_state: health_state(was_degraded?),
             new_state: health_state(degraded?),
             reason: reason || :stream_freshness_recovered,
             metadata: metadata
           ) do
        {:ok, _event} -> degraded?
        _error -> was_degraded?
      end
    end
  end

  defp pending_count(spec) do
    Repo.one(
      from(
        o in subquery(from(o in spec.table, limit: ^@pending_count_cap, select: o.id)),
        select: count()
      ),
      prefix: "platform"
    )
  end

  # Edge-triggered: one health event when the bound is crossed, one when the
  # outbox recovers.
  defp record_health(_spec, degraded?, degraded?, _age, _bound), do: degraded?

  defp record_health(spec, was_degraded?, degraded?, age, bound) do
    HealthTracker.record_state_change(:custom, spec.table,
      old_state: health_state(was_degraded?),
      new_state: health_state(degraded?),
      reason: if(degraded?, do: :outbox_relay_lagging, else: :outbox_relay_caught_up),
      metadata: %{"oldest_age_seconds" => age, "age_bound_seconds" => bound}
    )

    if degraded? do
      Logger.warning("Exposure outbox is behind",
        oldest_age_seconds: age,
        age_bound_seconds: bound
      )
    end

    degraded?
  end

  defp health_state(true), do: :degraded
  defp health_state(false), do: :healthy

  defp publish_metrics(now, spec, metrics) do
    observed_at = DateTime.to_unix(now, :nanosecond)

    body =
      MetricBatch.encode(%MetricBatch{
        schema_version: "serviceradar.metric.v1",
        resource: %MetricResource{service_name: "core", service_type: spec.metrics},
        ingest_identity: %IngestIdentity{
          source: spec.message_prefix <> "-relay",
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

    case JetStreamPublish.publish("metrics." <> spec.metrics, body, timeout: 1_000) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("Exposure outbox metrics publish failed", reason: inspect(reason))
    end
  end

  defp report_interval(opts),
    do: Keyword.get(opts, :report_interval_ms, @default_report_interval_ms)
end
