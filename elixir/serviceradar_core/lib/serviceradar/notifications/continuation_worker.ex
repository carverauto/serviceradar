defmodule ServiceRadar.Notifications.ContinuationWorker do
  @moduledoc """
  The delivery-keyed scheduler: every tick, it asks
  `ServiceRadar.Notifications.Dispatcher.due/2` what notification work is owed
  and queues it.

  Three lists come back and they go to different places, because they are
  different kinds of work:

    * `:retry` holds **delivery** ids - only `:pending` rows whose
      `next_attempt_at` has elapsed. Each becomes a
      `ServiceRadar.Notifications.DispatchWorker`. Agent commands already in
      `:dispatching` belong exclusively to `ReceiptWorker`, so this scan cannot
      duplicate an in-flight page.
    * `:escalation` holds **alert** ids whose ladder may owe another rung. An
      escalation rung is a *plan* decision, not a transport one, so these go to
      `ServiceRadar.Notifications.RoutingWorker` with `lifecycle_reason:
      :escalate`; `route/3` re-runs `Escalation.plan/1`, excludes the rungs that
      already have rows, and emits the dispatch workers itself. Enqueueing a
      `DispatchWorker` here would mean inventing a delivery row outside the one
      code path allowed to create one.
    * `:renotify` holds **alert** ids whose stateful-rule cadence has elapsed.
      These go through `AlertLifecycle.send_renotify/4`, preserving the rule
      engine's notification-count and last-notified bookkeeping.

  ## Why this is not redundant with the `Alert.:send_notifications` trigger

  They select over **different tables**, which is exactly the reason design.md
  sanctions a second scheduler on this queue ("Alert Lifecycle Changes").

  The AshOban trigger on `ServiceRadar.Monitoring.Alert` (`alert.ex:128-137`)
  scans `alerts` through `read :needs_notification`. It is alert-keyed and
  first-notify-only, and that is not a limitation to be fixed - it is design D8:
  originating a first notification belongs to the alert lifecycle alone, because
  that is where incident identity, dedup state, and the alert row are already
  consistent. A scheduler licensed to originate would race the lifecycle and
  double-page.

  Continuation work cannot be expressed as an `alerts` query at all. One alert
  has many deliveries, in different states, on different channels, with
  different `next_attempt_at` instants; "this Slack delivery is owed a third
  attempt in forty seconds" is a fact about a `notification_deliveries` row, and
  the alert it belongs to has already been notified, so every alert-keyed filter
  excludes it. Collapsing the two schedulers therefore has only two outcomes:
  drop retry and escalation entirely, or let the scheduler invent first
  notifications. This worker is the third option.

  The two cannot double-page. This worker never originates - `due/2`'s
  `:escalation` list contains only alerts that already have a dispatched
  delivery - and everything it queues passes through `route/3`'s idempotency and
  `DispatchWorker`'s unique key on the delivery id.

  ## Idempotency

  A tick queues work that already exists rather than creating any. Re-running it
  is a no-op by construction: `DispatchWorker` is unique on `delivery_id` across
  the incomplete states, so a delivery already queued (or snoozed waiting on its
  backoff) is not queued twice; `RoutingWorker` is unique on the routing request
  key, and `route/3` excludes dispatches that already have rows even when the
  unique key does not catch it.

  `max_attempts: 1`: a tick that fails is superseded by the next tick a minute
  later against fresher data, and `due/2` has no error channel by design - a read
  that fails is logged and yields an empty list, so a half-failed tick still
  drives the other half. Retrying a scan is strictly worse than re-scanning.

  ## Queue

  `:notifications`, concurrency 5. The scan itself is two indexed selects; the
  work it queues is what occupies the queue.
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Notifications.Dispatcher
  alias ServiceRadar.Notifications.DispatchWorker
  alias ServiceRadar.Notifications.RoutingWorker
  alias ServiceRadar.Observability.StatefulAlertEngine.AlertLifecycle
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  # Per list, per tick. The bound exists so one pathological incident cannot
  # make a single tick enqueue unbounded work; whatever it does not reach is
  # still owed and is picked up by the next tick.
  @default_limit 500

  @doc """
  The per-tick scan bounds, from `config :serviceradar_core,
  #{inspect(__MODULE__)}, limit: _, stall_seconds: _`.
  """
  @spec config() :: %{limit: pos_integer(), stall_seconds: pos_integer() | nil}
  def config do
    app_config = Application.get_env(:serviceradar_core, __MODULE__, [])

    %{
      limit: Keyword.get(app_config, :limit, @default_limit),
      stall_seconds: Keyword.get(app_config, :stall_seconds)
    }
  end

  @doc """
  Enqueues one continuation tick, outside the cron schedule.
  """
  @spec enqueue(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(opts \\ []) do
    {support_opts, job_opts} = Keyword.split(opts, [:insert_fun, :available_fun])

    %{}
    |> new(job_opts)
    |> ObanSupport.safe_insert(support_opts)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: sweep(job, [])

  @doc """
  `perform/1` with its collaborators injected.

  Options:

    * `:dispatcher` - replaces `ServiceRadar.Notifications.Dispatcher`.
    * `:enqueue_dispatch` - a one-argument function taking a delivery id.
    * `:enqueue_routing` - a two-argument function taking an alert id and a
      lifecycle reason.
    * `:send_renotify` - a two-argument function taking an alert id and the
      captured scan instant.
    * `:now` - the scan instant, captured once and passed to `due/2`.

  Everything else is forwarded to `due/2` (`:actor`, `:limit`,
  `:stall_seconds`).
  """
  @spec sweep(Oban.Job.t(), keyword()) :: :ok
  def sweep(%Oban.Job{}, opts) when is_list(opts) do
    {dispatcher, opts} = Keyword.pop(opts, :dispatcher, Dispatcher)
    {dispatch, opts} = Keyword.pop(opts, :enqueue_dispatch, &DispatchWorker.enqueue/1)
    {route, opts} = Keyword.pop(opts, :enqueue_routing, &RoutingWorker.enqueue/2)

    {renotify_alert, opts} =
      Keyword.pop(opts, :send_renotify, fn alert_id, now ->
        AlertLifecycle.send_renotify(alert_id, nil, nil, now)
      end)

    {now, due_opts} = Keyword.pop_lazy(opts, :now, &DateTime.utc_now/0)

    %{retry: retry, escalation: escalation, renotify: renotify} =
      dispatcher.due(now, due_options(due_opts))

    queued_retry = Enum.count(retry, &queued?(dispatch.(&1), "delivery", &1))

    queued_escalation =
      Enum.count(escalation, &queued?(route.(&1, :escalate), "escalation", &1))

    queued_renotify =
      Enum.count(renotify, &queued?(renotify_alert.(&1, now), "renotify", &1))

    log_tick(retry, queued_retry, escalation, queued_escalation, renotify, queued_renotify)

    :ok
  end

  defp due_options(opts) do
    %{limit: limit, stall_seconds: stall_seconds} = config()

    opts
    |> Keyword.put_new(:limit, limit)
    |> put_new_present(:stall_seconds, stall_seconds)
  end

  defp put_new_present(opts, _key, nil), do: opts
  defp put_new_present(opts, key, value), do: Keyword.put_new(opts, key, value)

  # A unique conflict is success: the work is already queued. Only a real insert
  # failure is counted as missed, and it is logged rather than raised so one bad
  # row cannot stop the tick from driving the rest.
  defp queued?({:ok, _job}, _kind, _id), do: true
  defp queued?(:ok, _kind, _id), do: true

  defp queued?({:error, reason}, kind, id) do
    Logger.error("notification continuation could not queue #{kind}",
      id: id,
      reason: inspect(reason)
    )

    false
  end

  defp log_tick([], _queued_retry, [], _queued_escalation, [], _queued_renotify), do: :ok

  defp log_tick(retry, queued_retry, escalation, queued_escalation, renotify, queued_renotify) do
    Logger.info("notification continuation tick queued due work",
      retry_due: length(retry),
      retry_queued: queued_retry,
      escalation_due: length(escalation),
      escalation_queued: queued_escalation,
      renotify_due: length(renotify),
      renotify_queued: queued_renotify
    )
  end
end
