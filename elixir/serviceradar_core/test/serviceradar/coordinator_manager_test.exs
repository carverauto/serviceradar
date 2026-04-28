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

  test "coordinator connection can bypass pooled repo host" do
    opts = [
      url: "ecto://serviceradar:secret@cnpg-pooler-rw.demo.svc.cluster.local:5432/serviceradar",
      ssl: true
    ]

    new_opts =
      CoordinatorManager.coordinator_connection_opts(
        opts,
        "cnpg-rw.demo.svc.cluster.local"
      )

    assert Keyword.fetch!(new_opts, :url) ==
             "ecto://serviceradar:secret@cnpg-rw.demo.svc.cluster.local:5432/serviceradar"
  end
end
