defmodule ServiceRadar.Notifications.ReceiptWorker do
  @moduledoc """
  The bounded periodic pass that closes out agent-routed deliveries whose
  wake-up signal was lost, and re-drives the ones a reconnected agent has made
  due early (tasks 3.4.4, 3.4.5).

  ## Why this exists rather than a supervision-flag change

  Design D3 offers two ways to give an edge delivery a durable receipt: enable
  `:status_handler_enabled` so `ServiceRadar.AgentCommands.StatusHandler`
  persists command acks and results, or ship a poll-based reconciler so
  notification deliveries do not depend on it. This is the second, and the
  reasoning is recorded here because the first looks like a one-line change and
  is not the smaller one:

    1. The flag is already on where it matters. Both deployed releases default
       `STATUS_HANDLER_ENABLED` to `"true"`
       (`serviceradar_core/config/runtime.exs`,
       `serviceradar_core_elx/config/runtime.exs`); the `false` default in
       `cluster/coordinator_children.ex` is only reached where no config sets
       the key. Flipping it would change behaviour for every OTHER command
       consumer - sync ingest, DIRE, the results router - in exactly the
       contexts where it is currently off deliberately, and change nothing in
       production.
    2. It would not deliver a receipt anyway. Nothing maps an `agent_commands`
       row onto a `notification_deliveries` row; without this pass, enabling the
       handler persists command results that no notification ever reads.
    3. A delivery guarantee must not vary with another subsystem's supervision
       flag. `Dispatcher.reconcile/2` reads only what CORE writes - the command
       row the bus itself creates, its status, and the `expires_at` it computes
       from the TTL - so it reaches the same answer with the status handler on
       or off. The handler, when running, simply makes that answer arrive
       sooner.

  ## What a tick does

  `Dispatcher.reconcile/2` returns two lists and they go to different places:

    * `:settled` was already written by `reconcile/2` and is logged only.
    * `:drain` holds deliveries waiting out a backoff for an agent that has
      since reconnected. Each is re-queued with `scheduled_at: now` and
      `replace: [scheduled: [:scheduled_at]]`, which is the only thing that
      moves a job Oban already has: `DispatchWorker`'s unique key spans the
      incomplete states, so a plain enqueue of a snoozed delivery is a conflict
      that changes nothing.

  ## Idempotency

  A tick creates no work of its own. `reconcile/2` settles a `:dispatching` row
  from its command row, which is the same answer every time it is asked;
  re-queuing an already-due delivery is a no-op against `DispatchWorker`'s
  unique key. `max_attempts: 1` for the same reason as `ContinuationWorker`: a
  failed tick is superseded by the next one against fresher data, and retrying
  a scan is strictly worse than re-scanning.

  ## Queue

  `:notifications`. The scan is two indexed selects plus one `agent_commands`
  read per accepted agent-routed delivery. Rows remain `:dispatching` by design
  until the durable SDK result settles them.
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Notifications.Dispatcher
  alias ServiceRadar.Notifications.DispatchWorker
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  # Per list, per tick. Whatever a tick does not reach is still owed and is
  # picked up by the next one.
  @default_limit 500

  @doc """
  The per-tick scan bound, from `config :serviceradar_core,
  #{inspect(__MODULE__)}, limit: _`.
  """
  @spec config() :: %{limit: pos_integer()}
  def config do
    app_config = Application.get_env(:serviceradar_core, __MODULE__, [])

    %{limit: Keyword.get(app_config, :limit, @default_limit)}
  end

  @doc """
  Enqueues one reconcile tick, outside the cron schedule.
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
    * `:enqueue_drain` - a one-argument function taking a delivery id.
    * `:now` - the scan instant, captured once and passed to `reconcile/2`.

  Everything else is forwarded to `reconcile/2` (`:actor`, `:limit`,
  `:load_command`, `:agent_online?`).
  """
  @spec sweep(Oban.Job.t(), keyword()) :: :ok
  def sweep(%Oban.Job{}, opts) when is_list(opts) do
    {dispatcher, opts} = Keyword.pop(opts, :dispatcher, Dispatcher)
    {drain, opts} = Keyword.pop(opts, :enqueue_drain, &drain/1)
    {now, reconcile_opts} = Keyword.pop_lazy(opts, :now, &DateTime.utc_now/0)

    %{settled: settled, drain: drain_ids} =
      dispatcher.reconcile(now, reconcile_options(reconcile_opts))

    drained = Enum.count(drain_ids, &queued?(drain.(&1), &1))

    log_tick(settled, drain_ids, drained)

    :ok
  end

  defp reconcile_options(opts) do
    %{limit: limit} = config()

    Keyword.put_new(opts, :limit, limit)
  end

  # `replace` is what distinguishes this from an ordinary enqueue: the delivery
  # already has a snoozed job, so without it the unique key silently keeps the
  # old `scheduled_at` and the drain does nothing at all.
  defp drain(delivery_id) do
    DispatchWorker.enqueue(delivery_id,
      scheduled_at: DateTime.utc_now(),
      replace: [scheduled: [:scheduled_at]]
    )
  end

  defp queued?({:ok, _job}, _id), do: true

  defp queued?({:error, reason}, id) do
    Logger.error("notification receipt sweep could not re-queue a drained delivery",
      delivery_id: id,
      reason: inspect(reason)
    )

    false
  end

  defp log_tick([], [], _drained), do: :ok

  defp log_tick(settled, drain_ids, drained) do
    Logger.info("notification receipt sweep reconciled agent-routed deliveries",
      settled: length(settled),
      drain_due: length(drain_ids),
      drain_queued: drained
    )
  end
end
