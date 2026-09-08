defmodule ServiceRadar.Plugins.RecoveryConfigDispatchTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.RecoveryConfigDispatch

  test "passes only the exact authenticated principal to the post-commit dispatcher" do
    test_pid = self()

    dispatcher = fn partition_id, agent_uid ->
      send(test_pid, {:config_push, partition_id, agent_uid})
      :ok
    end

    assert :ok =
             RecoveryConfigDispatch.dispatch_after_commit("agent-farm01", "farm01",
               config_dispatcher: dispatcher,
               config_dispatch_async?: false
             )

    assert_receive {:config_push, "farm01", "agent-farm01"}
    refute_receive {:config_push, _, _}
  end

  test "does not let a failed post-commit dispatch change the committed outcome" do
    test_pid = self()

    dispatcher = fn partition_id, agent_uid ->
      send(test_pid, {:config_push, partition_id, agent_uid})
      {:error, :agent_offline}
    end

    assert :ok =
             RecoveryConfigDispatch.dispatch_after_commit("agent-farm01", "farm01",
               config_dispatcher: dispatcher,
               config_dispatch_async?: false
             )

    assert_receive {:config_push, "farm01", "agent-farm01"}
  end

  test "invalid principal values do not invoke a dispatcher" do
    dispatcher = fn _partition_id, _agent_uid -> flunk("config dispatch must not be invoked") end

    assert :ok =
             RecoveryConfigDispatch.dispatch_after_commit("agent-farm01", " ",
               config_dispatcher: dispatcher,
               config_dispatch_async?: false
             )
  end
end
