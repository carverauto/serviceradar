defmodule ServiceRadar.Scans.ScanRunTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Scans.ScanRun

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  defp actor, do: SystemActor.system(:scan_run_test)

  test "creates a scan run with modes/ports/targets and defaults to pending" do
    {:ok, run} =
      ScanRun.create(
        %{
          agent_id: "agent-1",
          modes: ["icmp", "tcp"],
          ports: [22, 443],
          targets: ["10.0.0.1", "10.0.0.2"],
          target_count: 2,
          options: %{"mtr_protocol" => "icmp"}
        },
        actor: actor()
      )

    assert run.status == :pending
    assert run.modes == [:icmp, :tcp]
    assert run.ports == [22, 443]
    assert run.target_count == 2

    {:ok, fetched} = ScanRun.get(run.id, actor: actor())
    assert fetched.id == run.id
  end

  test "advances lifecycle to running then completed with counters" do
    {:ok, run} =
      ScanRun.create(
        %{agent_id: "agent-2", modes: ["icmp"], targets: ["10.0.0.5"], target_count: 1},
        actor: actor()
      )

    {:ok, running} =
      ScanRun.update_status(run, %{status: :running, started_at: DateTime.utc_now()},
        actor: actor()
      )

    assert running.status == :running
    assert running.started_at

    {:ok, done} =
      ScanRun.update_status(
        running,
        %{status: :completed, finished_at: DateTime.utc_now(), hosts_up: 1, ports_open: 0},
        actor: actor()
      )

    assert done.status == :completed
    assert done.hosts_up == 1
  end

  test "list_recent returns created runs newest first" do
    {:ok, _} =
      ScanRun.create(
        %{agent_id: "agent-3", modes: ["icmp"], targets: ["10.0.0.9"], target_count: 1},
        actor: actor()
      )

    {:ok, runs} = ScanRun.list_recent(actor: actor())
    assert Enum.any?(runs, &(&1.agent_id == "agent-3"))
  end
end
