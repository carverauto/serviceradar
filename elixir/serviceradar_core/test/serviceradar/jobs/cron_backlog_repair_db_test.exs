defmodule ServiceRadar.Jobs.CronBacklogRepairDbTest do
  @moduledoc """
  The reaper pass repairs pending periodic jobs that will never run: redundant cron
  ticks and periodic jobs starved behind higher-priority work. Rows are synthetic
  and confined to a per-test queue, so assertions ignore whatever else the
  database holds.
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias Oban.Job
  alias ServiceRadar.Jobs.ReapStalePeriodicJobsWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  @cron_meta %{
    "cron" => true,
    "cron_tz" => "Etc/UTC",
    "cron_expr" => "* * * * *",
    "cron_name" => "synthetic"
  }
  @tick_worker "ServiceRadar.Observability.StatefulAlertEngine.RecoveryWorker"
  @ash_scheduler "ServiceRadar.Jobs.JobSchedule.IdentityReconciliationScheduler"
  @ash_worker "ServiceRadar.Jobs.JobSchedule.IdentityReconciliationWorker"
  @one_off_worker "ServiceRadar.Jobs.SyntheticOneOffWorker"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, queue: "cron_repair_#{System.unique_integer([:positive])}"}
  end

  test "a wedged queue recovers on the next reaper pass, and a second pass changes nothing",
       %{queue: queue} do
    long_ago = DateTime.shift(DateTime.utc_now(), day: -2)

    # A tick that snoozes forever: one pending job per cron tick, some mid-snooze.
    stale_ticks =
      for n <- 1..40 do
        insert_job!(queue,
          worker: @tick_worker,
          meta: @cron_meta,
          state: if(rem(n, 4) == 0, do: "scheduled", else: "available")
        )
      end

    newest_tick = insert_job!(queue, worker: @tick_worker, meta: @cron_meta)
    running_tick = insert_job!(queue, worker: @tick_worker, meta: @cron_meta, state: "executing")

    # AshOban scheduler (cron-stamped) and worker (empty meta), starved at priority 3.
    starved_scheduler =
      insert_job!(queue,
        worker: @ash_scheduler,
        meta: @cron_meta,
        priority: 3,
        scheduled_at: long_ago
      )

    starved_worker =
      insert_job!(queue, worker: @ash_worker, priority: 2, scheduled_at: long_ago)

    assert :ok = ReapStalePeriodicJobsWorker.perform(%Job{})

    rows = rows_by_id(queue)

    # Mid-snooze ticks are left for Oban's stager, whose UPDATE would overwrite a
    # concurrent cancel; they are cancelled once staged.
    {snoozed, waiting} = Enum.split_with(stale_ticks, &(&1.state == "scheduled"))
    for tick <- waiting, do: assert(%{state: "cancelled"} = rows[tick.id])
    for tick <- snoozed, do: assert(%{state: "scheduled"} = rows[tick.id])
    assert %{state: "available"} = rows[newest_tick.id]
    assert %{state: "executing"} = rows[running_tick.id]
    assert %{state: "available", priority: 0} = rows[starved_scheduler.id]
    assert %{state: "available", priority: 0} = rows[starved_worker.id]

    snoozed_ids = Enum.map(snoozed, & &1.id)
    Repo.update_all(from(j in Job, where: j.id in ^snoozed_ids), set: [state: "available"])

    assert :ok = ReapStalePeriodicJobsWorker.perform(%Job{})
    rows = rows_by_id(queue)
    for tick <- stale_ticks, do: assert(%{state: "cancelled"} = rows[tick.id])
    assert %{state: "available"} = rows[newest_tick.id]

    assert :ok = ReapStalePeriodicJobsWorker.perform(%Job{})
    assert rows_by_id(queue) == rows
  end

  test "a healthy queue is left unchanged", %{queue: queue} do
    long_ago = DateTime.shift(DateTime.utc_now(), day: -2)

    # One pending tick per cron entry; distinct args are distinct entries.
    insert_job!(queue, worker: @tick_worker, meta: @cron_meta)
    insert_job!(queue, worker: @tick_worker, meta: @cron_meta, args: %{"trigger" => "cron"})
    insert_job!(queue, worker: @tick_worker, meta: @cron_meta, state: "executing")
    insert_job!(queue, worker: @tick_worker, meta: @cron_meta, state: "completed")

    # A scheduler waiting less than the starvation threshold.
    insert_job!(queue, worker: @ash_scheduler, meta: @cron_meta, priority: 3)

    # Non-periodic work: duplicates are legitimate and a long wait is not starvation.
    insert_job!(queue, worker: @one_off_worker, priority: 3, scheduled_at: long_ago)
    insert_job!(queue, worker: @one_off_worker, priority: 3, scheduled_at: long_ago)

    before = rows_by_id(queue)

    assert :ok = ReapStalePeriodicJobsWorker.perform(%Job{})
    assert rows_by_id(queue) == before
  end

  defp insert_job!(queue, attrs) do
    {overrides, opts} = Keyword.split(attrs, [:state, :scheduled_at])
    {args, opts} = Keyword.pop(opts, :args, %{})
    state = Keyword.get(overrides, :state, "available")

    changes =
      overrides
      |> Map.new()
      |> Map.merge(state_fields(state))

    args
    |> Job.new([queue: queue] ++ opts)
    |> Ecto.Changeset.change(changes)
    |> Repo.insert!()
  end

  defp state_fields("executing"), do: %{attempt: 1, attempted_at: DateTime.utc_now()}

  defp state_fields("completed"),
    do: %{attempt: 1, attempted_at: DateTime.utc_now(), completed_at: DateTime.utc_now()}

  defp state_fields(_pending), do: %{}

  defp rows_by_id(queue) do
    from(j in Job,
      where: j.queue == ^queue,
      select: {j.id, %{state: j.state, priority: j.priority}}
    )
    |> Repo.all()
    |> Map.new()
  end
end
