defmodule ServiceRadar.Notifications.RateLimiter do
  @moduledoc """
  The per-channel send budget, enforced against a **durable** counter (task
  1.3.9, design "Risks": Slack allows roughly one message per second per webhook
  and PagerDuty publishes hard quotas, so the budget "needs a restart-surviving
  budget ... not in-memory GenServer state as `WebhookNotifier` does").

  ## Why this is not a GenServer

  `ServiceRadar.Monitoring.WebhookNotifier` held its rate-limit state in process
  memory. That is the specific mistake this module exists not to repeat, and it
  fails three separate ways that all look like "the budget is not being
  enforced":

    * a restart or a rolling deploy resets every counter to zero, so a deploy
      during an alert storm sends the whole storm again;
    * a second core replica keeps its own counter, so the real send rate is
      `replicas x limit`;
    * an Oban retry running on a different node consumes a different budget.

  The counter therefore lives in `platform.notification_channel_rate_limits`,
  one row per channel, and every consume is a single atomic SQL statement. Two
  dispatchers on two nodes contend on one row and exactly one of them wins the
  last slot in the window.

  ## Fixed windows, not a token bucket

  `NotificationChannel.rate_limit_per_minute` is written in the operator's
  words - "at most N per minute" - and a fixed, minute-aligned window is what
  those words mean. It also gives an exact answer to "when may I try again?":
  the start of the next window, which is what `{:wait, at}` carries so a caller
  schedules rather than polls.

  The known trade-off is a boundary burst: N sends at 12:00:59 and N more at
  12:01:00 is `2N` inside one rolling minute. That is accepted deliberately. A
  sliding-window or token-bucket counter would need either a per-send ledger
  (unbounded growth plus its own retention policy) or a floating-point refill
  computed against the database clock, and both buy precision that a
  courtesy quota does not need.

  ## Consuming is a reservation, not a receipt

  `check_and_consume/4` is called **before** the transport attempt, and the slot
  is consumed whether or not the attempt then succeeds. That is the correct
  direction: the quota being protected is the destination's *request* quota, and
  a request that returned 500 still cost the destination a request. A retry
  therefore re-consumes, which is also correct - it is a second request.

  Over-budget calls do **not** increment the counter. The `ON CONFLICT ... WHERE`
  clause refuses the update outright, so `consumed` records sends attempted
  under budget rather than dispatcher wake-ups, and a channel that is hammered
  while over budget does not inflate its own counter.

  ## Fail open, never closed

  An unavailable counter must not be able to silence a deployment. This is the
  same rule `ServiceRadar.Notifications.Suppression` follows for an unevaluable
  schedule, for the same reason: a false page is a nuisance, a false suppression
  is an outage nobody hears about. A database error while consuming is logged
  and returns `:ok`.

  A `nil`, zero, or negative limit means "no budget configured" and returns
  `:ok` without touching the database at all, so the common case costs nothing.

  ## Purity

  `now` is a parameter, never `DateTime.utc_now/0`, so a budget decision is
  reproducible and testable - the same rule the decision cores follow. The
  window arithmetic (`window_start/1`, `next_window_start/1`) is pure and is
  exposed for tests and for a UI that wants to show when a throttled channel
  frees up.

  See `openspec/changes/add-notification-platform/design.md` ("Risks") and
  `ServiceRadar.Notifications.Dispatcher`, which is the only production caller.
  """

  alias ServiceRadar.Repo

  require Logger

  @schema "platform"
  @table "notification_channel_rate_limits"
  @qualified_table "#{@schema}.#{@table}"

  @window_seconds 60
  @empty_result_retries 1

  # One atomic statement, not a read-then-write. Two dispatchers evaluating the
  # same channel in the same millisecond must not both see "3 of 5 used" and
  # both send.
  #
  # The `ON CONFLICT ... DO UPDATE ... WHERE` clause is what makes the refusal
  # free: when the predicate is false Postgres updates nothing and the CTE
  # returns no rows, so an over-budget caller neither consumes a slot nor
  # inflates the counter. The second branch of the UNION then reads the row that
  # refused it - from the pre-statement snapshot, which is exactly the row whose
  # window bounds the wait.
  #
  # `GREATEST` guards the window against going backwards when two nodes disagree
  # slightly about the clock; without it the later node's older window would
  # reset a budget the earlier node had already advanced.
  @consume_sql """
  WITH granted AS (
    INSERT INTO #{@qualified_table} AS r
      (id, channel_id, window_started_at, consumed, inserted_at, updated_at)
    VALUES ($1, $2, $3, 1, $5, $5)
    ON CONFLICT (channel_id) DO UPDATE
      SET consumed =
            CASE
              WHEN r.window_started_at < EXCLUDED.window_started_at THEN 1
              ELSE r.consumed + 1
            END,
          window_started_at = GREATEST(r.window_started_at, EXCLUDED.window_started_at),
          updated_at = EXCLUDED.updated_at
      WHERE r.window_started_at < EXCLUDED.window_started_at OR r.consumed < $4
    RETURNING consumed, window_started_at
  )
  SELECT g.consumed, g.window_started_at, TRUE FROM granted g
  UNION ALL
  SELECT r.consumed, r.window_started_at, FALSE
    FROM #{@qualified_table} r
   WHERE r.channel_id = $2 AND NOT EXISTS (SELECT 1 FROM granted)
  """

  @usage_sql """
  SELECT consumed, window_started_at FROM #{@qualified_table} WHERE channel_id = $1
  """

  @reset_sql """
  DELETE FROM #{@qualified_table} WHERE channel_id = $1
  """

  @type decision :: :ok | {:wait, DateTime.t()}
  @type usage :: %{consumed: non_neg_integer(), window_started_at: DateTime.t()}

  @doc """
  The length of one budget window, in seconds.
  """
  @spec window_seconds() :: pos_integer()
  def window_seconds, do: @window_seconds

  @doc """
  The start of the window `now` falls in.

  Minute-aligned, so "10 per minute" means the same thing to every node and the
  wait a refused caller is handed is an instant both nodes agree on.
  """
  @spec window_start(DateTime.t()) :: DateTime.t()
  def window_start(%DateTime{} = now) do
    seconds = DateTime.to_unix(now, :second)
    DateTime.from_unix!(seconds - Integer.mod(seconds, @window_seconds), :second)
  end

  @doc """
  The start of the window after the one `now` falls in.

  This is the instant a caller refused at `now` may next try.
  """
  @spec next_window_start(DateTime.t()) :: DateTime.t()
  def next_window_start(%DateTime{} = now) do
    now |> window_start() |> DateTime.add(@window_seconds, :second)
  end

  @doc """
  Reserves one send against `channel_id`'s budget.

  Returns `:ok` when a slot was consumed, and `{:wait, at}` when the budget for
  the current window is spent - `at` is the instant the next window opens.

  A `nil`, zero, or negative `limit_per_minute` means the channel has no budget
  configured and returns `:ok` without a database round trip.

  `now` is an input, never the wall clock, so the decision is reproducible.

  Options:

    * `:repo` - the Ecto repo to consume against. Defaults to
      `ServiceRadar.Repo`; supplied by tests that want a second repo.
    * `:query` - a `fun.(sql, params)` query seam used by focused tests.

  A database failure returns `:ok` (see the moduledoc: never suppress on
  ignorance).
  """
  @spec check_and_consume(term(), term(), DateTime.t(), keyword()) :: decision()
  def check_and_consume(channel_id, limit_per_minute, now, opts \\ [])

  def check_and_consume(channel_id, limit, %DateTime{} = now, opts)
      when is_binary(channel_id) and is_integer(limit) and limit > 0 and is_list(opts) do
    case Ecto.UUID.dump(channel_id) do
      {:ok, channel_uuid} -> consume(channel_uuid, limit, now, opts, @empty_result_retries)
      :error -> :ok
    end
  end

  def check_and_consume(_channel_id, _limit_per_minute, %DateTime{}, _opts), do: :ok

  @doc """
  The stored budget for a channel, or `nil` when it has never been consumed.

  Read-only; for the channel health surface and for tests. The window it reports
  may already have rolled over - `check_and_consume/4` advances it lazily, in
  the statement that consumes from it - so compare `window_started_at` against
  `window_start/1` before showing it as current.
  """
  @spec usage(term(), keyword()) :: usage() | nil
  def usage(channel_id, opts \\ [])

  def usage(channel_id, opts) when is_binary(channel_id) and is_list(opts) do
    with {:ok, channel_uuid} <- Ecto.UUID.dump(channel_id),
         {:ok, %{rows: [[consumed, window_started_at] | _]}} <-
           query(opts, @usage_sql, [channel_uuid]) do
      %{consumed: consumed, window_started_at: to_datetime(window_started_at)}
    else
      _other -> nil
    end
  end

  def usage(_channel_id, _opts), do: nil

  @doc """
  Discards a channel's stored budget.

  For tests and for an operator who has just raised a limit and does not want to
  wait out the current window. Not part of the dispatch path.
  """
  @spec reset(term(), keyword()) :: :ok
  def reset(channel_id, opts \\ [])

  def reset(channel_id, opts) when is_binary(channel_id) and is_list(opts) do
    case Ecto.UUID.dump(channel_id) do
      {:ok, channel_uuid} ->
        _ = query(opts, @reset_sql, [channel_uuid])
        :ok

      :error ->
        :ok
    end
  end

  def reset(_channel_id, _opts), do: :ok

  # --- Consume --------------------------------------------------------------

  defp consume(channel_uuid, limit, now, opts, empty_result_retries) do
    window = window_start(now)

    params = [
      Ecto.UUID.dump!(Ash.UUIDv7.generate()),
      channel_uuid,
      naive(window),
      limit,
      naive(now)
    ]

    case query(opts, @consume_sql, params) do
      {:ok, %{rows: [[_consumed, _window, true] | _]}} ->
        :ok

      {:ok, %{rows: [[_consumed, window_started_at, false] | _]}} ->
        {:wait, window_started_at |> to_datetime() |> DateTime.add(@window_seconds, :second)}

      # A concurrent first insert can produce no rows even though the budget is
      # spent: the INSERT waits on the other transaction, while the fallback
      # SELECT still uses the statement snapshot taken before that transaction
      # committed. Retry in a fresh statement so it sees the committed row.
      {:ok, %{rows: []}} when empty_result_retries > 0 ->
        consume(channel_uuid, limit, now, opts, empty_result_retries - 1)

      # A row that is repeatedly created/deleted underneath both statements is
      # database uncertainty, so retain the documented fail-open policy.
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "notification rate limiter unavailable; allowing the send",
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp query(opts, sql, params) do
    case Keyword.get(opts, :query) do
      query when is_function(query, 2) -> query.(sql, params)
      _other -> Ecto.Adapters.SQL.query(repo(opts), sql, params)
    end
  rescue
    # A counter that cannot be read must not become a deployment-wide page
    # outage. `consume/5` turns this into `:ok`.
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, error}
  end

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)

  # The columns are `:utc_datetime_usec`, which Ecto renders as `timestamp(6)`
  # WITHOUT time zone, so Postgrex speaks NaiveDateTime on both sides. The
  # values stored are UTC by construction.
  defp naive(%DateTime{} = datetime) do
    datetime |> DateTime.to_naive() |> NaiveDateTime.truncate(:microsecond)
  end

  defp to_datetime(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
  defp to_datetime(%DateTime{} = datetime), do: datetime
end
