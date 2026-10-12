defmodule ServiceRadar.SweepJobs.ExecutionReaperIntegrationTest do
  use ServiceRadar.DataCase, async: true

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ExecutionReaper
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepGroupExecution

  @moduletag :integration

  setup do
    %{actor: SystemActor.system(:sweep_execution_reaper_integration_test)}
  end

  test "fails a running execution of a disabled group", %{actor: actor} do
    group = create_group!(actor, enabled: false, interval: "1h")
    execution = start_execution!(actor, group, idle_seconds: 15 * 60)

    assert {:ok, %{failed: failed}} = ExecutionReaper.reap(actor: actor)
    assert failed >= 1

    reaped = reload!(execution, actor)
    assert reaped.status == :failed
    assert reaped.error_message == "abandoned: sweep group disabled"
    assert %DateTime{} = reaped.completed_at
  end

  test "fails a running execution of an enabled group that stopped making progress", %{
    actor: actor
  } do
    group = create_group!(actor, enabled: true, interval: "5m")
    # 3 x 5m is below the 30-minute floor, so the floor applies.
    execution = start_execution!(actor, group, idle_seconds: 31 * 60)

    assert {:ok, _result} = ExecutionReaper.reap(actor: actor)

    reaped = reload!(execution, actor)
    assert reaped.status == :failed
    assert "abandoned: no progress since " <> _since = reaped.error_message
  end

  test "leaves a running execution that is still reporting progress", %{actor: actor} do
    group = create_group!(actor, enabled: true, interval: "5m")
    execution = start_execution!(actor, group, idle_seconds: 60)

    assert {:ok, _result} = ExecutionReaper.reap(actor: actor)

    assert reload!(execution, actor).status == :running
  end

  test "scales the no-progress bound with the group's interval", %{actor: actor} do
    group = create_group!(actor, enabled: true, interval: "1h")
    # Idle for two hours: past the 30-minute floor but inside 3 x 1h.
    execution = start_execution!(actor, group, idle_seconds: 2 * 3_600)

    assert {:ok, _result} = ExecutionReaper.reap(actor: actor)

    assert reload!(execution, actor).status == :running
  end

  test "does not touch completed or failed executions", %{actor: actor} do
    group = create_group!(actor, enabled: false, interval: "1h")

    completed = start_execution!(actor, group, idle_seconds: 7 * 86_400)

    {:ok, completed} =
      completed |> Ash.Changeset.for_update(:complete, %{}) |> Ash.update(actor: actor)

    failed = start_execution!(actor, group, idle_seconds: 7 * 86_400)

    {:ok, failed} =
      failed
      |> Ash.Changeset.for_update(:fail, %{error_message: "agent reported an error"})
      |> Ash.update(actor: actor)

    assert {:ok, _result} = ExecutionReaper.reap(actor: actor)

    assert %{status: :completed, error_message: nil} = reload!(completed, actor)
    assert %{status: :failed, error_message: "agent reported an error"} = reload!(failed, actor)
  end

  test "skips an execution that reported progress after it was read", %{actor: actor} do
    group = create_group!(actor, enabled: false, interval: "1h")
    execution = start_execution!(actor, group, idle_seconds: 15 * 60)

    # The reaper's snapshot says the execution has been quiet; by the time it
    # writes, a result chunk has bumped the heartbeat.
    stale_snapshot = %{
      id: execution.id,
      updated_at: DateTime.shift(DateTime.utc_now(), hour: -1),
      group_enabled: false,
      interval: "1h",
      schedule_type: :interval
    }

    assert {:ok, %{failed: 0, skipped: 1}} =
             ExecutionReaper.reap(actor: actor, lister: fn _batch -> {:ok, [stale_snapshot]} end)

    assert reload!(execution, actor).status == :running
  end

  defp create_group!(actor, opts) do
    unique = System.unique_integer([:positive, :monotonic])

    SweepGroup
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "reaper-group-#{unique}",
        partition: "default",
        agent_ids: [],
        enabled: Keyword.fetch!(opts, :enabled),
        interval: Keyword.fetch!(opts, :interval)
      },
      actor: actor
    )
    |> Ash.create!()
  end

  # Starts an execution and backdates its heartbeat, as if its last result chunk
  # arrived `idle_seconds` ago.
  defp start_execution!(actor, group, idle_seconds: idle_seconds) do
    execution =
      SweepGroupExecution
      |> Ash.Changeset.for_create(
        :start,
        %{sweep_group_id: group.id, agent_id: "agent-reaper-test"},
        actor: actor
      )
      |> Ash.create!()

    quiet_since = DateTime.shift(DateTime.utc_now(), second: -idle_seconds)

    Repo.update_all(
      from(e in SweepGroupExecution, where: e.id == ^execution.id),
      set: [updated_at: quiet_since, started_at: DateTime.truncate(quiet_since, :second)]
    )

    reload!(execution, actor)
  end

  defp reload!(execution, actor), do: Ash.get!(SweepGroupExecution, execution.id, actor: actor)
end
