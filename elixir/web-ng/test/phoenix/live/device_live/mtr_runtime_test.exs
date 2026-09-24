defmodule ServiceRadarWebNGWeb.DeviceLive.MtrRuntimeTest do
  # Not async: the registry-absent case uses the real dispatcher and command bus,
  # and depends on no test in this BEAM having started the process registry,
  # which web-ng never joins.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.ProcessRegistry
  alias ServiceRadarWebNGWeb.DeviceLive.MtrRuntime

  @moduletag :db_free

  @device_ip "192.0.2.10"
  @policy %{id: "policy-01", name: "Baseline", target_selector: %{}}

  describe "queue_trace/3" do
    test "an enabled policy on a node without the process registry returns a readable error" do
      refute ProcessRegistry.registry_present?()

      assert {:error, message} =
               MtrRuntime.queue_trace(socket(), @device_ip, list_policies: fn -> {:ok, [@policy]} end)

      assert message ==
               "No agents connected " <>
                 "(MTR policy: No MTR-capable agent is online in the device's partition)"
    end

    test "falls back to the first connected agent when no policy dispatches" do
      test_pid = self()

      dispatch_command = fn agent_id, "mtr.run", payload, opts ->
        send(test_pid, {:dispatched, agent_id, payload, opts})
        {:ok, "command-01"}
      end

      assert {:ok, "agent-01"} =
               MtrRuntime.queue_trace(socket(), @device_ip,
                 list_policies: fn -> {:ok, [@policy]} end,
                 dispatch_policy: fn _ctx, _policy, :baseline -> {:error, :cooldown_active} end,
                 list_agents: fn -> [%{agent_id: "agent-01"}, %{agent_id: "agent-02"}] end,
                 dispatch_command: dispatch_command
               )

      assert_received {:dispatched, "agent-01", %{"target" => @device_ip, "protocol" => "icmp"}, opts}

      assert opts[:context] == %{
               "device_uid" => "sr:00000000-0000-0000-0000-000000000001",
               "target_ip" => @device_ip
             }
    end

    test "returns the first agent a policy dispatched to without a direct dispatch" do
      assert {:ok, "agent-02"} =
               MtrRuntime.queue_trace(socket(), @device_ip,
                 list_policies: fn -> {:ok, [@policy]} end,
                 dispatch_policy: fn _ctx, _policy, :baseline -> {:ok, ["agent-02", "agent-03"]} end,
                 list_agents: direct_dispatch_probe()
               )

      refute_received :direct_dispatch_attempted
    end

    test "does not dispatch again when the policy dispatched but the cooldown row failed" do
      log =
        capture_log(fn ->
          assert {:ok, "the policy-selected agents"} =
                   MtrRuntime.queue_trace(socket(), @device_ip,
                     list_policies: fn -> {:ok, [@policy, @policy]} end,
                     dispatch_policy: fn _ctx, _policy, :baseline ->
                       {:error, {:window_persist_failed, :timeout}}
                     end,
                     list_agents: direct_dispatch_probe()
                   )
        end)

      assert log =~ "window_persist_failed"
      refute_received :direct_dispatch_attempted
    end

    test "maps a command-bus rejection of the direct dispatch to a readable message" do
      assert {:error, "Agent is already running the maximum number of concurrent MTR traces"} =
               MtrRuntime.queue_trace(socket(), @device_ip,
                 list_policies: fn -> {:ok, []} end,
                 list_agents: fn -> [%{"agent_id" => "agent-01"}] end,
                 dispatch_command: fn _agent_id, _type, _payload, _opts ->
                   {:error, {:agent_busy, :too_many_concurrent_mtr_traces}}
                 end
               )

      assert {:error, "Agent agent-01 is offline (MTR policy: The MTR policy's preferred agent is not online)"} =
               MtrRuntime.queue_trace(socket(), @device_ip,
                 list_policies: fn -> {:ok, [@policy]} end,
                 dispatch_policy: fn _ctx, _policy, :baseline -> {:error, :preferred_agent_unavailable} end,
                 list_agents: fn -> [%{agent_id: "agent-01"}] end,
                 dispatch_command: fn _agent_id, _type, _payload, _opts ->
                   {:error, {:agent_offline, "agent-01"}}
                 end
               )
    end

    test "prefers a policy that applied over one whose scope excluded the device" do
      reasons = %{"policy-01" => :out_of_scope, "policy-02" => :no_candidates}

      assert {:error, "No agents connected (MTR policy: No MTR-capable agent is online in the device's partition)"} =
               MtrRuntime.queue_trace(socket(), @device_ip,
                 list_policies: fn -> {:ok, [@policy, %{@policy | id: "policy-02"}]} end,
                 dispatch_policy: fn _ctx, policy, :baseline -> {:error, Map.fetch!(reasons, policy.id)} end,
                 list_agents: fn -> [] end
               )
    end

    test "a policy dispatch that raises falls through instead of crashing" do
      log =
        capture_log(fn ->
          assert {:error, "No agents connected (MTR policy: The MTR policy dispatch failed unexpectedly)"} =
                   MtrRuntime.queue_trace(socket(), @device_ip,
                     list_policies: fn -> {:ok, [@policy]} end,
                     dispatch_policy: fn _ctx, _policy, _mode -> raise ArgumentError, "no ETS table" end,
                     list_agents: fn -> [] end
                   )
        end)

      assert log =~ "MTR policy dispatch raised"
    end

    test "never raises into the LiveView when policy lookup or dispatch raise or exit" do
      log =
        capture_log(fn ->
          assert {:error, "MTR could not be queued because of an unexpected error"} =
                   MtrRuntime.queue_trace(socket(), @device_ip,
                     list_policies: fn -> raise RuntimeError, "repo not started" end
                   )

          assert {:error, "MTR could not be queued because of an unexpected error"} =
                   MtrRuntime.queue_trace(socket(), @device_ip,
                     list_policies: fn -> {:ok, []} end,
                     list_agents: fn -> [%{agent_id: "agent-01"}] end,
                     dispatch_command: fn _agent_id, _type, _payload, _opts ->
                       exit({:timeout, {GenServer, :call, []}})
                     end
                   )
        end)

      assert log =~ "Queue MTR raised"
      assert log =~ "Queue MTR exited"
    end

    test "a failed policy lookup still falls back to direct dispatch" do
      log =
        capture_log(fn ->
          assert {:ok, "agent-01"} =
                   MtrRuntime.queue_trace(socket(), @device_ip,
                     list_policies: fn -> {:error, :database_unavailable} end,
                     list_agents: fn -> [%{agent_id: "agent-01"}] end,
                     dispatch_command: fn _agent_id, _type, _payload, _opts -> {:ok, "command-01"} end
                   )
        end)

      assert log =~ "Listing enabled MTR policies failed"
    end

    test "rejects a device without an IP before consulting any policy" do
      test_pid = self()

      list_policies = fn ->
        send(test_pid, :policies_listed)
        {:ok, []}
      end

      assert {:error, "No device IP available for MTR"} =
               MtrRuntime.queue_trace(socket(), nil, list_policies: list_policies)

      refute_received :policies_listed
    end
  end

  describe "dispatch_error_message/1" do
    test "maps dispatcher and command-bus reasons to operator-readable text" do
      for reason <- [
            :no_candidates,
            :preferred_agent_unavailable,
            :cooldown_active,
            :out_of_scope,
            :no_selected_agents,
            :dispatch_failed,
            :missing_target,
            :registry_unavailable,
            :control_session_unavailable,
            {:agent_offline, "agent-01"},
            {:agent_capability_missing, "agent-01", "mtr"},
            {:agent_partition_mismatch, "agent-01", "site-02"},
            {:agent_partition_ambiguous, "agent-01"},
            {:window_persist_failed, :timeout}
          ] do
        message = MtrRuntime.dispatch_error_message(reason)
        refute message =~ "Failed to run MTR", "#{inspect(reason)} has no readable message"
        refute message =~ ":", "#{inspect(reason)} leaks an atom: #{message}"
      end
    end

    test "falls back to the inspected reason for anything unknown" do
      assert MtrRuntime.dispatch_error_message({:unexpected, 1}) ==
               "Failed to run MTR: {:unexpected, 1}"
    end
  end

  # Records a direct-dispatch attempt. Asserting inside the injected function
  # would not work: the agent listing rescues whatever it raises.
  defp direct_dispatch_probe do
    test_pid = self()

    fn ->
      send(test_pid, :direct_dispatch_attempted)
      []
    end
  end

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        device_uid: "sr:00000000-0000-0000-0000-000000000001",
        device_row: %{"partition" => "default"}
      }
    }
  end
end
