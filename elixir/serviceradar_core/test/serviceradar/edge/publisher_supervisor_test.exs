defmodule ServiceRadar.Edge.PublisherSupervisorTest do
  @moduledoc """
  The pools only bound anything if something OWNS them. Before this supervisor existed the pool
  code was exercised solely by tests that started their own pool, so at runtime no process held a
  lane's window at all -- a gap none of the pool's own tests could see.

  `async: false`: the pools register global names (`PublisherPool.via/1`), so a concurrent test
  starting the real topology would collide.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublisherPool
  alias ServiceRadar.Edge.PublisherSupervisor

  describe "the declared child inventory" do
    test "exactly one pool per lane, keyed by the lane's registered name" do
      specs = PublisherSupervisor.child_specs()

      assert length(specs) === length(PublisherLane.lanes())

      assert Enum.map(specs, & &1.id) ===
               Enum.map(PublisherLane.lanes(), &PublisherPool.via/1)
    end

    test "each child starts a PublisherPool for ITS lane, under ITS name" do
      for spec <- PublisherSupervisor.child_specs() do
        {PublisherPool, :start_link, [opts]} = spec.start
        lane = Keyword.fetch!(opts, :class)

        # id, class and registered name must all name the SAME lane. Checking ids alone passes
        # while every child is a :bulk pool wearing three different ids.
        assert lane in PublisherLane.lanes()
        assert spec.id === PublisherPool.via(lane)
        assert Keyword.fetch!(opts, :name) === PublisherPool.via(lane)
      end
    end

    test "init/1 supervises exactly that inventory" do
      {:ok, {_flags, children}} = PublisherSupervisor.init([])

      # Binding init/1, not just child_specs/1: supervising only the first spec is a mutation the
      # inventory assertions cannot see.
      assert Enum.map(children, & &1.id) ===
               Enum.map(PublisherLane.lanes(), &PublisherPool.via/1)
    end
  end

  describe "the running topology" do
    test "starts one live pool per lane, each on its own connection" do
      start_supervised!(PublisherSupervisor)

      for lane <- PublisherLane.lanes() do
        pid = Process.whereis(PublisherPool.via(lane))
        assert is_pid(pid), "no pool registered for #{inspect(lane)}"

        capacity = PublisherPool.capacity(pid)
        assert capacity.class === lane
        assert capacity.connection === PublisherLane.connection_name(lane)
      end
    end

    test "the supervisor owns exactly three pools and nothing else" do
      pid = start_supervised!(PublisherSupervisor)

      children = Supervisor.which_children(pid)
      assert length(children) === 3

      # NOT VACUOUS: three DISTINCT lanes, so a supervisor starting the same pool three times
      # under different ids would fail here.
      ids = children |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert ids === PublisherLane.lanes() |> Enum.map(&PublisherPool.via/1) |> Enum.sort()
    end

    test "each pool starts with its OWN credits, unshared" do
      start_supervised!(PublisherSupervisor)

      bulk = PublisherPool.via(:bulk)
      recovery = PublisherPool.via(:recovery)

      # Each pool compared against ITS OWN earlier value. Comparing bulk's capacity to recovery's
      # would differ on the `class` key whatever the credits did, and would pass unchanged even if
      # the two shared one window.
      bulk_before = PublisherPool.capacity(bulk)
      recovery_before = PublisherPool.capacity(recovery)

      assert :ok = PublisherPool.admit(bulk, 1, 10, 1_000)

      assert PublisherPool.capacity(recovery) === recovery_before
      refute PublisherPool.capacity(bulk) === bulk_before
    end
  end
end
