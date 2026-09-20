defmodule ServiceRadar.Analytics.StarRocks.PendingLoads do
  @moduledoc """
  Durable outbox for threshold-event Stream Loads that fail outside JetStream ACK.

  `Destination.persist_after_cnpg/3` fails the EventWriter ACK when a cutover
  dataset misses the warehouse, and the broker redelivers. Producers without
  a broker (Oban workers) have no redelivery: `persist_or_enqueue/3` gives
  them one by storing the failed batch's Stream Load documents in
  `platform.starrocks_pending_loads` and `drain_due/1` replays due rows on a
  later run. The warehouse copy is never silently dropped and the producing
  run is never blocked: both functions answer `:ok`-shaped tuples once the
  batch is durable, and a failing outbox is contained and reported as
  `{:error, {:quarantine_failed, _}}` rather than raised.

  Only `:events` is accepted. A replay carries the batch's stored label and
  nothing else, so a dataset whose Stream Load needs extra headers -
  `:flows` and `:flow_attribution` carry `merge_condition` and
  `partial_update` - would replay without them and overwrite newer rows.

  Replays are safe twice over. The warehouse tables are PRIMARY KEY models,
  so reloading the same rows converges on the same state, and every row
  carries the deterministic `StreamLoad` label, so the FE reconciles a load
  whose original response was lost instead of applying it twice. A
  `{:quarantine, _}` reply is terminal: the FE filtered poison rows that a
  retry would only filter again, so the row is dropped with a report.

  A batch that still fails after 25 replays is dead-lettered so the outbox
  cannot grow without bound; CNPG still holds the authoritative copy for a
  manual replay.
  """

  import Ecto.Query

  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Analytics.StarRocks.Rows
  alias ServiceRadar.Analytics.StarRocks.StreamLoad
  alias ServiceRadar.Repo

  require Logger

  @type dataset :: :events

  # Bounds one drain so a long outage's backlog clears progressively instead
  # of holding the producing run on dozens of sequential Stream Loads.
  @drain_limit 10

  # A replay runs after the producing worker has already alerted and
  # rescheduled, so it only holds an Oban slot; a short timeout keeps the
  # bounded worst case (limit x timeout) to a couple of minutes.
  @drain_http_timeout_ms 15_000

  # Long enough to cover a full drain pass at that worst case, so a batch a
  # live drain still holds is not due for anyone else. A drain killed
  # mid-pass releases its rows when the window lapses.
  @drain_claim_seconds 300

  # 60s, 5m, 25m, then hourly. The producing worker runs every minute, so a
  # fresh failure is retried on the next run and a dead FE backs off fast.
  @retry_base_seconds 60
  @retry_factor 5
  @retry_cap_seconds 3_600

  # At the hourly cap this is roughly a day of replays. A batch still failing
  # then is not a transient outage, and holding its payload forever is what
  # turns one dead FE into an unbounded table.
  @max_attempts 25

  defmodule Record do
    @moduledoc false
    use Ecto.Schema

    @schema_prefix "platform"

    schema "starrocks_pending_loads" do
      field :dataset, :string
      field :table_name, :string
      field :label, :string
      field :payload, :map
      field :attempts, :integer, default: 0
      field :next_retry_at, :naive_datetime_usec

      timestamps()
    end
  end

  @doc """
  Persists `rows` to the warehouse, quarantining the batch on failure.

  Forwards `opts` to `Destination.persist_after_cnpg/3` (notably `:persist`
  and `:http`). Answers `{:ok, :enqueued}` once a failed batch is durable;
  only a failing outbox itself answers `{:error, _}`.
  """
  @spec persist_or_enqueue(dataset(), [map()], keyword()) ::
          {:ok, map()} | {:ok, :disabled} | {:ok, :enqueued} | {:error, term()}
  def persist_or_enqueue(dataset, rows, opts \\ [])

  def persist_or_enqueue(:events = dataset, rows, opts) do
    case persist(dataset, rows, opts) do
      {:ok, _} = ok -> ok
      {:error, reason} -> enqueue_failed(dataset, rows, reason)
    end
  end

  @doc """
  Replays due quarantined batches, oldest first.

  Accepts `:persist` (default `&StreamLoad.persist/3`) and `:http` forwarded
  to it. At most #{@drain_limit} batches replay per call; per-batch failures
  defer the batch with backoff instead of failing the drain.
  """
  @spec drain_due(keyword()) ::
          {:ok,
           %{
             drained: non_neg_integer(),
             quarantined: non_neg_integer(),
             deferred: non_neg_integer(),
             dead_lettered: non_neg_integer(),
             skipped: non_neg_integer()
           }}
  def drain_due(opts \\ []) do
    empty = %{drained: 0, quarantined: 0, deferred: 0, dead_lettered: 0, skipped: 0}

    summary =
      Enum.reduce(claim_due(), empty, fn record, acc ->
        case drain_record(record, opts) do
          :drained -> %{acc | drained: acc.drained + 1}
          :quarantined -> %{acc | quarantined: acc.quarantined + 1}
          :deferred -> %{acc | deferred: acc.deferred + 1}
          :dead_lettered -> %{acc | dead_lettered: acc.dead_lettered + 1}
          :skipped -> %{acc | skipped: acc.skipped + 1}
        end
      end)

    {:ok, summary}
  end

  # Drains overlap by design: the producing worker queues its successor
  # before replaying, so a pass that outlives the run interval meets the next
  # one. Locking the due rows and pushing their next retry past a full pass
  # in one transaction leaves a concurrent drain a disjoint set.
  defp claim_due do
    now = NaiveDateTime.utc_now()

    {:ok, due} =
      Repo.transaction(fn ->
        due =
          Repo.all(
            from(r in Record,
              where: r.next_retry_at <= ^now,
              order_by: [asc: r.inserted_at],
              limit: @drain_limit,
              lock: "FOR UPDATE SKIP LOCKED"
            )
          )

        ids = Enum.map(due, & &1.id)
        claimed_until = NaiveDateTime.add(now, @drain_claim_seconds, :second)

        Repo.update_all(from(r in Record, where: r.id in ^ids),
          set: [next_retry_at: claimed_until]
        )

        due
      end)

    due
  end

  # One record's failure costs that record, not the rest of the pass. The
  # exception type alone is logged: `Ecto.StaleEntryError` renders the whole
  # struct, payload rows included.
  defp drain_record(%Record{} = record, opts) do
    attempt_drain(record, opts)
  rescue
    error ->
      Logger.error("StarRocks quarantined batch drain failed; row stays in the outbox",
        label: record.label,
        table: record.table_name,
        error: inspect(error.__struct__)
      )

      :skipped
  end

  defp persist(dataset, rows, opts) do
    Destination.persist_after_cnpg(dataset, rows, opts)
  rescue
    error ->
      # A crash leaves the load state unknown, but the deterministic label
      # makes a later replay safe, so quarantine first and report.
      Logger.error("StarRocks persist crashed; quarantining batch for replay",
        dataset: dataset,
        error: Exception.message(error),
        stacktrace: Exception.format_stacktrace(__STACKTRACE__)
      )

      {:error, {:crashed, Exception.message(error)}}
  end

  defp retry_after_seconds(attempts) when is_integer(attempts) and attempts >= 0 do
    min(@retry_base_seconds * Integer.pow(@retry_factor, attempts), @retry_cap_seconds)
  end

  # `Repo.insert/2` raises rather than returns on a pool checkout timeout, a
  # CNPG failover or a missing table, and the caller is a self-rescheduling
  # Oban job: an escaping exception would end the schedule chain. The outbox
  # is never re-entered from here.
  defp enqueue_failed(dataset, rows, reason) do
    encoded = Rows.encode(dataset, rows)
    table = Destination.table_for(dataset)
    label = StreamLoad.load_label(table, encoded)
    now = NaiveDateTime.utc_now()

    record = %Record{
      dataset: Atom.to_string(dataset),
      table_name: table,
      label: label,
      payload: %{"rows" => encoded},
      attempts: 0,
      next_retry_at: NaiveDateTime.add(now, retry_after_seconds(0), :second)
    }

    case Repo.insert(record, on_conflict: :nothing, conflict_target: :label) do
      {:ok, %{id: nil}} ->
        # Same deterministic label already pending: the batch is durable.
        Logger.debug("StarRocks failed batch already quarantined; keeping single row",
          dataset: dataset,
          label: label
        )

        {:ok, :enqueued}

      {:ok, _} ->
        Logger.error("StarRocks warehouse load failed; batch quarantined for replay",
          dataset: dataset,
          table: table,
          label: label,
          rows: length(encoded),
          error: inspect(reason)
        )

        :telemetry.execute(
          [:serviceradar, :starrocks, :pending_loads, :enqueued],
          %{rows: length(encoded)},
          %{dataset: dataset, table: table, label: label, reason: reason}
        )

        {:ok, :enqueued}
    end
  rescue
    error ->
      Logger.error("StarRocks warehouse load failed AND quarantine failed; batch lost",
        dataset: dataset,
        error: inspect(reason),
        quarantine_error: Exception.message(error)
      )

      {:error, {:quarantine_failed, reason}}
  end

  defp attempt_drain(%Record{} = record, opts) do
    rows = get_in(record.payload, ["rows"]) || []

    case replay(record, rows, opts) do
      {:ok, result} ->
        discard(record)

        Logger.info("StarRocks quarantined batch replayed",
          label: record.label,
          table: record.table_name,
          rows: length(rows)
        )

        :telemetry.execute(
          [:serviceradar, :starrocks, :pending_loads, :drained],
          %{rows: length(rows)},
          %{
            dataset: record.dataset,
            table: record.table_name,
            label: record.label,
            result: result
          }
        )

        :drained

      {:quarantine, reason} ->
        # Terminal: the FE filtered poison rows a retry would only filter
        # again. Drop with a report, mirroring Destination's treatment.
        discard(record)

        Logger.warning("StarRocks quarantined batch filtered on replay; dropping",
          label: record.label,
          table: record.table_name,
          rows: length(rows),
          reason: inspect(reason)
        )

        :telemetry.execute(
          [:serviceradar, :starrocks, :pending_loads, :quarantined],
          %{rows: length(rows)},
          %{
            dataset: record.dataset,
            table: record.table_name,
            label: record.label,
            reason: reason
          }
        )

        :quarantined

      {:error, reason} ->
        defer(record, rows, reason)
    end
  end

  defp replay(%Record{} = record, rows, opts) do
    persist = Keyword.get(opts, :persist, &StreamLoad.persist/3)

    persist_opts =
      opts
      |> Keyword.take([:http])
      |> Keyword.put(:label, record.label)
      |> Keyword.put(:config, Destination.client_config())
      |> Keyword.put(:http_timeout, @drain_http_timeout_ms)

    persist.(record.table_name, rows, persist_opts)
  rescue
    error -> {:error, {:crashed, Exception.message(error)}}
  end

  # A row another drain already finished is gone, not an error.
  defp discard(%Record{} = record) do
    Repo.delete!(record)
    :ok
  rescue
    Ecto.StaleEntryError -> :ok
  end

  defp defer(%Record{} = record, rows, reason) do
    attempts = record.attempts + 1

    if attempts >= @max_attempts do
      dead_letter(record, rows, attempts, reason)
    else
      next_retry_at =
        NaiveDateTime.add(NaiveDateTime.utc_now(), retry_after_seconds(attempts), :second)

      case reschedule(record, attempts, next_retry_at) do
        :gone ->
          :drained

        :ok ->
          Logger.warning("StarRocks quarantined batch replay failed; deferred with backoff",
            label: record.label,
            table: record.table_name,
            rows: length(rows),
            attempts: attempts,
            next_retry_at: NaiveDateTime.to_iso8601(next_retry_at),
            error: inspect(reason)
          )

          :telemetry.execute(
            [:serviceradar, :starrocks, :pending_loads, :deferred],
            %{rows: length(rows)},
            %{
              dataset: record.dataset,
              table: record.table_name,
              label: record.label,
              attempts: attempts,
              reason: reason
            }
          )

          :deferred
      end
    end
  end

  defp reschedule(%Record{} = record, attempts, next_retry_at) do
    record
    |> Ecto.Changeset.change(attempts: attempts, next_retry_at: next_retry_at)
    |> Repo.update!()

    :ok
  rescue
    Ecto.StaleEntryError -> :gone
  end

  defp dead_letter(%Record{} = record, rows, attempts, reason) do
    discard(record)

    Logger.error("StarRocks quarantined batch exhausted replays; dropping from outbox",
      label: record.label,
      table: record.table_name,
      rows: length(rows),
      attempts: attempts,
      error: inspect(reason)
    )

    :telemetry.execute(
      [:serviceradar, :starrocks, :pending_loads, :dead_lettered],
      %{rows: length(rows)},
      %{
        dataset: record.dataset,
        table: record.table_name,
        label: record.label,
        attempts: attempts,
        reason: reason
      }
    )

    :dead_lettered
  end
end
