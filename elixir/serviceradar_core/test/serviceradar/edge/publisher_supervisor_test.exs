defmodule ServiceRadar.Edge.PublisherSupervisorTest do
  @moduledoc """
  The pools only bound anything if something OWNS them, and the credits are only configurable if
  a deployment can actually change them. Both were claimed before they were true: the pools
  existed solely in tests, and the gateway started a bare supervisor so every deployment received
  the hard-coded defaults.

  `async: false`: the pools register global names (`PublisherPool.via/1`).
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.LaneSupervisor
  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublisherPool

  # Reservations key on the COMPLETE authenticated slot, never the bare sequence: one pool serves
  # every agent and spool in its class. `fp/1` fingerprints the publication, so the same sequence
  # is the same record retrying.
  alias ServiceRadar.Edge.PublisherSupervisor

  # Pools live inside each lane's restart unit now, so their specs come from LaneSupervisor. The
  # credits still come from PublisherSupervisor, which is what these tests are about.
  defp lane_pool_specs(opts \\ []) do
    Enum.map(PublisherLane.lanes(), fn lane ->
      [
        lane: lane,
        connection_settings: %{host: "127.0.0.1", port: 4222},
        backoff_period: 1_000,
        credits: PublisherSupervisor.credits_for(lane, opts)
      ]
      |> LaneSupervisor.child_specs()
      |> Enum.find(&(&1.id === PublisherPool.via(lane)))
    end)
  end

  defp k(seq),
    do: ServiceRadar.Edge.PublishWindow.key(<<0xA1>>, "agent-1", <<0xB2>>, seq, fp(seq))

  defp fp(seq), do: {:record, seq}

  describe "the declared pool inventory" do
    test "exactly one pool per lane, keyed by the lane's registered name" do
      specs = lane_pool_specs()

      assert length(specs) === length(PublisherLane.lanes())
      assert Enum.map(specs, & &1.id) === Enum.map(PublisherLane.lanes(), &PublisherPool.via/1)
    end

    test "each child starts a PublisherPool for ITS lane, under ITS name" do
      for spec <- lane_pool_specs() do
        {PublisherPool, :start_link, [opts]} = spec.start
        lane = Keyword.fetch!(opts, :class)

        # id, class and registered name must all name the SAME lane. Checking ids alone passes
        # while every child is a :bulk pool wearing three different ids.
        assert lane in PublisherLane.lanes()
        assert spec.id === PublisherPool.via(lane)
        assert Keyword.fetch!(opts, :name) === PublisherPool.via(lane)
      end
    end
  end

  describe "credits are configurable, not merely called configurable" do
    setup do
      previous = Application.get_env(:serviceradar_core, PublisherSupervisor)
      on_exit(fn -> restore(previous) end)
      :ok
    end

    test "defaults apply when nothing is configured" do
      Application.delete_env(:serviceradar_core, PublisherSupervisor)
      credits = PublisherSupervisor.credits_for(:bulk)

      assert Keyword.fetch!(credits, :frame_credits) === 64
      assert Keyword.fetch!(credits, :byte_credits) === 64 * 1024 * 1024
    end

    test "application config overrides the defaults for every lane" do
      # THE REGRESSION: the gateway starts a bare supervisor, so config is the only channel a
      # deployment has. If it did not reach the pools, "configurable" was false in production.
      Application.put_env(:serviceradar_core, PublisherSupervisor,
        frame_credits: 7,
        byte_credits: 111
      )

      for lane <- PublisherLane.lanes() do
        credits = PublisherSupervisor.credits_for(lane)
        assert Keyword.fetch!(credits, :frame_credits) === 7
        assert Keyword.fetch!(credits, :byte_credits) === 111
      end
    end

    test "a per-lane override beats the global value, for that lane only" do
      Application.put_env(:serviceradar_core, PublisherSupervisor,
        frame_credits: 7,
        byte_credits: 111,
        lane_credits: %{recovery: [frame_credits: 3]}
      )

      assert PublisherSupervisor.credits_for(:recovery)[:frame_credits] === 3
      # Unset keys still fall through to the global value.
      assert PublisherSupervisor.credits_for(:recovery)[:byte_credits] === 111

      # NOT VACUOUS: the other lanes are untouched, so this cannot pass by overriding everything.
      assert PublisherSupervisor.credits_for(:bulk)[:frame_credits] === 7
    end

    test "opts beat application config" do
      Application.put_env(:serviceradar_core, PublisherSupervisor, frame_credits: 7)
      assert PublisherSupervisor.credits_for(:bulk, frame_credits: 99)[:frame_credits] === 99
    end

    test "the configured credits reach the CHILD SPEC, not just credits_for/2" do
      # credits_for/2 being right is not the property that matters -- the pools have to be started
      # with those values. A spec builder that ignored it would pass every test above.
      Application.put_env(:serviceradar_core, PublisherSupervisor, frame_credits: 5)

      for spec <- lane_pool_specs() do
        {PublisherPool, :start_link, [opts]} = spec.start
        assert Keyword.fetch!(opts, :frame_credits) === 5
      end
    end

    defp restore(nil), do: Application.delete_env(:serviceradar_core, PublisherSupervisor)
    defp restore(value), do: Application.put_env(:serviceradar_core, PublisherSupervisor, value)
  end

  describe "the running pools" do
    setup do
      for spec <- lane_pool_specs(), do: start_supervised!(spec)

      # These specs deliberately take the POOL only -- the subject here is credits, not transport
      # -- but an accountant is CLOSED until a transport registers, so each needs a stand-in. What
      # the accountant binds to is a process LIFETIME, not anything a connection can do.
      for lane <- PublisherLane.lanes() do
        transport = spawn(fn -> Process.sleep(:infinity) end)
        on_exit(fn -> Process.exit(transport, :kill) end)
        {:ok, _gen} = PublisherPool.register_transport(PublisherPool.via(lane), transport)
      end

      :ok
    end

    test "one live pool per lane, each reporting its own lane and connection" do
      for lane <- PublisherLane.lanes() do
        pid = Process.whereis(PublisherPool.via(lane))
        assert is_pid(pid), "no pool registered for #{inspect(lane)}"

        capacity = PublisherPool.capacity(pid)
        assert capacity.class === lane
        assert capacity.connection === PublisherLane.connection_name(lane)
      end
    end

    test "each pool holds its OWN credits, unshared" do
      bulk = PublisherPool.via(:bulk)
      recovery = PublisherPool.via(:recovery)

      # Each compared against ITS OWN earlier value: comparing bulk's capacity to recovery's would
      # differ on the `class` key whatever the credits did, and would pass even if they shared a
      # window.
      bulk_before = PublisherPool.capacity(bulk)
      recovery_before = PublisherPool.capacity(recovery)

      assert {:ok, _res} = PublisherPool.admit(bulk, k(1), 10, 1_000)

      assert PublisherPool.capacity(recovery) === recovery_before
      refute PublisherPool.capacity(bulk) === bulk_before
    end
  end
end
