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

    :ok
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
