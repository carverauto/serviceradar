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

  test "coordinator connection enforces single-connection pool and at least a 15s heartbeat timeout" do
    opts = [
      hostname: "cnpg-rw.demo.svc.cluster.local",
      timeout: 5_000,
      ssl: true
    ]

    new_opts = CoordinatorManager.coordinator_connection_opts(opts, nil)

    assert Keyword.fetch!(new_opts, :pool_size) == 1
    assert Keyword.fetch!(new_opts, :timeout) == 15_000

    larger_opts = CoordinatorManager.coordinator_connection_opts([timeout: 30_000], "")
    assert Keyword.fetch!(larger_opts, :timeout) == 30_000
  end

  test "coordinator connection drops repo pool and queue options for standalone Postgrex sessions" do
    opts = [
      url: "ecto://serviceradar:secret@cnpg-rw.example.svc.cluster.local:5432/serviceradar",
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 16,
      name: ServiceRadar.Repo,
      queue_target: 1_000,
      queue_interval: 1_000,
      ownership_timeout: 120_000,
      ssl: true
    ]

    new_opts = CoordinatorManager.coordinator_connection_opts(opts, nil)

    assert Keyword.fetch!(new_opts, :pool_size) == 1
    assert Keyword.fetch!(new_opts, :ssl) == true
    refute Keyword.has_key?(new_opts, :pool)
    refute Keyword.has_key?(new_opts, :name)
    refute Keyword.has_key?(new_opts, :queue_target)
    refute Keyword.has_key?(new_opts, :queue_interval)
    refute Keyword.has_key?(new_opts, :ownership_timeout)
  end
end
