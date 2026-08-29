defmodule ServiceRadar.Edge.LaneSupervisorTest do
  @moduledoc """
  The lane's accounting and its transport must share a restart boundary.

  As `:one_for_one` siblings they did not, and that quietly relaxed the bound: `PublisherPool.init/1`
  builds an EMPTY window, so restarting only the pool made the whole grant available again while
  the requests admitted under the old window were still in flight on the untouched connection.

  `async: false`: the pool registers a global name.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.LaneSupervisor
  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublisherPool

  # A port nothing is listening on: Gnat retries in the background with a long backoff, which is
  # irrelevant here -- these assert supervision structure, not connectivity.
  defp opts(lane, extra \\ []) do
    [
      lane: lane,
      connection_settings: %{host: "127.0.0.1", port: 14_222},
      backoff_period: 3_600_000,
      credits: [frame_credits: 1, byte_credits: 100]
    ] ++ extra
  end

  describe "the lane is one restart unit" do
    test "its strategy is :one_for_all" do
      {:ok, {flags, _children}} = LaneSupervisor.init(opts(:bulk))

      # The whole finding in one assertion: under :one_for_one a pool restart discards the
      # reservations while its in-flight requests survive on the connection.
      assert flags.strategy === :one_for_all
    end

    test "it supervises exactly its own connection and its own pool, connection FIRST" do
      specs = LaneSupervisor.child_specs(opts(:interactive))

      assert Enum.map(specs, & &1.id) === [
               PublisherLane.connection_name(:interactive),
               PublisherPool.via(:interactive)
             ]

      # NOT VACUOUS: a different lane yields different ids, so this cannot pass by hard-coding.
      other = LaneSupervisor.child_specs(opts(:recovery))

      assert Enum.map(other, & &1.id) === [
               PublisherLane.connection_name(:recovery),
               PublisherPool.via(:recovery)
             ]
    end
  end

  describe "a crash takes the whole lane with it" do
    setup do
      {:ok, sup} = LaneSupervisor.start_link(opts(:bulk, name: :lane_sup_under_test))

      on_exit(fn ->
        # Racy by nature: the unit may already have gone down with the crash under test.
        try do
          Supervisor.stop(sup, :normal)
        catch
          :exit, _ -> :ok
        end
      end)

      %{sup: sup}
    end

    defp connection_pid(sup) do
      sup
      |> Supervisor.which_children()
      |> Enum.find_value(fn {id, pid, _t, _m} ->
        if id === PublisherLane.connection_name(:bulk), do: pid
      end)
    end

    defp await(fun, tries \\ 200)
    defp await(_fun, 0), do: flunk("condition never held")

    defp await(fun, tries) do
      if fun.(), do: :ok, else: Process.sleep(10) && await(fun, tries - 1)
    end

    test "killing the POOL also restarts the connection", %{sup: sup} do
      conn_before = connection_pid(sup)
      pool_before = Process.whereis(PublisherPool.via(:bulk))
      assert is_pid(conn_before) and is_pid(pool_before)

      Process.exit(pool_before, :kill)

      await(fn ->
        pid = Process.whereis(PublisherPool.via(:bulk))
        is_pid(pid) and pid !== pool_before
      end)

      await(fn ->
        pid = connection_pid(sup)
        is_pid(pid) and pid !== conn_before
      end)

      # THE POINT: the connection is a NEW process, so the requests admitted under the window the
      # restart just emptied went with it. A surviving connection would still be carrying them
      # while the fresh window handed their credits to someone else.
      refute connection_pid(sup) === conn_before
    end

    test "killing the RECONNECT MANAGER also restarts the pool", %{sup: sup} do
      # NAMED for what it actually kills. The supervised child is Gnat.ConnectionSupervisor -- the
      # reconnect manager -- not the transport socket it owns, and an ordinary NATS reconnect does
      # NOT exit it. So this binds process death of that child, not reconnect behaviour;
      # reservations deliberately survive reconnects (see LaneSupervisor's moduledoc).
      conn_before = connection_pid(sup)
      pool_before = Process.whereis(PublisherPool.via(:bulk))

      Process.exit(conn_before, :kill)

      await(fn ->
        pid = Process.whereis(PublisherPool.via(:bulk))
        is_pid(pid) and pid !== pool_before
      end)

      refute Process.whereis(PublisherPool.via(:bulk)) === pool_before
    end
  end
end
