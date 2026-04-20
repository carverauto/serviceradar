defmodule ServiceRadar.CoordinatorManagerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Cluster.CoordinatorManager

  test "demotes when the coordinator child tree exits" do
    ref = make_ref()

    state = %{
      conn: nil,
      conn_mon: nil,
      leader?: true,
      coordinator_child: nil,
      coordinator_child_mon: ref
    }

    assert {:noreply, new_state} =
             CoordinatorManager.handle_info({:DOWN, ref, :process, self(), :shutdown}, state)

    refute new_state.leader?
    assert new_state.coordinator_child == nil
    assert new_state.coordinator_child_mon == nil
  end
end
