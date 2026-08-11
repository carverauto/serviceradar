defmodule ServiceRadar.Notifications.DispatchWorker do
  @moduledoc """
  Performs one transport attempt for one `NotificationDelivery`.

  This worker is deliberately thin. Every decision - suppression re-evaluation,
  the rate-limit budget, secret resolution, rendering, transport selection, and
  the retry rule itself - belongs to
  `ServiceRadar.Notifications.Dispatcher.deliver/2` and the pure cores behind it.
  What lives here is the Oban contract: what the args carry, what happens when
  the job runs twice, and how each of `deliver/2`'s four answers maps onto a job
  outcome.

  ## Why `max_attempts: 1`

  Retry in this platform is owned by the **delivery row** - `attempt_count`,
  `max_attempts`, and `next_attempt_at` - which is what an operator configures on
  the channel and what the Delivery Log renders. Giving Oban a second attempt
  budget does not add resilience; it multiplies. A channel configured for three
  attempts, run by a worker configured for three Oban attempts, sends up to nine
  times, and nothing in the UI explains why. The two budgets also disagree about
  what an attempt *is*: Oban counts job executions, so a job that dies before the
  transport call and a job whose destination returned 500 cost the same, while
  the delivery row correctly charges only the second.

  So Oban gets exactly one execution and never decides anything about retry:

    * `{:ok, :sent}` / `{:ok, :suppressed}` -> `:ok`. Terminal, recorded.
    * `{:ok, :dispatching}` -> `:ok`. The agent accepted the command and the
      durable receipt reconciler now owns completion; acceptance is not
      delivery.
    * `{:retry, at}` -> `{:snooze, seconds}`. Oban's snooze reschedules **and
      increments `max_attempts`** (`Oban.Engines.Basic.snooze_job/3`), so waiting
      never consumes the single execution. The job comes back at `at`, which is
      the same instant the row's `next_attempt_at` now holds.
    * `{:error, reason}` -> `:ok` plus a log line. This is the one that looks
      wrong and is not: `deliver/2` returns `{:error, _}` for an attempt that is
      **finished and recorded**, or for a delivery that cannot be processed at
      all. Handing that back to Oban would either burn an invisible retry the
      operator never configured, or park a permanently unprocessable row in
      `retryable` forever.

  Nothing is lost by completing the job. A delivery that still deserves another
  attempt stays `:pending` with `next_attempt_at` set, and
  `ServiceRadar.Notifications.ContinuationWorker` re-drives it from
  `Dispatcher.due/2` - which is also what recovers a job this worker never got to
  run at all, such as one lost to a node dying mid-execution.

  ## Idempotency

  Two layers, because the unique index and the row state cover different races.

  `unique` on `delivery_id` across the incomplete states collapses a duplicate
  enqueue - a routing worker that ran twice, a continuation tick overlapping a
  snoozed job - onto the job already in flight. It deliberately does **not**
  extend to completed jobs: once an attempt has finished, the row may legitimately
  be owed another one, and a `period: :infinity, states: :all` unique key would
  make the retry scan silently unable to re-enqueue it.

  Behind that, `deliver/2` guards on the delivery's own state before contacting
  anything, so a job that runs twice against a `:sent` row answers `{:ok, :sent}`
  without a second send. That is the `:already_sent` shape of
  `ServiceRadarWebNG.Dashboards.ReportDeliveryWorker.ensure_deliverable/1`, and it
  is what makes re-running this worker safe even when the unique key cannot help.

  ## Queue

  `:notifications`, concurrency 5 (`config.exs:36`,
  `OBAN_QUEUE_NOTIFICATIONS`). See
  `ServiceRadar.Notifications.DispatchSchedule` for the capacity analysis; the
  short version is that this worker is the only one on the queue that makes a
  network call, and a rate-limited delivery snoozes rather than blocking a slot.
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 1,
    unique: [
      fields: [:worker, :args],
      keys: [:delivery_id],
      period: :infinity,
      states: :incomplete
    ]

  alias ServiceRadar.Notifications.Dispatcher
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  # Oban rejects a non-positive snooze, and a delivery whose `next_attempt_at`
  # has already passed by the time the job answers is due now rather than in the
  # past.
  @min_snooze_seconds 1

  @doc """
  The args for a delivery. String keys, one id, no structs (Oban Iron Laws).
  """
  @spec args(binary()) :: %{binary() => binary()}
  def args(delivery_id) when is_binary(delivery_id), do: %{"delivery_id" => delivery_id}

  @doc """
  An unsaved job for `delivery_id`.

  Pure - it builds a changeset and touches nothing - so a test can assert the
  args and the unique/queue options without a database or a running Oban.

  `opts` are `Oban.Job` options; `:scheduled_at` is the useful one, for a
  delivery whose rung is owed in the future.
  """
  @spec job(binary(), keyword()) :: Ecto.Changeset.t()
  def job(delivery_id, opts \\ []) when is_binary(delivery_id) do
    delivery_id |> args() |> new(opts)
  end

  @doc """
  Enqueues one delivery attempt.

  Returns `{:ok, job}` for both a fresh insert and a unique conflict, because
  "the work is already queued" is success. `{:error, :oban_unavailable}` when
  Oban is not running in this node, which is how `serviceradar_core` code stays
  callable from web-ng.

  `:insert_fun` and `:available_fun` are forwarded to
  `ServiceRadar.SweepJobs.ObanSupport.safe_insert/2` as test seams; every other
  option goes to the job.
  """
  @spec enqueue(binary(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(delivery_id, opts \\ []) when is_binary(delivery_id) do
    {support_opts, job_opts} = Keyword.split(opts, [:insert_fun, :available_fun])

    delivery_id
    |> job(job_opts)
    |> ObanSupport.safe_insert(support_opts)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: dispatch(job, [])

  @doc """
  `perform/1` with its collaborators injected.

  `:dispatcher` replaces `ServiceRadar.Notifications.Dispatcher`; every other
  option is forwarded verbatim to `deliver/2`, which is where the documented
  `:now`, `:actor`, `:transport`, `:transport_opts`, `:command_bus`, `:rand`,
  and `:links` seams live. This is the entry point a test uses to exercise the
  outcome mapping without a database or a network.
  """
  @spec dispatch(Oban.Job.t(), keyword()) ::
          :ok | {:snooze, pos_integer()} | {:cancel, term()}
  def dispatch(%Oban.Job{args: %{"delivery_id" => delivery_id}}, opts)
      when is_binary(delivery_id) and is_list(opts) do
    {dispatcher, deliver_opts} = Keyword.pop(opts, :dispatcher, Dispatcher)

    delivery_id
    |> dispatcher.deliver(deliver_opts)
    |> handle(delivery_id, deliver_opts)
  end

  def dispatch(%Oban.Job{args: args}, _opts) do
    # Unprocessable rather than transient: no number of retries invents a
    # delivery id. Cancelling says so in the job record instead of leaving a
    # permanently failing job in `retryable`.
    Logger.error("notification dispatch job has no delivery_id", args: inspect(args))
    {:cancel, :missing_delivery_id}
  end

  defp handle({:ok, :sent}, _delivery_id, _opts), do: :ok
  defp handle({:ok, :suppressed}, _delivery_id, _opts), do: :ok
  defp handle({:ok, :dispatching}, _delivery_id, _opts), do: :ok

  defp handle({:retry, %DateTime{} = at}, _delivery_id, opts) do
    {:snooze, snooze_seconds(at, opts)}
  end

  # Recorded on the delivery row, which is the system of record. Completing the
  # job is what keeps Oban from opening a second retry budget behind the
  # operator's back; see the moduledoc.
  defp handle({:error, reason}, delivery_id, _opts) do
    Logger.warning("notification delivery attempt did not send",
      delivery_id: delivery_id,
      reason: inspect(reason)
    )

    :ok
  end

  defp handle(other, delivery_id, _opts) do
    Logger.error("notification dispatcher returned an unrecognised result",
      delivery_id: delivery_id,
      result: inspect(other)
    )

    :ok
  end

  defp snooze_seconds(%DateTime{} = at, opts) do
    now =
      case Keyword.get(opts, :now) do
        %DateTime{} = now -> now
        _none -> DateTime.utc_now()
      end

    at
    |> DateTime.diff(now, :second)
    |> max(@min_snooze_seconds)
  end
end
