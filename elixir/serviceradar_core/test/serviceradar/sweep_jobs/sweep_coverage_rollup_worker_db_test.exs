defmodule ServiceRadar.SweepJobs.SweepCoverageRollupWorkerDbTest do
  use ServiceRadar.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.SweepCoverageRollupWorker
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepGroupExecution
  alias ServiceRadar.SweepJobs.SweepHostResult

  @moduletag :integration

  test "two sweep groups on one device and agent produce two rows" do
    day = Date.add(Date.utc_today(), -1)
    device_uid = "device-overlap"
    {group_a, group_b} = {Ash.UUID.generate(), Ash.UUID.generate()}

    insert_result(day, device_uid, "10.0.0.5", group_a, "agent-a", [443], [443])
    insert_result(day, device_uid, "10.0.0.5", group_b, "agent-a", [3001], [])

    assert {:ok, 2} = SweepCoverageRollupWorker.rollup_day(day)

    rows = coverage_rows(day, device_uid)
    assert length(rows) == 2
    assert Enum.sort(Enum.map(rows, & &1.sweep_group_id)) == Enum.sort([group_a, group_b])
  end

  test "re-running a day does not double count" do
    day = Date.add(Date.utc_today(), -1)
    device_uid = "device-idempotent"
    group = Ash.UUID.generate()

    insert_result(day, device_uid, "10.0.0.6", group, "agent-a", [443], [443])

    assert {:ok, 1} = SweepCoverageRollupWorker.rollup_day(day)
    [first] = coverage_rows(day, device_uid)

    assert {:ok, 1} = SweepCoverageRollupWorker.rollup_day(day)
    [second] = coverage_rows(day, device_uid)

    assert second.execution_count == first.execution_count
    assert second.available_count == first.available_count
    assert Enum.sort(second.scanned_ports) == Enum.sort(first.scanned_ports)
  end

  test "unions port coverage across executions in the day" do
    day = Date.add(Date.utc_today(), -1)
    device_uid = "device-union"
    group = Ash.UUID.generate()

    insert_result(day, device_uid, "10.0.0.7", group, "agent-a", [443], [443])
    insert_result(day, device_uid, "10.0.0.7", group, "agent-a", [3001, 4502], [])

    assert {:ok, 1} = SweepCoverageRollupWorker.rollup_day(day)

    [row] = coverage_rows(day, device_uid)
    assert Enum.sort(row.scanned_ports) == [443, 3001, 4502]
    assert row.open_ports == [443]
    assert row.execution_count == 2
  end

  test "a day with no results writes nothing and still succeeds" do
    day = Date.add(Date.utc_today(), -300)
    assert {:ok, 0} = SweepCoverageRollupWorker.rollup_day(day)
  end

  test "a host not yet matched to inventory (device_uid NULL) still gets its ports rolled up" do
    day = Date.add(Date.utc_today(), -1)
    group = Ash.UUID.generate()

    # device_id_for_ip/2 returns nil for any swept IP not yet matched to an
    # inventory device (sweep_results_ingestor.ex:1008-1013), so device_uid
    # NULL on sweep_host_results is routine, not an edge case. The port-union
    # and modes CTEs must still be found by the join keyed on NULL device_uid.
    insert_result(day, nil, "10.0.0.9", group, "agent-a", [443, 8080], [443])

    assert {:ok, 1} = SweepCoverageRollupWorker.rollup_day(day)

    [row] = coverage_rows_by_ip(day, "10.0.0.9")
    assert Enum.sort(row.scanned_ports) == [443, 8080]
    assert row.open_ports == [443]
  end

  test "modes_observed captures only the modes that actually succeeded" do
    day = Date.add(Date.utc_today(), -1)
    device_uid = "device-modes"
    group = Ash.UUID.generate()

    insert_result(day, device_uid, "10.0.0.11", group, "agent-a", [], [], %{
      "icmp" => "success",
      "tcp" => "no_response"
    })

    assert {:ok, 1} = SweepCoverageRollupWorker.rollup_day(day)

    [row] = coverage_rows(day, device_uid)
    assert Enum.sort(row.modes_requested) == ["icmp", "tcp"]
    assert row.modes_observed == ["icmp"]
  end

  # Regression for C2: on a fresh deployment (or after any missed day)
  # `sweep_coverage_daily` is empty while `sweep_host_results` already holds
  # days of history. `perform/1` given no args (the scheduled path) must not
  # roll only yesterday -- it must catch up every un-rolled day through
  # yesterday, or the earliest gap never advances and
  # `SweepDataCleanupWorker`'s watermark guard is pinned forever.
  test "an args-less run catches up every un-rolled day through yesterday" do
    day1 = Date.add(Date.utc_today(), -3)
    day2 = Date.add(Date.utc_today(), -2)
    day3 = Date.add(Date.utc_today(), -1)
    group = Ash.UUID.generate()

    insert_result(day1, "device-catchup-1", "10.0.2.21", group, "agent-a", [443], [443])
    insert_result(day2, "device-catchup-2", "10.0.2.22", group, "agent-a", [443], [443])
    insert_result(day3, "device-catchup-3", "10.0.2.23", group, "agent-a", [443], [443])

    assert :ok = SweepCoverageRollupWorker.perform(%Oban.Job{args: %{}})

    assert length(coverage_rows(day1, "device-catchup-1")) == 1
    assert length(coverage_rows(day2, "device-catchup-2")) == 1
    assert length(coverage_rows(day3, "device-catchup-3")) == 1
  end

  # Inserts one sweep_group_executions row plus one sweep_host_results row,
  # then backdates the result's inserted_at into `day`. Each call creates its
  # own execution (and its own disabled sweep group, to avoid the global Oban
  # scheduling side effect a default-enabled group triggers) so that repeated
  # calls with the same device/ip do not collide on the
  # sweep_host_results_execution_ip_uidx unique index -- distinct executions
  # for the same ip within a day is exactly the "two sweeps ran" case the
  # rollup aggregates.
  defp insert_result(
         day,
         device_uid,
         ip,
         group_id,
         agent_id,
         scanned_ports,
         open_ports,
         sweep_modes_results \\ %{}
       ) do
    actor = SystemActor.system(:test)
    execution_id = insert_execution(actor)

    {:ok, result} =
      SweepHostResult
      |> Ash.Changeset.for_create(
        :create,
        %{
          execution_id: execution_id,
          ip: ip,
          device_id: device_uid,
          status: :available,
          response_time_ms: 5,
          sweep_modes_results: sweep_modes_results,
          open_ports: open_ports,
          scanned_ports: scanned_ports,
          agent_id: agent_id,
          sweep_group_id: group_id
        },
        actor: actor
      )
      |> Ash.create()

    stamp_inserted_at(result.id, day)
  end

  defp insert_execution(actor) do
    unique_id = System.unique_integer([:positive, :monotonic])

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Coverage Group #{unique_id}",
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

    execution.id
  end

  defp stamp_inserted_at(result_id, %Date{} = day) do
    {:ok, timestamp} = DateTime.new(day, ~T[12:00:00.000000], "Etc/UTC")

    Repo.update_all(
      from(r in "sweep_host_results",
        prefix: "platform",
        where: r.id == type(^result_id, :binary_id)
      ),
      set: [inserted_at: timestamp]
    )
  end

  defp coverage_rows(day, device_uid) do
    Repo.all(
      from(r in "sweep_coverage_daily",
        prefix: "platform",
        where: r.day == ^day and r.device_uid == ^device_uid,
        select: %{
          sweep_group_id: type(r.sweep_group_id, :binary_id),
          agent_id: r.agent_id,
          execution_count: r.execution_count,
          available_count: r.available_count,
          unavailable_count: r.unavailable_count,
          error_count: r.error_count,
          scanned_ports: r.scanned_ports,
          open_ports: r.open_ports,
          modes_requested: r.modes_requested,
          modes_observed: r.modes_observed,
          last_status: r.last_status,
          last_response_time_ms: r.last_response_time_ms
        }
      )
    )
  end

  # device_uid is nullable on the coverage table (a swept host not yet
  # matched to inventory), so a device_uid equality filter cannot find those
  # rows -- `x = NULL` never matches in SQL. Look up by ip instead.
  defp coverage_rows_by_ip(day, ip) do
    Repo.all(
      from(r in "sweep_coverage_daily",
        prefix: "platform",
        where: r.day == ^day and r.ip == ^ip,
        select: %{
          sweep_group_id: type(r.sweep_group_id, :binary_id),
          agent_id: r.agent_id,
          execution_count: r.execution_count,
          available_count: r.available_count,
          unavailable_count: r.unavailable_count,
          error_count: r.error_count,
          scanned_ports: r.scanned_ports,
          open_ports: r.open_ports,
          modes_requested: r.modes_requested,
          modes_observed: r.modes_observed,
          last_status: r.last_status,
          last_response_time_ms: r.last_response_time_ms
        }
      )
    )
  end
end
