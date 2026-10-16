defmodule ServiceRadar.Jobs.CronBacklogRepair do
  @moduledoc """
  Repairs the two states in which a periodic Oban job stops running without any
  job failing.

  **Redundant pending ticks.** A cron entry inserts one job per tick. A tick that
  never completes (a worker that snoozes forever, a queue no node consumes) leaves
  its job pending while the next tick inserts another, so the backlog grows by one
  job per interval for as long as the condition lasts. Two pending ticks of the
  same worker, queue and args do the same work, so every pending tick but the
  newest is cancelled once it is `available`, or while it is `scheduled` more
  than a couple of seconds ahead of now. A `scheduled` tick that is already due
  is left alone: Oban's stager can overwrite a cancel of a due row.

  **Starved schedulers.** Oban fetches by priority before age. AshOban enqueues its
  schedulers at priority 3, so a queue that always has priority-0 work available
  never fetches them, and because each scheduler is unique over its incomplete
  states the starved job also blocks every later cron insert. Nothing fails and
  nothing is retried; the schedule simply stops. A periodic job left `available`
  or `scheduled` past `starvation_threshold_minutes/0` is raised to priority 0,
  which puts it in plain arrival order with the rest of the queue. A row is not
  raised while another row of the same worker, queue, and args is `executing`,
  because uniqueness is enforced at insert and a second already-available row
  would otherwise run beside the in-flight job.

  Both repairs only ever touch pending (`available`/`scheduled`) rows of periodic
  jobs, are bounded per pass, and are no-ops on a healthy queue, so
  `ServiceRadar.Jobs.ReapStalePeriodicJobsWorker` runs them on every pass. An
  install that upgrades with either state already present therefore recovers
  without operator action.
  """

  import Ecto.Query, warn: false

  alias Oban.Job
  alias ServiceRadar.Repo

  @default_starvation_threshold_minutes 15
  @default_batch_limit 5_000
  @pending_states ["available", "scheduled"]
  # Due `scheduled` rows are the ones Oban's stager selects. Leave that window
  # alone; a tick further ahead is not staged by a concurrent pass.
  @stager_lead_seconds 2

  @type job_ref :: %{id: pos_integer(), worker: String.t(), queue: String.t()}
  @type result :: %{cancelled_ticks: non_neg_integer(), promoted_jobs: [job_ref()]}

  @spec starvation_threshold_minutes() :: pos_integer()
  def starvation_threshold_minutes do
    Application.get_env(
      :serviceradar_core,
      :periodic_job_starvation_threshold_minutes,
      @default_starvation_threshold_minutes
    )
  end

  @doc """
  Run both repairs once.

  `periodic_workers` names the non-cron-stamped workers (AshOban and
  self-scheduled) that count as periodic, in `oban_jobs.worker` form.
  """
  @spec run([String.t()], keyword()) :: result()
  def run(periodic_workers, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, @default_batch_limit)

    {:ok, result} =
      Repo.transaction(fn ->
        %{
          cancelled_ticks: cancel_redundant_ticks(now, limit),
          promoted_jobs: promote_starved_jobs(periodic_workers, now, limit)
        }
      end)

    result
  end

  # Only cron-stamped rows: an AshOban or self-scheduled worker may legitimately
  # hold several pending jobs with identical args.
  defp cancel_redundant_ticks(now, limit) do
    horizon = DateTime.add(now, @stager_lead_seconds, :second)

    ranked =
      from(j in Job,
        where: j.state in ^@pending_states,
        where: fragment("coalesce(?->>'cron', 'false') = 'true'", j.meta),
        select: %{
          id: j.id,
          state: j.state,
          scheduled_at: j.scheduled_at,
          rank:
            over(row_number(),
              partition_by: [j.worker, j.queue, j.args],
              order_by: [desc: j.id]
            )
        }
      )

    redundant =
      from(r in subquery(ranked),
        where:
          r.rank > 1 and
            (r.state == "available" or
               (r.state == "scheduled" and r.scheduled_at > ^horizon)),
        order_by: [asc: r.id],
        limit: ^limit,
        select: r.id
      )

    # Re-check state in the UPDATE. Oban's stager moves due `scheduled` rows to
    # `available` with an UPDATE that joins on id alone and does not re-check
    # state, so a cancel of a due tick that commits while the stager waits on
    # its row lock is overwritten back to `available`. A due redundant tick is
    # cancelled on a later pass, once staged. A tick scheduled past `horizon`
    # is not in that select.
    {count, _} =
      Repo.update_all(
        from(j in Job,
          where: j.id in subquery(redundant),
          where:
            j.state == "available" or
              (j.state == "scheduled" and j.scheduled_at > ^horizon)
        ),
        set: [state: "cancelled", cancelled_at: now]
      )

    count
  end

  # `parent_as/1` is expanded in the caller's query, so the sibling check is a macro.
  defmacrop executing_same_group do
    quote do
      from(e in Job,
        where: e.state == "executing",
        where: e.worker == parent_as(:candidate).worker,
        where: e.queue == parent_as(:candidate).queue,
        where: e.args == parent_as(:candidate).args,
        select: 1
      )
    end
  end

  defp promote_starved_jobs(periodic_workers, now, limit) do
    cutoff = DateTime.shift(now, minute: -starvation_threshold_minutes())

    starved =
      from(j in Job,
        as: :candidate,
        where: j.state in ^@pending_states,
        where: j.priority > 0,
        where: j.scheduled_at < ^cutoff,
        where:
          fragment("coalesce(?->>'cron', 'false') = 'true'", j.meta) or
            j.worker in ^periodic_workers,
        where: not exists(executing_same_group()),
        order_by: [asc: j.id],
        limit: ^limit,
        select: j.id
      )

    {_count, promoted} =
      Repo.update_all(
        from(j in Job,
          as: :candidate,
          where: j.id in subquery(starved),
          where: j.state in ^@pending_states,
          where: not exists(executing_same_group()),
          select: %{id: j.id, worker: j.worker, queue: j.queue}
        ),
        set: [priority: 0]
      )

    Enum.sort_by(promoted, & &1.id)
  end
end
