defmodule ServiceRadarWebNG.Topology.WorldDetailsTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Topology.WorldCache
  alias ServiceRadarWebNG.Topology.WorldDetails

  @moduletag :db_free

  test "abandoning a detail request releases its blocked read worker" do
    tasks = ServiceRadarWebNG.Topology.WorldDetailTasks
    guards = ServiceRadarWebNG.Topology.WorldDetailGuards
    supervisor = start_supervised!({Task.Supervisor, name: tasks, max_children: 16})
    start_supervised!(Supervisor.child_spec({Task.Supervisor, name: guards, max_children: 16}, id: guards))
    cache = start_supervised!({WorldCache, task_supervisor: tasks, pubsub: ServiceRadar.PubSub})
    :ok = :sys.suspend(cache)
    :erlang.trace(supervisor, true, [:procs, {:tracer, self()}])

    params = %{
      "kind" => "device",
      "id" => "invented-router-a",
      "layout_version" => "00000000-0000-4000-8000-000000000477",
      "generation" => "1"
    }

    # A blocked real cache keeps the read alive without supplying a fabricated
    # world or receipt. Abandoning the caller must cancel this pending read.
    try do
      caller = spawn(fn -> WorldDetails.fetch(nil, params) end)
      assert_receive {:trace, ^supervisor, :spawn, worker, _mfa}
      ref = Process.monitor(worker)
      Process.exit(caller, :shutdown)
      assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 1_000
    after
      :sys.resume(cache)
    end
  end
end
