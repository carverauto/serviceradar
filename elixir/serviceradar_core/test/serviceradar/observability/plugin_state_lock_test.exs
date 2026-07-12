defmodule ServiceRadar.Observability.PluginStateLockTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Observability.ServiceStateRegistry.PluginState
  alias ServiceRadar.Repo

  @tag sandbox: :unboxed
  test "shared identity mutations block the exclusive cleanup lock" do
    parent = self()

    identity = %{
      agent_id: "lock-agent-#{System.unique_integer([:positive])}",
      partition: "default",
      service_type: "plugin",
      service_name: "lock-service"
    }

    shared_holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          assert :ok = PluginState.acquire_lock(identity)
          send(parent, :shared_plugin_state_lock_held)

          receive do
            :release_shared_plugin_state_lock -> :ok
          after
            5_000 -> raise "timed out waiting to release shared plugin state lock"
          end
        end)
      end)

    assert_receive :shared_plugin_state_lock_held, 5_000

    exclusive_waiter =
      Task.async(fn ->
        result =
          Repo.transaction(fn ->
            assert :ok = PluginState.acquire_reconciliation_lock()
            send(parent, :exclusive_plugin_state_lock_acquired)
          end)

        result
      end)

    refute_receive :exclusive_plugin_state_lock_acquired, 250
    send(shared_holder.pid, :release_shared_plugin_state_lock)

    assert {:ok, :ok} = Task.await(shared_holder, 5_000)
    assert {:ok, :exclusive_plugin_state_lock_acquired} = Task.await(exclusive_waiter, 5_000)
    assert_receive :exclusive_plugin_state_lock_acquired
  end
end
