defmodule ServiceRadar.StatusAdmissionIsolationTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Admission.Lane
  alias ServiceRadar.StatusHandler

  setup do
    topology = ServiceRadar.TestSupport.start_ingestion_topology!()
    %{topology: topology}
  end

  test "worker-tree downtime rejects admission without restarting the dispatcher", %{
    topology: topology
  } do
    handler = Process.whereis(StatusHandler)

    status = %{
      source: "synthetic-heartbeat",
      service_name: "agent",
      agent_id: "agent01",
      partition: "test-partition",
      message: nil
    }

    descriptor = Lane.descriptor(status, 15_000)

    assert :ok = Supervisor.terminate_child(topology, ServiceRadar.Ingestion.Supervisor)

    assert {:error, {:admission_lane_unavailable, :noproc}} =
             GenServer.call(handler, {:reserve_status, descriptor}, 500)

    assert Process.whereis(StatusHandler) == handler
    assert Process.alive?(handler)

    assert {:ok, _workers} =
             Supervisor.restart_child(topology, ServiceRadar.Ingestion.Supervisor)

    assert {:ok, {lane, _reservation}} =
             GenServer.call(handler, {:reserve_status, descriptor}, 500)

    assert Process.alive?(lane)
    assert Process.whereis(StatusHandler) == handler
  end
end
