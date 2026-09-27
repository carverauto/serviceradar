defmodule ServiceRadar.NetworkDiscovery.RuntimeTopologyProjectionConcurrencyTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.NetworkDiscovery.RuntimeTopologyProjection
  alias ServiceRadar.Repo

  @moduletag :integration
  @moduletag sandbox: :unboxed

  test "overlapping refreshes publish one complete generation and matching metadata" do
    assert {:ok, %{rows: 1}} =
             RuntimeTopologyProjection.refresh_from_graph(graph: __MODULE__.SeedGraph)

    parent = self()

    on_exit(fn ->
      Repo.query!("DELETE FROM platform.runtime_topology_links")

      Repo.query!("""
      DELETE FROM platform.runtime_topology_projection_meta
      WHERE projection_name IN ('runtime_topology_links', 'runtime_topology_links_complete')
      """)
    end)

    first =
      Task.async(fn ->
        Repo.transaction(fn ->
          result = RuntimeTopologyProjection.refresh_from_graph(graph: __MODULE__.FirstGraph)
          send(parent, {:first_publication_ready, result})

          receive do
            :commit -> result
          after
            15_000 -> Repo.rollback(:publication_not_released)
          end
        end)
      end)

    try do
      assert_receive {:first_publication_ready, {:ok, %{rows: 1}}}, 10_000

      second =
        Task.async(fn ->
          Repo.transaction(fn ->
            %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:second_backend, backend_pid})
            RuntimeTopologyProjection.refresh_from_graph(graph: __MODULE__.SecondGraph)
          end)
        end)

      try do
        assert_receive {:second_backend, backend_pid}, 10_000
        assert_backend_waiting_for_lock(backend_pid, System.monotonic_time(:millisecond) + 10_000)
        send(first.pid, :commit)

        assert {:ok, {:ok, %{rows: 1}}} = Task.await(first, 10_000)
        assert {:ok, {:ok, %{rows: 1}}} = Task.await(second, 10_000)

        assert {:ok, [%{"local_device_id" => "sr:host03", "neighbor_device_id" => "sr:host04"}]} =
                 RuntimeTopologyProjection.read_cached_links(limit: :all)

        assert %{rows: [[1, 1, true]]} =
                 Repo.query!("""
                 SELECT current.row_count, complete.row_count,
                        current.refreshed_at = complete.refreshed_at
                 FROM platform.runtime_topology_projection_meta AS current
                 JOIN platform.runtime_topology_projection_meta AS complete
                   ON complete.projection_name = 'runtime_topology_links_complete'
                 WHERE current.projection_name = 'runtime_topology_links'
                 """)
      after
        Task.shutdown(second, :brutal_kill)
      end
    after
      send(first.pid, :commit)
      Task.shutdown(first, :brutal_kill)
    end
  end

  defmodule SeedGraph do
    @moduledoc false
    def query(_query) do
      {:ok, [%{"local_device_id" => "sr:host05", "neighbor_device_id" => "sr:host06"}]}
    end
  end

  defmodule FirstGraph do
    @moduledoc false
    def query(_query) do
      {:ok, [%{"local_device_id" => "sr:host01", "neighbor_device_id" => "sr:host02"}]}
    end
  end

  defmodule SecondGraph do
    @moduledoc false
    def query(_query) do
      {:ok, [%{"local_device_id" => "sr:host03", "neighbor_device_id" => "sr:host04"}]}
    end
  end

  defp assert_backend_waiting_for_lock(backend_pid, deadline) do
    case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend_pid]) do
      %{rows: [["Lock"]]} ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline,
               "second refresh did not overlap a database lock held by the first"

        Process.sleep(10)
        assert_backend_waiting_for_lock(backend_pid, deadline)
    end
  end
end
