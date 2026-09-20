defmodule ServiceRadar.Analytics.StarRocks.PendingLoads do
  @moduledoc """
  Durable outbox for StarRocks Stream Loads that fail outside JetStream ACK.

  `Destination.persist_after_cnpg/3` fails the EventWriter ACK when a cutover
  dataset misses the warehouse, and the broker redelivers. Producers without
  a broker (Oban workers) have no redelivery: `persist_or_enqueue/3` gives
  them one by storing the failed batch's Stream Load documents in
  `platform.starrocks_pending_loads` and `drain_due/1` replays due rows on a
  later run. The warehouse copy is never silently dropped and the producing
  run is never blocked: both functions answer `:ok`-shaped tuples once the
  batch is durable, and only a failing outbox insert itself returns
  `{:error, _}`.

  Replays are safe twice over. The warehouse tables are PRIMARY KEY models,
  so reloading the same rows converges on the same state, and every row
  carries the deterministic `StreamLoad` label, so the FE reconciles a load
  whose original response was lost instead of applying it twice. A
  `{:quarantine, _}` reply is terminal: the FE filtered poison rows that a
  retry would only filter again, so the row is dropped with a report.
  """

  import Ecto.Query

  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Analytics.StarRocks.Rows
  alias ServiceRadar.Analytics.StarRocks.StreamLoad
  alias ServiceRadar.Repo

  require Logger

  @type dataset :: Destination.dataset()

  # Bounds one drain so a long outage's backlog clears progressively instead
  # of holding the producing run on dozens of sequential Stream Loads.
  @drain_limit 25

  # 60s, 5m, 25m, then hourly. The producing worker runs every minute, so a
  # fresh failure is retried on the next run and a dead FE backs off fast.
  @retry_base_seconds 60
  @retry_factor 5
  @retry_cap_seconds 3_600

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
  only a failing outbox insert answers `{:error, _}`.
  """
  @spec persist_or_enqueue(dataset(), [map()], keyword()) ::
          {:ok, map()} | {:ok, :disabled} | {:ok, :enqueued} | {:error, term()}
  def persist_or_enqueue(dataset, rows, opts \\ []) do
    case Destination.persist_after_cnpg(dataset, rows, opts) do
      {:ok, _} = ok -> ok
      {:error, reason} -> enqueue_failed(dataset, rows, reason)
    end
  rescue
    error ->
      # A crash leaves the load state unknown, but the deterministic label
      # makes a later replay safe, so quarantine first and report.
      Logger.error("StarRocks persist crashed; quarantining batch for replay",
        dataset: dataset,
        error: Exception.message(error),
        stacktrace: Exception.format_stacktrace(__STACKTRACE__)
      )

      enqueue_failed(dataset, rows, {:crashed, Exception.message(error)})
  end

  @doc """
  Replays due quarantined batches, oldest first.

  Accepts `:persist` (default `&StreamLoad.persist/3`), `:http` forwarded to
  it, and `:limit`. Answers a summary; per-batch failures defer the batch
  with backoff instead of failing the drain.
  """
  @spec drain_due(keyword()) ::
          {:ok,
           %{
             drained: non_neg_integer(),
             quarantined: non_neg_integer(),
             deferred: non_neg_integer()
           }}
  def drain_due(opts \\ []) do
    limit = Keyword.get(opts, :limit, @drain_limit)
    now = NaiveDateTime.utc_now()

    due =
      Repo.all(
        from(r in Record,
          where: r.next_retry_at <= ^now,
          order_by: [asc: r.inserted_at],
          limit: ^limit,
          lock: "FOR UPDATE SKIP LOCKED"
        )
      )

    summary =
      Enum.reduce(due, %{drained: 0, quarantined: 0, deferred: 0}, fn record, acc ->
        case attempt_drain(record, opts) do
          :drained -> %{acc | drained: acc.drained + 1}
          :quarantined -> %{acc | quarantined: acc.quarantined + 1}
          :deferred -> %{acc | deferred: acc.deferred + 1}
        end
      end)

    {:ok, summary}
  end

  @doc """
  Seconds until the next retry after `attempts` recorded failures.
  """
  @spec retry_after_seconds(non_neg_integer()) :: pos_integer()
  def retry_after_seconds(attempts) when is_integer(attempts) and attempts >= 0 do
    min(@retry_base_seconds * Integer.pow(@retry_factor, attempts), @retry_cap_seconds)
  end

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

      {:error, changeset} ->
        Logger.error("StarRocks warehouse load failed AND quarantine insert failed; batch lost",
          dataset: dataset,
          table: table,
          label: label,
          rows: length(encoded),
          error: inspect(reason),
          changeset_errors: inspect(changeset.errors)
        )

        {:error, {:quarantine_failed, reason}}
    end
  end

  defp attempt_drain(%Record{} = record, opts) do
    persist = Keyword.get(opts, :persist, &StreamLoad.persist/3)
    rows = get_in(record.payload, ["rows"]) || []

    persist_opts =
      opts
      |> Keyword.take([:http])
      |> Keyword.put(:label, record.label)
      |> Keyword.put(:config, Destination.client_config())

    case persist.(record.table_name, rows, persist_opts) do
      {:ok, result} ->
        Repo.delete!(record)

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
        Repo.delete!(record)

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
  rescue
    error ->
      defer(record, get_in(record.payload, ["rows"]) || [], {:crashed, Exception.message(error)})
  end

  defp defer(%Record{} = record, rows, reason) do
    attempts = record.attempts + 1

    next_retry_at =
      NaiveDateTime.add(NaiveDateTime.utc_now(), retry_after_seconds(attempts), :second)

    record
    |> Ecto.Changeset.change(attempts: attempts, next_retry_at: next_retry_at)
    |> Repo.update!()

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
