defmodule ServiceRadar.Notifications.RoutingWorker do
  @moduledoc """
  Turns one routing request into `NotificationDelivery` rows, then queues an
  attempt for each one that is dispatchable.

  This is the job `AlertLifecycle` enqueues when an incident is owed a
  notification, and the job `ServiceRadar.Notifications.ContinuationWorker`
  enqueues when an escalation rung comes due. It calls
  `ServiceRadar.Notifications.Dispatcher.route/3` and then, for each id in
  `planned`, enqueues a `ServiceRadar.Notifications.DispatchWorker`. It decides
  nothing itself: matching, deduplication, escalation, and suppression are all
  `route/3`'s, and through it the pure cores'.

  Ids in `suppressed` are **not** enqueued and are **not** an error. A withheld
  notification is already fully recorded as a delivery row carrying its
  `suppression_reason` (design D5), including the `:no_matching_route` row that
  makes an unrouted alert visible. There is nothing left to send, and nothing was
  dropped.

  ## Args

  `%{"alert_id" => id, "lifecycle_reason" => reason, "step_number" => n | nil,
  "dedupe_key" => key | nil}` - string keys, ids and scalars only, no structs.

  Those four fields are exactly `Dedupe.routing_request_key/1`'s tuple, and they
  are exactly the `unique` keys below, so the Oban job identity and the routing
  request identity cannot drift apart. `step_number` and `dedupe_key` are always
  present, `nil` when they do not apply, because a key that is sometimes absent
  computes a different uniqueness digest than the same key set to `nil`.

  `lifecycle_reason` arrives as a string and is mapped to an atom through a fixed
  table. `String.to_atom/1` on job args is prohibited by the Iron Laws, and
  `String.to_existing_atom/1` is not a fix - it converts an atom-table question
  into a runtime crash that depends on what else happens to be loaded.

  ## Why `max_attempts` is 3 here and 1 on the dispatch worker

  These two workers sit on opposite sides of the only rule that matters: whether
  something else will notice the work if this job gives up.

  A delivery attempt that fails leaves a `:pending` row with `next_attempt_at`
  set, which `Dispatcher.due/2` finds and the continuation sweeper re-drives - so
  `DispatchWorker` needs no Oban retry, and giving it one would multiply the
  channel's configured attempt budget by Oban's.

  A **routing** request that fails leaves nothing at all. Design D8 reserves
  originating a first notification for `AlertLifecycle` alone, precisely so the
  scheduler cannot race it and double-page; the corollary is that the scheduler
  also cannot rescue it. If this job dies on a transient database error, that
  incident is simply never routed. So it retries, and it is safe to retry because
  `route/3` is idempotent: it recomputes the plan, excludes the dispatches that
  already have rows, and serialises concurrent requests for the same routing
  request key on an advisory lock.

  ## Queue

  `:notifications`, concurrency 5. Short and database-only - the transport call
  happens in `DispatchWorker`, not here.
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 3,
    unique: [
      fields: [:worker, :args],
      keys: [:alert_id, :lifecycle_reason, :step_number, :dedupe_key],
      period: :infinity,
      states: :incomplete
    ]

  alias ServiceRadar.Notifications.Dispatcher
  alias ServiceRadar.Notifications.DispatchWorker
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  # The lifecycle reasons design D6 names, as a closed table. Adding one is a
  # deliberate edit here, which is the point.
  @lifecycle_reasons %{
    "fire" => :fire,
    "renotify" => :renotify,
    "escalate" => :escalate,
    "resolve" => :resolve
  }

  @doc """
  The routing reasons this worker accepts, as `%{string => atom}`.
  """
  @spec lifecycle_reasons() :: %{binary() => atom()}
  def lifecycle_reasons, do: @lifecycle_reasons

  @doc """
  The args for a routing request. String keys; `step_number` and `dedupe_key`
  are always present so the unique digest is stable.
  """
  @spec args(binary(), atom() | binary(), keyword()) :: %{binary() => term()}
  def args(alert_id, lifecycle_reason, opts \\ []) when is_binary(alert_id) do
    %{
      "alert_id" => alert_id,
      "lifecycle_reason" => to_string(lifecycle_reason),
      "step_number" => Keyword.get(opts, :step_number),
      "dedupe_key" => Keyword.get(opts, :dedupe_key)
    }
  end

  @doc """
  An unsaved routing job. Pure; builds a changeset and touches nothing.
  """
  @spec job(binary(), atom() | binary(), keyword()) :: Ecto.Changeset.t()
  def job(alert_id, lifecycle_reason, opts \\ []) when is_binary(alert_id) do
    {args_opts, job_opts} = Keyword.split(opts, [:step_number, :dedupe_key])

    alert_id
    |> args(lifecycle_reason, args_opts)
    |> new(job_opts)
  end

  @doc """
  Enqueues a routing request.

  Returns `{:ok, job}` for a unique conflict as well as a fresh insert: an
  identical request already in flight is the answer, not a failure.
  """
  @spec enqueue(binary(), atom() | binary(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(alert_id, lifecycle_reason, opts \\ []) when is_binary(alert_id) do
    {support_opts, job_opts} = Keyword.split(opts, [:insert_fun, :available_fun])

    alert_id
    |> job(lifecycle_reason, job_opts)
    |> ObanSupport.safe_insert(support_opts)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: route(job, [])

  @doc """
  `perform/1` with its collaborators injected.

  Options:

    * `:dispatcher` - replaces `ServiceRadar.Notifications.Dispatcher`.
    * `:enqueue` - a one-argument function taking a delivery id, replacing
      `DispatchWorker.enqueue/1`. The seam that lets the fan-out be asserted
      without a running queue.

  Everything else is forwarded to `route/3`, which is where `:now`, `:actor`,
  and `:lock?` live.
  """
  @spec route(Oban.Job.t(), keyword()) :: :ok | {:error, term()} | {:cancel, term()}
  def route(%Oban.Job{args: %{"alert_id" => alert_id} = args}, opts)
      when is_binary(alert_id) and is_list(opts) do
    case lifecycle_reason(args) do
      {:ok, reason} -> do_route(alert_id, reason, args, opts)
      :error -> cancel_unknown_reason(alert_id, args)
    end
  end

  def route(%Oban.Job{args: args}, _opts) do
    Logger.error("notification routing job has no alert_id", args: inspect(args))
    {:cancel, :missing_alert_id}
  end

  defp do_route(alert_id, reason, args, opts) do
    {dispatcher, opts} = Keyword.pop(opts, :dispatcher, Dispatcher)
    {enqueue, route_opts} = Keyword.pop(opts, :enqueue, &DispatchWorker.enqueue/1)

    route_opts = Keyword.merge(route_opts, request_opts(args))

    case dispatcher.route(alert_id, reason, route_opts) do
      {:ok, %{planned: planned, suppressed: suppressed}} ->
        queued = Enum.count(planned, &dispatchable(&1, alert_id, enqueue))
        log_routed(alert_id, reason, planned, suppressed, queued)
        :ok

      {:error, :alert_not_found} ->
        # The alert was resolved and pruned, or never existed. Retrying cannot
        # bring it back, so the job says so rather than failing three times.
        Logger.info("notification routing skipped: the alert is gone",
          alert_id: alert_id,
          lifecycle_reason: reason
        )

        {:cancel, :alert_not_found}

      {:error, :invalid_routing_request} ->
        {:cancel, :invalid_routing_request}

      {:error, reason_term} ->
        # Everything else - a database blip, an unreadable dispatch history - is
        # transient, and nothing else will route this incident if this job gives
        # up. See the moduledoc.
        Logger.error("notification routing failed",
          alert_id: alert_id,
          lifecycle_reason: reason,
          reason: inspect(reason_term)
        )

        {:error, reason_term}
    end
  end

  # An enqueue failure is logged and counted, not raised: one channel whose job
  # could not be inserted must not discard the deliveries that were queued
  # alongside it, and every planned row is still `:pending` with
  # `next_attempt_at` set, so the continuation sweeper picks it up.
  defp dispatchable(delivery_id, alert_id, enqueue) do
    case enqueue.(delivery_id) do
      {:ok, _job} ->
        true

      {:error, reason} ->
        Logger.error("notification delivery could not be queued",
          alert_id: alert_id,
          delivery_id: delivery_id,
          reason: inspect(reason)
        )

        false
    end
  end

  defp request_opts(args) do
    Enum.reject(
      [
        step_number: args["step_number"],
        dedupe_key: args["dedupe_key"]
      ],
      fn {_key, value} -> is_nil(value) end
    )
  end

  defp lifecycle_reason(%{"lifecycle_reason" => reason}) when is_binary(reason) do
    Map.fetch(@lifecycle_reasons, reason)
  end

  defp lifecycle_reason(_args), do: :error

  defp cancel_unknown_reason(alert_id, args) do
    Logger.error("notification routing job has an unknown lifecycle_reason",
      alert_id: alert_id,
      lifecycle_reason: inspect(args["lifecycle_reason"]),
      known: Map.keys(@lifecycle_reasons)
    )

    {:cancel, :unknown_lifecycle_reason}
  end

  defp log_routed(alert_id, reason, planned, suppressed, queued) do
    Logger.info("notification routing request resolved",
      alert_id: alert_id,
      lifecycle_reason: reason,
      planned: length(planned),
      queued: queued,
      suppressed: length(suppressed)
    )
  end
end
