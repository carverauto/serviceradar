defmodule ServiceRadar.SweepJobs.SweepDataCleanupWatermarkDbTest do
  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.SweepCoverageRollupWorker
  alias ServiceRadar.SweepJobs.SweepDataCleanupWorker
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepGroupExecution
  alias ServiceRadar.SweepJobs.SweepHostResult

  @moduletag :integration

  setup do
    previous = Application.get_env(:serviceradar_core, SweepDataCleanupWorker, [])

    Application.put_env(:serviceradar_core, SweepDataCleanupWorker,
      host_results_retention_days: 7,
      executions_retention_days: 30,
      rollup_retention_days: 400,
      batch_size: 100
    )

    on_exit(fn ->
      Application.put_env(:serviceradar_core, SweepDataCleanupWorker, previous)
    end)

    :ok
  end

  test "a day that has not been rolled up is not deleted" do
    day = Date.add(Date.utc_today(), -10)
    insert_result_on(day, "10.0.1.5")

    assert :ok = SweepDataCleanupWorker.perform(%Oban.Job{args: %{}})

    assert host_results_on(day) == 1
  end

  test "a rolled-up day past retention is deleted, and its coverage survives" do
    day = Date.add(Date.utc_today(), -10)
    insert_result_on(day, "10.0.1.6")

    {:ok, 1} = SweepCoverageRollupWorker.rollup_day(day)

    assert :ok = SweepDataCleanupWorker.perform(%Oban.Job{args: %{}})

    assert host_results_on(day) == 0
    assert coverage_rows_on(day) == 1
  end

  test "coverage rows past the rollup retention are deleted" do
    day = Date.add(Date.utc_today(), -500)
    insert_result_on(day, "10.0.1.7")
    {:ok, 1} = SweepCoverageRollupWorker.rollup_day(day)

    assert :ok = SweepDataCleanupWorker.perform(%Oban.Job{args: %{}})

    assert coverage_rows_on(day) == 0
  end

  # Regression for C1: MAX(day) on platform.sweep_coverage_daily is not a
  # coverage watermark, because SweepCoverageRollupWorker.perform/1
  # processes exactly one day per run with no catch-up. If day D fails
  # permanently while a later day D+2 succeeds, MAX(day) advances past D --
  # the still-unrolled day -- and an unguarded `min(retention_cutoff,
  # watermark)` cutoff deletes D anyway. Roll the day *before* and the day
  # *after* a middle day, but never the middle day itself, with retention
  # short enough that all three are otherwise eligible: the middle day, and
  # every day at or after it, must survive.
  test "an earlier unrolled day blocks deletion at and after it, even though a later day was itself rolled up" do
    Application.put_env(:serviceradar_core, SweepDataCleanupWorker,
      host_results_retention_days: 1,
      executions_retention_days: 30,
      rollup_retention_days: 400,
      batch_size: 100
    )

    day_before = Date.add(Date.utc_today(), -5)
    day_gap = Date.add(Date.utc_today(), -4)
    day_after = Date.add(Date.utc_today(), -3)

    insert_result_on(day_before, "10.0.1.8")
    insert_result_on(day_gap, "10.0.1.9")
    insert_result_on(day_after, "10.0.1.10")

    {:ok, 1} = SweepCoverageRollupWorker.rollup_day(day_before)
    {:ok, 1} = SweepCoverageRollupWorker.rollup_day(day_after)
    # day_gap is deliberately never rolled up.

    assert :ok = SweepDataCleanupWorker.perform(%Oban.Job{args: %{}})

    assert host_results_on(day_before) == 0
    assert host_results_on(day_gap) == 1
    assert host_results_on(day_after) == 1
  end

  # Regression for C3: earliest_unrolled_day/0 must fail CLOSED. A missing
  # table during a rolling deploy, a connection error, or a query timeout
  # are failures of the watermark query, not evidence that there is no gap.
  # Collapsing them into `nil` (fail open) silently disables the guard and
  # deletes exactly the unrolled days it exists to protect. Drop the
  # coverage table (inside this test's rolled-back sandbox transaction) to
  # force the watermark query to fail, and assert the host-result delete is
  # skipped rather than falling back to retention alone.
  #
  # CASCADE is load-bearing: `platform.device_sweep_overlap` is a view over
  # this table, so a bare DROP TABLE now raises 2BP01 rather than reaching the
  # behavior under test. Dropping the dependents is also the truthful
  # simulation -- the scenario is "the coverage table is not there", and a real
  # deploy that removed it would have taken the view with it.
  test "a watermark query failure skips the host-result delete instead of deleting" do
    day = Date.add(Date.utc_today(), -10)
    insert_result_on(day, "10.0.1.20")

    Repo.query!("DROP TABLE platform.sweep_coverage_daily CASCADE")

    assert :ok = SweepDataCleanupWorker.perform(%Oban.Job{args: %{}})

    assert host_results_on(day) == 1
  end

  for status <- [:completed, :failed] do
    test "retention preserves unrolled results for an old #{status} execution" do
      day = Date.add(Date.utc_today(), -40)
      execution = insert_result_on(day, "192.0.2.41")
      at = DateTime.new!(day, ~T[12:00:00.000000], "Etc/UTC")

      Repo.update_all(
        from(e in SweepGroupExecution, where: e.id == ^execution.id),
        set: [status: unquote(status), started_at: at, completed_at: at]
      )

      assert :ok = SweepDataCleanupWorker.perform(%Oban.Job{args: %{}})
      assert host_results_on(day) == 1
      assert Repo.exists?(from(e in SweepGroupExecution, where: e.id == ^execution.id))

      assert {:ok, 1} = SweepCoverageRollupWorker.rollup_day(day)
      assert :ok = SweepDataCleanupWorker.perform(%Oban.Job{args: %{}})
      assert host_results_on(day) == 0
      refute Repo.exists?(from(e in SweepGroupExecution, where: e.id == ^execution.id))
      assert coverage_rows_on(day) == 1
    end
  end

  defp insert_result_on(day, ip) do
    actor = SystemActor.system(:test)
    unique_id = System.unique_integer([:positive, :monotonic])
    at = DateTime.new!(day, ~T[12:00:00.000000], "Etc/UTC")

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Watermark Group #{unique_id}",
          partition: "default",
          agent_ids: [],
          enabled: false
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, execution} =
      SweepGroupExecution
      |> Ash.Changeset.for_create(
        :start,
        %{sweep_group_id: group.id, agent_id: "agent-a"},
        actor: actor
      )
      |> Ash.create()

    Repo.insert_all(SweepHostResult, [
      %{
        id: Ash.UUID.generate(),
        execution_id: execution.id,
        ip: ip,
        status: :available,
        open_ports: [443],
        scanned_ports: [443, 3001],
        sweep_modes_results: %{"tcp" => "success"},
        agent_id: "agent-a",
        sweep_group_id: group.id,
        inserted_at: at
      }
    ])

    execution
  end

  defp host_results_on(day) do
    from_at = DateTime.new!(day, ~T[00:00:00.000000], "Etc/UTC")
    to_at = DateTime.new!(Date.add(day, 1), ~T[00:00:00.000000], "Etc/UTC")

    Repo.one!(
      from(r in SweepHostResult,
        where: r.inserted_at >= ^from_at and r.inserted_at < ^to_at,
        select: count(r.id)
      )
    )
  end

  defp coverage_rows_on(day) do
    %{rows: [[count]]} =
      Repo.query!("SELECT COUNT(*) FROM platform.sweep_coverage_daily WHERE day = $1", [day])

    count
  end
end
