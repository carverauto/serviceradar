defmodule ServiceRadar.Notifications.DeliveryRetentionWorker do
  @moduledoc """
  Prunes settled `notification_deliveries` rows past the notification platform's
  own retention window.

  ## Why this is a separate window from `AlertsRetentionWorker`

  `ServiceRadar.Jobs.AlertsRetentionWorker` hard-deletes resolved and suppressed
  alerts after three days. A delivery is not a child of that lifetime - it
  deliberately **outlives** its alert. That is exactly why `alert_snapshot` is
  required and why `alert_id` is `nilify_all` rather than `delete_all`: the row
  keeps enough of the incident to explain itself after the incident is gone
  (design "Data Model", `NotificationDelivery`).

  So the Delivery Log answers "why was I paged, or not, three weeks ago?" long
  after the alert has been pruned - and it can only do that if this worker owns
  its own, longer window. Reusing the alerts retention window would delete the
  audit trail three days in and make `alert_snapshot` pointless machinery.
  Default is 30 days, tunable through
  `SERVICERADAR_NOTIFICATION_DELIVERY_RETENTION_DAYS`.

  ## Only settled rows are pruned

  The predicate excludes `:pending` and `:dispatching`. A row in either state is
  still **owed**: `:pending` is where a retry-eligible delivery waits (design D4
  - retry keeps a delivery `:pending`, only `:failed` is terminal), and
  `:dispatching` is a row an attempt is holding. Deleting an owed delivery
  silently cancels a page, which is a strictly worse outcome than keeping a row
  a while longer.

  Rows do not get stuck outside the pruner's reach as a result. The dispatcher
  terminalises them: exhausting `max_attempts` writes `:failed`, and
  `Dispatcher.reconcile/2` turns a stale, unreadable agent-command receipt into
  an ordinary retryable failure. A delivery becomes prunable by moving through
  its own state machine, never by the pruner guessing that it is abandoned.

  A suppression row that is still collapsing repeats onto itself is also spared:
  `:record_suppression` refreshes `last_evaluated_at` on every repeat while
  `inserted_at` stays put, so an old row that is still being written to would
  otherwise be deleted mid-silence and immediately recreated, resetting the
  `occurrence_count` an operator is reading.

  ## Batching

  `ctid`-addressed batched deletes with a batch cap, the same shape as
  `ServiceRadar.Credentials.BrokerRetentionWorker` and the flow-attribution
  prune (#4329). Whatever the cap defers is still there tomorrow; an unbounded
  single-statement delete on a table this size is what took the prune out in the
  first place. The `inserted_at` predicate is served by
  `notification_deliveries_retention_idx`.

  ## Queue

  `:maintenance`, not `:notifications`. This is a daily bulk delete that can run
  for minutes, and `:notifications` has concurrency 5 with the delivery worker on
  it - a retention pass there would hold 20% of the paging capacity for the
  duration. Every other retention worker in the tree is on `:maintenance` for the
  same reason.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_retention_days 30
  @default_batch_size 5_000
  @default_max_batches 100

  @table "notification_deliveries"

  # `:pending` and `:dispatching` are excluded because those rows are still
  # owed; see the moduledoc. Written out rather than derived from the resource so
  # the SQL literal and the state vocabulary are visibly the same list.
  @settled_states ~w(sent failed expired cancelled suppressed skipped)

  @delete_batch_sql """
  DELETE FROM platform.#{@table}
  WHERE ctid IN (
    SELECT ctid
    FROM platform.#{@table}
    WHERE inserted_at < $1
      AND state = ANY($2)
      AND (last_evaluated_at IS NULL OR last_evaluated_at < $1)
    LIMIT $3
  )
  """

  @doc "The batched delete this worker runs, for inspection and tests."
  @spec delete_batch_sql() :: String.t()
  def delete_batch_sql, do: @delete_batch_sql

  @doc "The delivery states this worker is allowed to prune."
  @spec settled_states() :: [String.t()]
  def settled_states, do: @settled_states

  @doc """
  Retention settings, from `config :serviceradar_core, #{inspect(__MODULE__)},
  retention_days: _, batch_size: _, max_batches: _`.
  """
  @spec config() :: %{
          retention_days: pos_integer(),
          batch_size: pos_integer(),
          max_batches: pos_integer()
        }
  def config do
    app_config = Application.get_env(:serviceradar_core, __MODULE__, [])

    %{
      retention_days: Keyword.get(app_config, :retention_days, @default_retention_days),
      batch_size: Keyword.get(app_config, :batch_size, @default_batch_size),
      max_batches: Keyword.get(app_config, :max_batches, @default_max_batches)
    }
  end

  @doc """
  The instant before which settled deliveries are prunable.
  """
  @spec cutoff(DateTime.t(), pos_integer()) :: DateTime.t()
  def cutoff(%DateTime{} = now, retention_days) when is_integer(retention_days) do
    DateTime.add(now, -retention_days * 86_400, :second)
  end

  @doc """
  Enqueues one retention pass, outside the cron schedule.
  """
  @spec enqueue(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(opts \\ []) do
    {support_opts, job_opts} = Keyword.split(opts, [:insert_fun, :available_fun])

    %{}
    |> new(job_opts)
    |> ObanSupport.safe_insert(support_opts)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: prune(job, [])

  @doc """
  `perform/1` with its collaborators injected.

  Options: `:now` (the cutoff origin) and `:query` - a
  `fun.(sql, params)` returning `{:ok, %{num_rows: n}}` or `{:error, reason}`,
  which lets the batching and the cap be asserted without a database.
  """
  @spec prune(Oban.Job.t(), keyword()) :: :ok | {:error, term()}
  def prune(%Oban.Job{}, opts) when is_list(opts) do
    %{retention_days: retention_days, batch_size: batch_size, max_batches: max_batches} = config()

    now = fetch_now(opts)
    cutoff = cutoff(now, retention_days)
    query = Keyword.get(opts, :query, &run_query/2)

    case delete_batches(query, cutoff, batch_size, max_batches, 0, 0) do
      {:ok, deleted, batches, capped?} ->
        log_completed(deleted, batches, capped?, cutoff, retention_days)
        :ok

      {:error, reason} ->
        Logger.error("notification delivery retention failed",
          cutoff: cutoff,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp delete_batches(_query, _cutoff, _batch_size, max_batches, deleted, batches)
       when batches >= max_batches do
    {:ok, deleted, batches, true}
  end

  defp delete_batches(query, cutoff, batch_size, max_batches, deleted, batches) do
    case query.(@delete_batch_sql, [cutoff, @settled_states, batch_size]) do
      {:ok, %{num_rows: num_rows}} when num_rows < batch_size ->
        {:ok, deleted + num_rows, batches + batch_of(num_rows), false}

      {:ok, %{num_rows: num_rows}} ->
        delete_batches(query, cutoff, batch_size, max_batches, deleted + num_rows, batches + 1)

      # The notification tables are created by an Elixir migration, so a
      # deployment that has not migrated yet has no table rather than a broken
      # one. That is a not-yet, not a failure, and it must not retry three times
      # and page anybody.
      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        Logger.debug("notification_deliveries table missing; skipping retention")
        {:ok, deleted, batches, false}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp batch_of(0), do: 0
  defp batch_of(_num_rows), do: 1

  defp run_query(sql, params), do: SQL.query(Repo, sql, params, timeout: 60_000)

  defp log_completed(0, _batches, _capped?, _cutoff, _retention_days), do: :ok

  defp log_completed(deleted, batches, capped?, cutoff, retention_days) do
    Logger.info("notification delivery retention pruned settled deliveries",
      deleted_rows: deleted,
      batches: batches,
      batch_cap_hit: capped?,
      retention_days: retention_days,
      cutoff: cutoff
    )
  end

  defp fetch_now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> now
      _none -> DateTime.utc_now()
    end
  end
end
