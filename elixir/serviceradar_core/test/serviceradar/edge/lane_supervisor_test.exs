defmodule ServiceRadar.Edge.LaneSupervisorTest do
  @moduledoc """
  The lane's accounting must OUTLIVE its transport, and its transport must not outlive the loss of
  accounting.

  Both halves were wrong before, in opposite ways. As `:one_for_one` siblings a pool could restart
  alone with an empty window, handing out the whole grant again while its in-flight requests
  survived on the untouched connection. `:one_for_all` narrowed that by restarting both, but it
  also emptied the ledger on every transport blip -- and a supervisor restart is ordered, not
  instantaneous, so a request could still complete inside the interval.

  `:rest_for_one` with the ACCOUNTANT FIRST gives the asymmetry the invariant actually needs.

  `async: false`: the accountant registers a global name.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.LaneSupervisor
  alias ServiceRadar.Edge.LaneTransportRuntime
  alias ServiceRadar.Edge.PublisherPool
  alias ServiceRadar.Edge.PublishWindow

  # A port nothing is listening on: Gnat retries in the background with a long backoff, which is
  # irrelevant here -- these assert supervision structure and accounting lifetime, not
  # connectivity.
  defp opts(lane, extra \\ []) do
    [
      lane: lane,
      connection_settings: %{host: "127.0.0.1", port: 14_222},
      backoff_period: 3_600_000,
      credits: [frame_credits: 1, byte_credits: 100]
    ] ++ extra
  end

  defp k(seq), do: PublishWindow.key(<<0xA1>>, "agent-1", <<0xB2>>, seq, {:record, seq})

  describe "the lane's restart order IS the invariant" do
    test "its strategy is :rest_for_one" do
      {:ok, {flags, _children}} = LaneSupervisor.init(opts(:bulk))

      # :one_for_all would empty the ledger on a transport blip; :one_for_one would let the
      # accountant restart empty beside a live transport. Only :rest_for_one, ordered as below,
      # gives one direction without the other.
      assert flags.strategy === :rest_for_one
    end

    test "the ACCOUNTANT comes first and the transport second" do
      specs = LaneSupervisor.child_specs(opts(:interactive))

      assert Enum.map(specs, & &1.id) === [
               PublisherPool.via(:interactive),
               LaneTransportRuntime.via(:interactive)
             ]

      # NOT VACUOUS: a different lane yields different ids, so this cannot pass by hard-coding.
      other = LaneSupervisor.child_specs(opts(:recovery))

      assert Enum.map(other, & &1.id) === [
               PublisherPool.via(:recovery),
               LaneTransportRuntime.via(:recovery)
             ]
    end
  end

  describe "a transport restart preserves the ledger" do
    setup do
      {:ok, sup} = LaneSupervisor.start_link(opts(:bulk, name: :lane_sup_under_test))

      on_exit(fn ->
        try do
          Supervisor.stop(sup, :normal)
        catch
          :exit, _ -> :ok
        end
      end)

      %{sup: sup}
    end

    defp transport_pid(sup) do
      sup
      |> Supervisor.which_children()
      |> Enum.find_value(fn {id, pid, _t, _m} ->
        if id === LaneTransportRuntime.via(:bulk), do: pid
      end)
    end

    defp await(fun, tries \\ 300)
    defp await(_fun, 0), do: flunk("condition never held")

    defp await(fun, tries) do
      if fun.(), do: :ok, else: Process.sleep(10) && await(fun, tries - 1)
    end

    test "THE RESTART INVARIANT, at the process level: a replacement transport inherits the " <>
           "remaining capacity, not a fresh grant",
         %{sup: sup} do
      # Grant of ONE frame. This is the decisive case: publication A is admitted and its request
      # goes to the transport; that transport is then replaced. Previously the accounting went
      # with it, so a replacement started with the whole grant and B could publish alongside an A
      # that may already be on the wire.
      accountant = Process.whereis(PublisherPool.via(:bulk))
      transport_before = transport_pid(sup)
      assert is_pid(accountant) and is_pid(transport_before)

      assert {:ok, _res_a} = PublisherPool.admit(accountant, k(1), 50, 60_000)
      assert %{outstanding_frames: 1, available_frames: 0} = PublisherPool.capacity(accountant)

      Process.exit(transport_before, :kill)

      await(fn ->
        pid = transport_pid(sup)
        is_pid(pid) and pid !== transport_before
      end)

      # THE ACCOUNTANT IS THE SAME PROCESS. That is what makes the rest possible.
      assert Process.whereis(PublisherPool.via(:bulk)) === accountant,
             "the transport restart took the ledger with it"

      # And A's charge SURVIVED. Transport death says nothing about whether A's bytes reached the
      # broker, so releasing here would hand back a broker-ambiguous frame.
      await(fn -> match?(%{outstanding_frames: 1}, PublisherPool.capacity(accountant)) end)

      assert %{outstanding_frames: 1, outstanding_bytes: 50, available_frames: 0} =
               PublisherPool.capacity(accountant)

      # So B is REFUSED. It performs no I/O, because it is never admitted.
      assert {:error, :frame_credits_exhausted} =
               PublisherPool.admit(accountant, k(2), 50, 60_000)

      # A may retry on the charge it already holds -- the fence ended its ATTEMPT, not its
      # reservation -- and that retry costs no new credit.
      assert {:ok, retry} = PublisherPool.admit(accountant, k(1), 50, 60_000)
      assert %{outstanding_frames: 1, outstanding_bytes: 50} = PublisherPool.capacity(accountant)

      # Only once A settles does B become admissible.
      assert :ok = PublisherPool.settle(accountant, retry, :primary_publication)
      assert %{outstanding_frames: 0, available_frames: 1} = PublisherPool.capacity(accountant)
      assert {:ok, _b} = PublisherPool.admit(accountant, k(2), 50, 60_000)
    end

    test "the accountant re-opens on the replacement generation", %{sup: sup} do
      # NOT VACUOUS for the test above: fencing clears the accepting generation, so if nothing
      # re-registered, the lane would be closed rather than bounded and the refusal above would
      # be :no_transport for the wrong reason.
      accountant = Process.whereis(PublisherPool.via(:bulk))
      before = PublisherPool.generations(accountant)
      transport_before = transport_pid(sup)

      Process.exit(transport_before, :kill)
      await(fn -> transport_pid(sup) !== transport_before end)

      await(fn ->
        PublisherPool.generations(accountant).accepting not in [nil, before.accepting]
      end)

      after_restart = PublisherPool.generations(accountant)
      assert is_reference(after_restart.accepting)
      refute after_restart.accepting === before.accepting

      # The spec bounds this metadata: at most one accepting and one draining generation.
      assert length(after_restart.known) <= 2
    end

    test "FAIL CLOSED: losing the accountant tears the transport down with it", %{sup: sup} do
      # The other direction, and the reason the order is what it is. A fresh accountant has an
      # EMPTY ledger; an empty ledger beside live send capability is the over-admission defect
      # wearing a different hat. Under :rest_for_one the transport is terminated first.
      accountant_before = Process.whereis(PublisherPool.via(:bulk))
      transport_before = transport_pid(sup)

      Process.exit(accountant_before, :kill)

      await(fn ->
        pid = Process.whereis(PublisherPool.via(:bulk))
        is_pid(pid) and pid !== accountant_before
      end)

      await(fn ->
        pid = transport_pid(sup)
        is_pid(pid) and pid !== transport_before
      end)

      # The send capability that existed alongside the old ledger is GONE, not merely idle.
      refute Process.alive?(transport_before),
             "a fresh empty ledger coexisted with the previous generation's transport"
    end
  end
end
