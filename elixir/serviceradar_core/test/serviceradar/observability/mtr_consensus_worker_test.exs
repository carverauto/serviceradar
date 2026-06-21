defmodule ServiceRadar.Observability.MtrConsensusWorkerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.MtrConsensusWorker

  test "emits consensus signal for incident cohort once minimum evidence is met" do
    parent = self()

    emitter = fn consensus_result, context, outcomes ->
      send(parent, {:emitted, consensus_result, context, outcomes})
      :ok
    end

    policy_provider = fn _ctx ->
      %{
        consensus_min_agents: 2,
        consensus_mode: "majority"
      }
    end

    {:ok, pid} =
      start_supervised(
        {MtrConsensusWorker,
         name: :"mtr-consensus-worker-#{System.unique_integer([:positive])}",
         subscribe: false,
         emitter: emitter,
         policy_provider: policy_provider}
      )

    send(pid, {:command_result, mtr_result("agent-a", "inc-1", false, 0.0, 0.0)})
    refute_receive {:emitted, _, _, _}, 100

    send(pid, {:command_result, mtr_result("agent-b", "inc-1", false, 0.0, 0.0)})

    assert_receive {:emitted, consensus_result, context, outcomes}, 1_000
    assert consensus_result.classification == :target_outage
    assert context["incident_correlation_id"] == "inc-1"
    assert length(outcomes) == 2
  end

  test "ignores non-mtr command results" do
    parent = self()

    emitter = fn consensus_result, context, outcomes ->
      send(parent, {:emitted, consensus_result, context, outcomes})
      :ok
    end

    {:ok, pid} =
      start_supervised(
        {MtrConsensusWorker,
         name: :"mtr-consensus-worker-#{System.unique_integer([:positive])}",
         subscribe: false,
         emitter: emitter,
         policy_provider: fn _ -> %{consensus_min_agents: 1} end}
      )

    send(pid, {:command_result, %{command_type: "sweep.run_group", command_id: "c1"}})
    refute_receive {:emitted, _, _, _}, 200
  end

  test "does not re-emit the same incident/classification identity repeatedly" do
    parent = self()

    emitter = fn consensus_result, context, outcomes ->
      send(
        parent,
        {:emitted, consensus_result.classification, context["incident_correlation_id"],
         length(outcomes)}
      )

      :ok
    end

    {:ok, pid} =
      start_supervised(
        {MtrConsensusWorker,
         name: :"mtr-consensus-worker-#{System.unique_integer([:positive])}",
         subscribe: false,
         emitter: emitter,
         policy_provider: fn _ -> %{consensus_min_agents: 2, consensus_mode: "majority"} end}
      )

    send(pid, {:command_result, mtr_result("agent-a", "inc-dedupe", false, 0.0, 0.0)})
    send(pid, {:command_result, mtr_result("agent-b", "inc-dedupe", false, 0.0, 0.0)})
    assert_receive {:emitted, :target_outage, "inc-dedupe", 2}, 1_000

    # Replaying the same outcome class should not emit again.
    send(pid, {:command_result, mtr_result("agent-c", "inc-dedupe", false, 0.0, 0.0)})
    refute_receive {:emitted, :target_outage, "inc-dedupe", _}, 250
  end

  test "re-emits non-incident command cohort when classification escalates" do
    parent = self()
    command_id = Ecto.UUID.generate()

    emitter = fn consensus_result, context, outcomes ->
      send(
        parent,
        {:emitted, consensus_result.classification, context["incident_correlation_id"],
         context["trigger_mode"], length(outcomes)}
      )

      :ok
    end

    {:ok, pid} =
      start_supervised(
        {MtrConsensusWorker,
         name: :"mtr-consensus-worker-#{System.unique_integer([:positive])}",
         subscribe: false,
         emitter: emitter,
         policy_provider: fn _ -> %{consensus_min_agents: 2, consensus_mode: "majority"} end}
      )

    send(
      pid,
      {:command_result,
       mtr_result("agent-a", nil, true, 35.0, 30.0,
         command_id: command_id,
         trigger_mode: "baseline"
       )}
    )

    send(
      pid,
      {:command_result,
       mtr_result("agent-b", nil, true, 35.0, 30.0,
         command_id: command_id,
         trigger_mode: "baseline"
       )}
    )

    assert_receive {:emitted, :degraded_path, nil, "baseline", 2}, 1_000

    send(
      pid,
      {:command_result,
       mtr_result("agent-a", nil, false, 0.0, 0.0,
         command_id: command_id,
         trigger_mode: "baseline"
       )}
    )

    send(
      pid,
      {:command_result,
       mtr_result("agent-b", nil, false, 0.0, 0.0,
         command_id: command_id,
         trigger_mode: "baseline"
       )}
    )

    assert_receive {:emitted, :target_outage, nil, "baseline", 2}, 1_000
  end

  test "uses destination hop RTT instead of inflated transit hop RTT" do
    parent = self()

    emitter = fn consensus_result, _context, outcomes ->
      send(parent, {:emitted, consensus_result, outcomes})
      :ok
    end

    {:ok, pid} =
      start_supervised(
        {MtrConsensusWorker,
         name: :"mtr-consensus-worker-#{System.unique_integer([:positive])}",
         subscribe: false,
         emitter: emitter,
         policy_provider: fn _ -> %{consensus_min_agents: 2, consensus_mode: "majority"} end}
      )

    hops = [
      %{"hop_number" => 1, "addr" => "192.0.2.1", "avg_us" => 5_000},
      %{"hop_number" => 2, "addr" => "198.51.100.1", "avg_us" => 900_000},
      %{"hop_number" => 3, "addr" => "8.8.8.8", "avg_us" => 30_000}
    ]

    send(pid, {:command_result, mtr_result("agent-a", "inc-transit-rtt", true, 0.0, hops)})
    send(pid, {:command_result, mtr_result("agent-b", "inc-transit-rtt", true, 0.0, hops)})

    assert_receive {:emitted, consensus_result, outcomes}, 1_000
    assert consensus_result.classification == :healthy
    assert Enum.all?(outcomes, &(&1.avg_rtt_ms == 30.0))
  end

  test "uses destination hop loss instead of inflated transit hop loss" do
    parent = self()

    emitter = fn consensus_result, _context, outcomes ->
      send(parent, {:emitted, consensus_result, outcomes})
      :ok
    end

    {:ok, pid} =
      start_supervised(
        {MtrConsensusWorker,
         name: :"mtr-consensus-worker-#{System.unique_integer([:positive])}",
         subscribe: false,
         emitter: emitter,
         policy_provider: fn _ -> %{consensus_min_agents: 2, consensus_mode: "majority"} end}
      )

    hops = [
      %{"hop_number" => 1, "addr" => "192.0.2.1", "loss_pct" => 0.0, "avg_us" => 5_000},
      %{"hop_number" => 2, "addr" => "198.51.100.1", "loss_pct" => 80.0, "avg_us" => 900_000},
      %{"hop_number" => 3, "addr" => "8.8.8.8", "loss_pct" => 0.0, "avg_us" => 30_000}
    ]

    send(pid, {:command_result, mtr_result("agent-a", "inc-transit-loss", true, 0.0, hops)})
    send(pid, {:command_result, mtr_result("agent-b", "inc-transit-loss", true, 0.0, hops)})

    assert_receive {:emitted, consensus_result, outcomes}, 1_000
    assert consensus_result.classification == :healthy
    assert Enum.all?(outcomes, &(&1.packet_loss_pct == 0.0))
  end

  defp mtr_result(agent_id, incident_id, target_reached, loss_pct, avg_rtt_ms, opts \\ []) do
    hops =
      if is_list(avg_rtt_ms) do
        avg_rtt_ms
      else
        [%{"loss_pct" => loss_pct, "avg_rtt_ms" => avg_rtt_ms}]
      end

    %{
      command_id: Keyword.get(opts, :command_id, Ecto.UUID.generate()),
      command_type: "mtr.run",
      agent_id: agent_id,
      partition_id: "default",
      incident_correlation_id: incident_id,
      target_device_uid: "dev-1",
      trigger_mode: Keyword.get(opts, :trigger_mode, "incident"),
      success: true,
      payload: %{
        "target" => "8.8.8.8",
        "trace" => %{
          "target_reached" => target_reached,
          "target_ip" => "8.8.8.8",
          "hops" => hops
        }
      }
    }
  end
end
