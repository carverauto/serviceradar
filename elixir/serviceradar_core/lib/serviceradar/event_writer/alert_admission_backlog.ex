defmodule ServiceRadar.EventWriter.AlertAdmissionBacklog do
  @moduledoc """
  The durable backlog that makes alert-evaluation backpressure lag, never loss.

  EventWriter stores a signal before it admits the signal's records to stateful
  alert evaluation. When admission is refused for capacity (`{:overloaded,
  dimension}`) or during a rolling restart (`:alert_evaluation_peer_not_ready`),
  `admit/3` defers the refused records instead of failing the batch: their
  immutable admission snapshots are written to
  `platform.lifecycle_pending_admissions`, and the JetStream message is
  acknowledged once that transaction commits. A refusal therefore never
  consumes a JetStream delivery and can never reach the terminal one. Genuine
  failures (an unavailable store, a failed write) still fail the batch.

  Each signal (`:event`, `:metric`) is one FIFO lane ordered by `seq`. While a
  lane holds rows, new records join behind them instead of being admitted
  ahead, and the batch that joined admits one chunk from the head, so the
  backlog drains as traffic arrives.
  `ServiceRadar.EventWriter.LifecycleAdmissionDrainWorker` drains it when no
  traffic does. A chunk is the head's first
  `Inbox.limits/0` `batch_records` rows, admitted in one call inside one
  transaction that deletes the rows only when every record was accepted. The
  inbox commits the in-order prefix of a refused chunk and deduplicates it on
  retry, so a retry admits exactly the remainder, still in order. One drainer
  holds a lane at a time; a busy lane is left to its holder.

  Lifecycle occurrences share the table in the `lifecycle` lane, keyed by
  series, and are owned by `ServiceRadar.EventWriter.Processors.AnalyticsSignals`.
  The table and the drain worker keep their lifecycle-only names so that pods
  of the previous release keep working during a rolling upgrade (see migration
  `20261105100000_add_lanes_to_lifecycle_pending_admissions`).

  Nothing caps the backlog and nothing in it is truncated; it is bounded by the
  CNPG volume. `report/0` publishes its size and age per lane and records the
  `alert-admission-backlog` core health check, which turns unhealthy once the
  oldest row has waited 10 minutes or the backlog reaches 100,000 rows.
  """

  alias ServiceRadar.Ingestion.RuntimeMetrics
  alias ServiceRadar.Observability.AdvisoryLocks
  alias ServiceRadar.Observability.StatefulAlertEngine.Inbox
  alias ServiceRadar.Observability.StatefulAlertEngine.Input
  alias ServiceRadar.Observability.StatefulEvaluationLedger
  alias ServiceRadar.Observability.TripwireHealth
  alias ServiceRadar.Repo

  require Logger

  @type signal :: :event | :metric

  @signals [:event, :metric]
  @lanes ["lifecycle", "event", "metric"]
  @lane_lock_prefix "alert-admission-backlog:lane:v1:"
  @health_check "alert-admission-backlog"
  @unhealthy_oldest_ms 600_000
  @unhealthy_count 100_000
  @drain_budget_ms 30_000

  @doc """
  Whether a refusal is transient backpressure that the backlog absorbs. Every
  other refusal is a genuine failure of the batch.
  """
  @spec retryable?(term()) :: boolean()
  def retryable?(:alert_evaluation_peer_not_ready), do: true
  def retryable?({:overloaded, _dimension}), do: true
  def retryable?(_reason), do: false

  @doc """
  Admits `records` to stateful evaluation, or defers them to the backlog.

  Records are admitted directly while their lane is empty. A retryable refusal,
  or a lane that already holds a backlog, defers them. Returns `:ok` once they
  are admitted, deferred, or skipped because alert evaluation is not activated;
  `{:error, reason}` only for a genuine failure, so the caller fails its batch.

  Options:

    * `:after_admission` - zero-arity function for the caller's own
      consequences of a first admission. It runs once the records are admitted,
      or before the deferral is written, and an `{:error, _}` result fails the
      call.
    * `:record` - zero-arity function that marks the records handled. It runs
      after `:after_admission` once the records are admitted, and inside the
      deferral's transaction when they are deferred, so a redelivery finds them
      either admitted or queued, never neither.
  """
  @spec admit(signal(), [map()], keyword()) :: :ok | {:error, term()}
  def admit(signal, records, opts \\ [])

  def admit(signal, [], _opts) when signal in @signals, do: :ok

  def admit(signal, records, opts) when signal in @signals and is_list(records) do
    if pending?(signal) do
      with :ok <- defer(signal, records, :behind_backlog, opts) do
        admit_head_after_joining(signal)
      end
    else
      case engine_admit(signal, records) do
        :ok ->
          with :ok <- run(opts, :after_admission), do: run(opts, :record)

        {:error, :alert_evaluation_not_activated} ->
          {:skipped, _count} = StatefulEvaluationLedger.skip_not_activated(records)
          :ok

        {:error, reason} ->
          if retryable?(reason),
            do: defer(signal, records, reason, opts),
            else: {:error, reason}
      end
    end
  end

  @doc "Whether `signal`'s lane holds any deferred record."
  @spec pending?(signal()) :: boolean()
  def pending?(signal) when signal in @signals do
    %{rows: [[pending?]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM platform.lifecycle_pending_admissions WHERE lane = $1)",
        [lane(signal)]
      )

    pending?
  end

  @doc """
  Admits the head chunk of `signal`'s lane. Returns `{:ok, admitted}`,
  `{:refused, reason}` when admission is still refused (the rows stay, and the
  accepted prefix is kept), `:busy` when another drainer holds the lane, or
  `{:error, reason}`.
  """
  @spec admit_head(signal()) ::
          {:ok, non_neg_integer()} | {:refused, term()} | :busy | {:error, term()}
  def admit_head(signal) when signal in @signals do
    limit = Inbox.limits().batch_records

    fn ->
      Repo.transaction(fn ->
        case AdvisoryLocks.try_acquire_ordered([@lane_lock_prefix <> lane(signal)]) do
          :ok -> admit_locked_head(signal, limit)
          {:error, {:advisory_locks_busy, _keys}} -> :busy
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
    |> Inbox.with_notification_queue()
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @doc """
  Drains each deferred lane from its head, chunk by chunk, until it is empty,
  refused, held by another drainer, or `:budget_ms` (default 30 seconds) has
  elapsed. Returns the number of records admitted.
  """
  @spec drain(keyword()) :: non_neg_integer()
  def drain(opts \\ []) do
    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :budget_ms, @drain_budget_ms)

    Enum.reduce(@signals, 0, &drain_lane(&1, deadline, &2))
  end

  @doc """
  Pending rows and the age of the oldest, per lane (`"lifecycle"`, `"event"`,
  `"metric"`), with `pending_count` and `oldest_pending_ms` zero for an empty
  lane.
  """
  @spec sample() :: {:ok, %{String.t() => map()}} | {:error, term()}
  def sample do
    case Repo.query("""
         SELECT lane, count(*),
                greatest(extract(epoch FROM (now() - min(inserted_at))) * 1000, 0)::bigint
         FROM platform.lifecycle_pending_admissions
         GROUP BY lane
         """) do
      {:ok, %{rows: rows}} ->
        sampled =
          Map.new(rows, fn [lane, count, oldest] ->
            {lane, %{pending_count: count, oldest_pending_ms: oldest}}
          end)

        {:ok,
         Map.new(@lanes, fn lane ->
           {lane, Map.get(sampled, lane, %{pending_count: 0, oldest_pending_ms: 0})}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Samples the backlog and reports it: a
  `[:serviceradar, :event_writer, :alert_admission_backlog]` telemetry event
  per lane, the `alert_admission_backlog` ingestion-lane gauges published
  through JetStream, and the `alert-admission-backlog` core health check.
  """
  @spec report() :: :ok | {:error, term()}
  def report do
    case sample() do
      {:ok, lanes} ->
        Enum.each(lanes, fn {lane, measurements} ->
          :telemetry.execute(
            [:serviceradar, :event_writer, :alert_admission_backlog],
            measurements,
            %{lane: lane}
          )
        end)

        total = lanes |> Map.values() |> Enum.map(& &1.pending_count) |> Enum.sum()
        oldest = lanes |> Map.values() |> Enum.map(& &1.oldest_pending_ms) |> Enum.max()

        RuntimeMetrics.record(:alert_admission_backlog, :state, %{
          pending_count: total,
          oldest_pending_ms: oldest
        })

        record_health(total, oldest, lanes)

      {:error, reason} ->
        Logger.warning("Could not sample the alert admission backlog",
          reason: inspect(reason, limit: 10, printable_limit: 500)
        )

        {:error, reason}
    end
  end

  @doc """
  Restores a stored admission snapshot to the record the engine receives. Keys
  the snapshot names as record fields become atoms again; any other key stays
  text, so restoring never creates an atom.
  """
  @spec restore(map()) :: map()
  def restore(snapshot) when is_map(snapshot) do
    snapshot
    |> Input.restore_record()
    |> Map.new(fn
      {key, value} when is_binary(key) -> {existing_atom(key), value}
      entry -> entry
    end)
  end

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp record_health(total, oldest, lanes) do
    healthy? = total < @unhealthy_count and oldest < @unhealthy_oldest_ms

    if not healthy? do
      Logger.warning("Alert admission backlog is lagging",
        pending_count: total,
        oldest_pending_ms: oldest
      )
    end

    TripwireHealth.record(@health_check, healthy?, %{
      "pending_count" => total,
      "oldest_pending_ms" => oldest,
      "unhealthy_count" => @unhealthy_count,
      "unhealthy_oldest_ms" => @unhealthy_oldest_ms,
      "lanes" => Map.new(lanes, fn {lane, measurements} -> {lane, measurements.pending_count} end)
    })
  end

  defp drain_lane(signal, deadline, admitted) do
    if System.monotonic_time(:millisecond) >= deadline do
      admitted
    else
      case admit_head(signal) do
        {:ok, 0} ->
          admitted

        {:ok, count} ->
          drain_lane(signal, deadline, admitted + count)

        {:refused, _reason} ->
          admitted

        :busy ->
          admitted

        {:error, reason} ->
          Logger.warning("Could not drain the alert admission backlog",
            lane: lane(signal),
            reason: inspect(reason, limit: 10, printable_limit: 500)
          )

          admitted
      end
    end
  end

  # The batch that joined a backlog admits one chunk from its head in place of
  # the direct admission it skipped, so a lane drains as traffic arrives. Its
  # own records are already durable, so the outcome never fails the batch.
  defp admit_head_after_joining(signal) do
    case admit_head(signal) do
      {:error, reason} ->
        Logger.warning("Could not admit the alert admission backlog head",
          lane: lane(signal),
          reason: inspect(reason, limit: 10, printable_limit: 500)
        )

      _admitted_refused_or_busy ->
        :ok
    end

    :ok
  end

  defp admit_locked_head(signal, limit) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT occurrence_id, occurrence
        FROM platform.lifecycle_pending_admissions
        WHERE lane = $1
        ORDER BY seq
        LIMIT $2
        """,
        [lane(signal), limit]
      )

    case rows do
      [] ->
        {:ok, 0}

      rows ->
        ids = Enum.map(rows, &hd/1)
        records = Enum.map(rows, fn [_id, occurrence] -> restore(occurrence) end)

        case engine_admit(signal, records) do
          :ok ->
            release(ids)

          {:error, :alert_evaluation_not_activated} ->
            {:skipped, _count} = StatefulEvaluationLedger.skip_not_activated(records)
            release(ids)

          {:error, reason} ->
            # A capacity refusal commits the prefix the inbox accepted and keeps
            # the rows for the retry that continues it. Any other refusal
            # accepted nothing and rolls back.
            if retryable?(reason), do: {:refused, reason}, else: Repo.rollback(reason)
        end
    end
  end

  defp release(ids) do
    Repo.query!(
      "DELETE FROM platform.lifecycle_pending_admissions WHERE occurrence_id = ANY($1::uuid[])",
      [ids]
    )

    {:ok, length(ids)}
  end

  defp defer(signal, records, reason, opts) do
    with :ok <- run(opts, :after_admission),
         {:ok, deferred} <- write(signal, records, Keyword.get(opts, :record)) do
      :telemetry.execute(
        [:serviceradar, :event_writer, :alert_admission, :deferred],
        %{count: deferred},
        %{lane: lane(signal), reason: reason_class(reason)}
      )

      Logger.debug("Deferred alert admission to the durable backlog",
        lane: lane(signal),
        count: deferred,
        reason: inspect(reason)
      )

      :ok
    end
  end

  # Each record gets its own row in input order, so `seq` is the lane's FIFO. A
  # record already pending conflicts on its occurrence id and changes nothing.
  defp write(signal, records, record) do
    entries = Enum.flat_map(records, &entry(signal, &1))

    Repo.transaction(fn ->
      if entries != [] do
        Repo.query!(
          """
          INSERT INTO platform.lifecycle_pending_admissions (
            occurrence_id, lane, event_time, event_id, occurrence
          )
          SELECT occurrence_id, $1, event_time, event_id, occurrence::jsonb
          FROM unnest($2::uuid[], $3::timestamptz[], $4::uuid[], $5::text[]) WITH ORDINALITY
            AS entry(occurrence_id, event_time, event_id, occurrence, position)
          ORDER BY position
          ON CONFLICT (occurrence_id) DO NOTHING
          """,
          [lane(signal) | Enum.map(0..3, fn index -> Enum.map(entries, &elem(&1, index)) end)]
        )
      end

      case run_record(record) do
        :ok -> length(entries)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  rescue
    error -> {:error, error}
  end

  defp run_record(nil), do: :ok
  defp run_record(record) when is_function(record, 0), do: record.()

  # The snapshot is exactly the payload the inbox accepts for this record,
  # validated now so a stored row is always admittable. A record that cannot be
  # encoded could never be admitted at all; it is logged and counted, and its
  # stored signal is unaffected.
  defp entry(signal, record) do
    case Input.prepare(signal, record) do
      {:ok, %{source_key: source_key, payload: payload}} ->
        <<occurrence_id::binary-size(16), _rest::binary>> = :crypto.hash(:sha256, source_key)

        [
          {occurrence_id, snapshot_time(payload), event_id(record, occurrence_id),
           Jason.encode!(payload)}
        ]

      {:error, reason} ->
        :telemetry.execute(
          [:serviceradar, :event_writer, :alert_admission, :unadmittable],
          %{count: 1},
          %{lane: lane(signal)}
        )

        Logger.warning("Skipping alert evaluation for an unencodable record",
          lane: lane(signal),
          reason: inspect(reason, limit: 10, printable_limit: 200)
        )

        []
    end
  end

  defp snapshot_time(payload) do
    with value when is_binary(value) <- payload["time"] || payload["timestamp"],
         {:ok, time, _offset} <- DateTime.from_iso8601(value) do
      time
    else
      _ -> DateTime.utc_now()
    end
  end

  defp event_id(record, fallback) do
    case Ecto.UUID.dump(to_string(Map.get(record, :id))) do
      {:ok, id} -> id
      :error -> fallback
    end
  end

  defp engine_admit(:event, records),
    do: StatefulEvaluationLedger.engine().evaluate_events(records)

  defp engine_admit(:metric, records),
    do: StatefulEvaluationLedger.engine().evaluate_metrics(records)

  defp run(opts, key) do
    case Keyword.get(opts, key) do
      nil -> :ok
      fun when is_function(fun, 0) -> fun.()
    end
  end

  defp lane(:event), do: "event"
  defp lane(:metric), do: "metric"

  defp reason_class(:behind_backlog), do: :behind_backlog
  defp reason_class(:alert_evaluation_peer_not_ready), do: :peer_not_ready
  defp reason_class({:overloaded, dimension}), do: dimension
end
