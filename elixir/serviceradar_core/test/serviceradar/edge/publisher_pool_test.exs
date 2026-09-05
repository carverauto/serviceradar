defmodule ServiceRadar.Edge.PublisherPoolTest do
  @moduledoc """
  The property that matters is ISOLATION: exhausting one class must not affect another, in either
  direction. Most of these tests start two pools and check the second is untouched.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.PublisherPool

  # Reservations key on the COMPLETE authenticated slot, never the bare sequence: one pool serves
  # every agent and spool in its class. `fp/1` fingerprints the publication, so the same sequence
  # is the same record retrying.
  defp k(seq),
    do: ServiceRadar.Edge.PublishWindow.key(<<0xA1>>, "agent-1", <<0xB2>>, seq, fp(seq))

  defp fp(seq), do: {:record, seq}

  # A well-formed reservation for a publication that is NOT outstanding.
  defp absent(seq), do: {k(seq), 1}

  defp pool(class, frames \\ 2, bytes \\ 600) do
    {:ok, pid} =
      PublisherPool.start_link(
        class: class,
        frame_credits: frames,
        byte_credits: bytes,
        # Unnamed, so tests run concurrently without colliding on the registered name.
        name: nil
      )

    # A lane is CLOSED until a transport registers, so every pool a test uses needs one. The
    # stand-in is a bare process: what the accountant binds to is its LIFETIME, not anything it
    # can do -- generation death is the signal, and a real Gnat connection is not needed to
    # produce it.
    transport = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(transport, :kill) end)
    {:ok, _generation} = PublisherPool.register_transport(pid, transport)

    pid
  end

  describe "capacity is per class and unborrowable" do
    test "exhausting BULK leaves interactive and recovery untouched" do
      bulk = pool(:bulk, 1, 300)
      interactive = pool(:interactive, 1, 300)
      recovery = pool(:recovery, 1, 300)

      assert {:ok, _res} = PublisherPool.admit(bulk, k(1), 300, 500)
      assert {:error, :frame_credits_exhausted} = PublisherPool.admit(bulk, k(2), 1, 500)

      # THE POINT: a bulk backlog must not consume the reserve of another class.
      assert %{available_frames: 1, available_bytes: 300} = PublisherPool.capacity(interactive)
      assert %{available_frames: 1, available_bytes: 300} = PublisherPool.capacity(recovery)

      assert {:ok, _res} = PublisherPool.admit(interactive, k(1), 300, 500)
      assert {:ok, _res} = PublisherPool.admit(recovery, k(1), 300, 500)
    end

    test "exhausting RECOVERY does not consume the interactive reserve either" do
      # Borrowing is wrong in BOTH directions: recovery is unborrowable BY others, and must not
      # silently draw on others in turn.
      # TWO frames but only 300 bytes, so the BYTE ceiling is the binding one -- with one frame
      # the frame check fires first and the byte path is never reached.
      recovery = pool(:recovery, 2, 300)
      interactive = pool(:interactive, 1, 300)

      assert {:ok, _res} = PublisherPool.admit(recovery, k(1), 300, 500)

      assert {:error, :byte_credits_exhausted} =
               PublisherPool.admit(recovery, k(2), 300, 500)

      assert %{outstanding_frames: 0, available_bytes: 300} = PublisherPool.capacity(interactive)
    end

    test "two pools never publish on the same NATS connection" do
      # Separate accounting over ONE socket is not separate capacity: both lanes would queue in
      # the same Gnat mailbox, so a saturated lane could stall another whose credits were free.
      # Invisible from the window numbers, which is why it is asserted on the reported connection.
      connections =
        for class <- PublisherPool.classes() do
          %{connection: connection} = PublisherPool.capacity(pool(class))
          connection
        end

      assert length(Enum.uniq(connections)) === length(connections)

      # NOT VACUOUS: each pool reports the connection its own lane owns, not just some unique
      # value -- a per-pool counter would also pass a pure uniqueness check.
      for class <- PublisherPool.classes() do
        %{connection: connection} = PublisherPool.capacity(pool(class))
        assert connection === ServiceRadar.Edge.PublisherLane.connection_name(class)
      end
    end

    test "there is no cross-class API to borrow through" do
      # Structural: a pool holds one window and has no reference to another, so borrowing is
      # unrepresentable rather than merely unimplemented.
      {:module, _} = Code.ensure_loaded(PublisherPool)

      exported = :functions |> PublisherPool.__info__() |> Enum.map(&elem(&1, 0))

      for name <- exported do
        n = Atom.to_string(name)

        refute String.contains?(n, "borrow") or String.contains?(n, "steal") or
                 String.contains?(n, "transfer"),
               "#{name} looks like a cross-class capacity path"
      end

      # Every entry point takes ONE pool. None accepts a second pool to draw from.
      assert PublisherPool.__info__(:functions)[:admit] === 4
      assert PublisherPool.__info__(:functions)[:settle] === 3
    end
  end

  describe "a pool is keyed on CLASS, never on scope" do
    test "only the three classes exist, and a SCOPE-SHAPED key is refused" do
      assert PublisherPool.classes() === [:bulk, :interactive, :recovery]

      # A mutation that accepted `{:scoped, _}` as a class survived the earlier version of this
      # test: asserting that classes/0 returns three atoms says nothing about what start_link
      # ACCEPTS, and a single bad-atom case does not cover composite keys. Each of these is a way
      # of smuggling a per-scope, per-agent or per-partition pool past the class key.
      for bad <- [
            :per_agent,
            {:scoped, "scope-a"},
            {:bulk, "agent-1"},
            {:bulk, 7},
            [:bulk, "scope-a"],
            "bulk",
            %{class: :bulk, scope: "s"},
            nil
          ] do
        assert_raise ArgumentError, fn ->
          PublisherPool.start_link(class: bad, frame_credits: 1, byte_credits: 1, name: nil)
        end
      end

      # NOT VACUOUS: each real class still starts.
      for good <- PublisherPool.classes() do
        assert {:ok, _} =
                 PublisherPool.start_link(
                   class: good,
                   frame_credits: 1,
                   byte_credits: 1,
                   name: nil
                 )
      end
    end

    test "start_link accepts nothing that could key a pool to a scope" do
      # The spec forbids a connection/process per network scope, agent, assignment, run, contract,
      # package or partition. A per-scope pool must be UNREPRESENTABLE, not discouraged: these
      # options are ignored, so no caller can create one by passing them.
      {:ok, pid} =
        PublisherPool.start_link(
          class: :bulk,
          frame_credits: 1,
          byte_credits: 100,
          name: nil,
          network_scope_id: "scope-a",
          agent_id: "agent-1",
          partition: 7
        )

      assert %{class: :bulk} = PublisherPool.capacity(pid)
    end
  end

  describe "a rejected call leaves process state unchanged" do
    test "the refusal does not disturb capacity -- observable now that state outlives the call" do
      # In parts 1 and 2 this was guaranteed by immutability and untestable: an {:error, _} return
      # exposed no replacement term. Here the state lives in a process and survives the call, so a
      # rejection that corrupted it would be visible.
      p = pool(:bulk, 2, 500)

      assert {:ok, res} = PublisherPool.admit(p, k(1), 200, 500)
      before = PublisherPool.capacity(p)

      assert {:error, :byte_credits_exhausted} = PublisherPool.admit(p, k(2), 400, 500)

      assert {:error, :not_outstanding} =
               PublisherPool.settle(p, absent(99), :primary_publication)

      assert {:error, :unknown_outcome} = PublisherPool.settle(p, res, :nonsense)
      assert {:error, :not_settled} = PublisherPool.settle(p, res, :retryable_rejection)
      assert {:error, :not_outstanding} = PublisherPool.rearm(p, absent(99), 900)

      assert PublisherPool.capacity(p) === before,
             "a rejected call changed the pool's state"

      # NOT VACUOUS: an accepted call DOES change it, so the comparison can fail.
      assert :ok = PublisherPool.settle(p, res, :primary_publication)
      refute PublisherPool.capacity(p) === before
    end

    test "the pool survives every rejection -- none of them crashes it" do
      p = pool(:bulk, 1, 100)

      for call <- [
            fn -> PublisherPool.admit(p, k(0), 1, 500) end,
            fn -> PublisherPool.admit(p, k(1), -1, 500) end,
            fn -> PublisherPool.admit(p, k(1), 1, nil) end,
            fn -> PublisherPool.settle(p, absent(1), nil) end,
            fn -> PublisherPool.rearm(p, absent(1), nil) end,
            # A caller-supplied clock is gone, so a malformed one is a refusal rather than a crash
            # that would take the whole lane down with the pool under :one_for_all.
            fn -> PublisherPool.rearm(p, absent(1), :not_a_timeout) end
          ] do
        assert {:error, _} = call.()
        assert Process.alive?(p)
      end

      # ...and it still works afterwards.
      assert {:ok, _res} = PublisherPool.admit(p, k(1), 100, 500)
    end
  end

  describe "the window semantics carry through the process boundary" do
    test "expiry reports without releasing, and rearm moves the deadline only" do
      p = pool(:bulk, 1, 300)

      # A ZERO timeout, so the reservation is already past its deadline when we ask. The POOL owns
      # the clock now -- the same one that stamped the deadline -- so there is no `now` to pass and
      # no malformed `now` that could crash it.
      assert {:ok, res} = PublisherPool.admit(p, k(1), 300, 0)
      assert PublisherPool.expired(p) === [res]

      # Still full: expiry released nothing.
      assert %{available_frames: 0, available_bytes: 0} = PublisherPool.capacity(p)
      assert {:error, :frame_credits_exhausted} = PublisherPool.admit(p, k(2), 1, 500)

      assert :ok = PublisherPool.rearm(p, res, 60_000)
      assert PublisherPool.expired(p) === []
      assert %{available_frames: 0, available_bytes: 0} = PublisherPool.capacity(p)

      assert :ok = PublisherPool.settle(p, res, :primary_publication)
      assert %{available_frames: 1, available_bytes: 300} = PublisherPool.capacity(p)
    end

    test "a stale reservation cannot settle or re-arm what reused its key" do
      p = pool(:bulk, 1, 300)

      assert {:ok, stale} = PublisherPool.admit(p, k(1), 300, 0)
      assert :ok = PublisherPool.settle(p, stale, :primary_publication)

      # The same publication is admitted again: same key, new epoch.
      assert {:ok, fresh} = PublisherPool.admit(p, k(1), 300, 60_000)
      refute fresh === stale

      assert {:error, :not_outstanding} = PublisherPool.settle(p, stale, :primary_publication)
      assert {:error, :not_outstanding} = PublisherPool.rearm(p, stale, 1)

      # NOT VACUOUS: the current reservation is untouched and still settles.
      assert %{outstanding_frames: 1} = PublisherPool.capacity(p)
      assert :ok = PublisherPool.settle(p, fresh, :primary_publication)
    end
  end

  describe "caller death alone authorises nothing" do
    test "a caller that dies AFTER taking delivery leaves its credits charged" do
      # Deliberate, and the conservative direction. By the time a caller holds its reservation a
      # request may already be on the socket; releasing then would permit a second publish while
      # the first is still broker-ambiguous. A lane restart is what clears these.
      #
      # The pre-handoff case -- a caller that dies before it ever receives the reservation -- is a
      # different question and is covered in PublisherPoolHandoffTest.
      p = pool(:bulk, 1, 100)
      test_pid = self()

      caller =
        spawn(fn ->
          send(test_pid, {:admitted, PublisherPool.admit(p, k(1), 50, 60_000)})
          receive do: (:never -> :ok)
        end)

      assert_receive {:admitted, {:ok, _res}}
      ref = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^ref, :process, ^caller, _}

      Process.sleep(50)
      assert %{outstanding_frames: 1, outstanding_bytes: 50} = PublisherPool.capacity(p)
    end

    test "an unrecognised :DOWN cannot release anything" do
      # The pool only ever acts on a monitor reference it issued for a PENDING admission. An
      # earlier version matched on the pid alone and released that owner's reservations for any
      # :DOWN naming it.
      p = pool(:bulk, 1, 100)
      assert {:ok, _} = PublisherPool.admit(p, k(1), 50, 60_000)

      send(p, {:DOWN, make_ref(), :process, self(), :normal})
      Process.sleep(50)

      assert %{outstanding_frames: 1} = PublisherPool.capacity(p)
    end
  end

  describe "attempts, not just reservations" do
    test "a concurrent retry is refused while the first attempt is live" do
      p = pool(:bulk, 2, 200)
      assert {:ok, _first} = PublisherPool.admit(p, k(1), 50, 60_000)

      # Two requests under one charge is the bound violation this closes.
      assert {:error, :attempt_in_flight} = PublisherPool.admit(p, k(1), 50, 60_000)
    end

    test "ending the attempt keeps the credits but allows the retry" do
      p = pool(:bulk, 1, 100)
      assert {:ok, first} = PublisherPool.admit(p, k(1), 50, 0)
      assert :ok = PublisherPool.attempt_failed(p, first)

      # Still charged: the record is owed a republish.
      assert %{outstanding_frames: 1, outstanding_bytes: 50} = PublisherPool.capacity(p)

      assert {:ok, retry} = PublisherPool.admit(p, k(1), 50, 60_000)
      refute retry === first
      assert %{outstanding_frames: 1, outstanding_bytes: 50} = PublisherPool.capacity(p)

      assert {:error, :not_outstanding} = PublisherPool.attempt_failed(p, first)
      assert :ok = PublisherPool.settle(p, retry, :primary_publication)
    end
  end

  defp eventually(fun, tries \\ 200)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, tries - 1)
    end
  end

  describe "an accountant with no live transport is CLOSED" do
    # These deliberately do NOT use pool/3, which registers a transport for you. The closed state
    # is what pool/3 hides, and mutation testing is how that gap surfaced: the fail-closed guard
    # could be deleted outright and every other test in this suite still passed.
    defp bare_pool(frames \\ 2, bytes \\ 600) do
      {:ok, pid} =
        PublisherPool.start_link(
          class: :bulk,
          frame_credits: frames,
          byte_credits: bytes,
          name: nil
        )

      pid
    end

    defp live_transport(pool) do
      transport = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(transport, :kill) end)
      {:ok, generation} = PublisherPool.register_transport(pool, transport)
      {transport, generation}
    end

    test "a FRESH accountant admits nothing until a transport registers" do
      # The fail-closed half of the restart contract. A replaced accountant has an EMPTY ledger,
      # and an empty ledger that accepts admissions is the over-admission defect wearing a
      # different hat -- so it must refuse until send capability exists again.
      p = bare_pool()

      assert {:error, :no_transport} = PublisherPool.admit(p, k(1), 50, 60_000)
      assert %{outstanding_frames: 0, outstanding_bytes: 0} = PublisherPool.capacity(p)

      # NOT VACUOUS: the identical call succeeds once a transport registers, so the refusal is
      # about the missing generation and not about the request.
      {_transport, _gen} = live_transport(p)
      assert {:ok, _res} = PublisherPool.admit(p, k(1), 50, 60_000)
    end

    test "a refusal for want of transport charges NOTHING" do
      # A refusal that consumed a credit would be worse than admitting: the lane would bleed
      # capacity every time it was closed, and never get it back.
      p = bare_pool(1, 100)
      before = PublisherPool.capacity(p)

      assert {:error, :no_transport} = PublisherPool.admit(p, k(1), 50, 60_000)
      assert {:error, :no_transport} = PublisherPool.admit(p, k(2), 50, 60_000)

      assert PublisherPool.capacity(p) === before
    end

    test "when its transport DIES the accountant closes again" do
      # The generation is gone, so there is nothing to publish on. Continuing to admit would
      # charge credits against transport that cannot carry them -- and would do it while the
      # replacement generation has not registered, so nothing could report the outcome either.
      p = bare_pool(2, 600)
      {transport, generation} = live_transport(p)

      assert {:ok, _res} = PublisherPool.admit(p, k(1), 50, 60_000)
      assert PublisherPool.generations(p).accepting === generation

      Process.exit(transport, :kill)

      assert eventually(fn -> PublisherPool.generations(p).accepting === nil end, 300),
             "the accountant kept accepting on a dead generation"

      assert {:error, :no_transport} = PublisherPool.admit(p, k(2), 50, 60_000)

      # AND the charge from before the death survived: generation death ends the ATTEMPT, never
      # the reservation, because it is no evidence about whether the bytes reached the broker.
      assert %{outstanding_frames: 1, outstanding_bytes: 50} = PublisherPool.capacity(p)
    end

    test "a REPLACEMENT transport re-opens it, on the remaining capacity" do
      p = bare_pool(2, 600)
      {transport, first_gen} = live_transport(p)

      assert {:ok, _res} = PublisherPool.admit(p, k(1), 50, 60_000)
      Process.exit(transport, :kill)
      assert eventually(fn -> PublisherPool.generations(p).accepting === nil end, 300)

      {_replacement, second_gen} = live_transport(p)
      refute second_gen === first_gen

      # Open again -- but with ONE frame, not two: the fenced reservation is still charged.
      assert %{outstanding_frames: 1, available_frames: 1} = PublisherPool.capacity(p)
      assert {:ok, _res2} = PublisherPool.admit(p, k(2), 50, 60_000)
      assert {:error, :frame_credits_exhausted} = PublisherPool.admit(p, k(3), 50, 60_000)
    end
  end

  describe "registration is a bounded transition" do
    # A transport that stays alive, so a generation registered against it does NOT drain. That is
    # what makes the bound observable at all: the reaping step retires dead generations, so an
    # over-count can only be produced by registrars that are genuinely still running.
    defp held_transport do
      transport = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(transport, :kill) end)
      transport
    end

    defp open_pool do
      {:ok, pid} =
        PublisherPool.start_link(class: :bulk, frame_credits: 4, byte_credits: 900, name: nil)

      pid
    end

    test "a THIRD live generation is refused, not absorbed" do
      # The spec bounds retention at one accepting and one draining generation. Absorbing a third
      # would grow `transports` without limit on a lane whose registrars stop dying, and each
      # entry carries a monitor -- so the leak is of VM resources as well as of accuracy.
      p = open_pool()

      assert {:ok, first} = PublisherPool.register_transport(p, held_transport())
      assert {:ok, second} = PublisherPool.register_transport(p, held_transport())
      refute second === first

      assert {:error, :generation_limit} = PublisherPool.register_transport(p, held_transport())

      # AND the refusal did not disturb the lane: the newest generation is still accepting, both
      # known generations are still known, and admissions still work.
      assert %{accepting: ^second, known: known} = PublisherPool.generations(p)
      assert length(known) == 2
      assert {:ok, _res} = PublisherPool.admit(p, k(1), 50, 60_000)
    end

    test "an ALREADY-DEAD registrar is refused, and does not displace a live generation" do
      # THE WEDGE this closes. Accepting it made the dead generation `accepting`; the :DOWN
      # already in flight for it then set `accepting` to nil, while the live generation stayed in
      # `transports` with no registrar that would ever register again. The lane was closed for the
      # life of the pool, holding send capability it refused to use.
      p = open_pool()
      assert {:ok, live} = PublisherPool.register_transport(p, held_transport())

      corpse = spawn(fn -> :ok end)
      assert eventually(fn -> not Process.alive?(corpse) end, 300)

      assert {:error, :dead_registrar} = PublisherPool.register_transport(p, corpse)

      # The live generation is untouched, and STAYS untouched: nothing arrives later to close it.
      assert %{accepting: ^live} = PublisherPool.generations(p)

      refute eventually(fn -> PublisherPool.generations(p).accepting !== live end, 20),
             "a refused dead registrar still closed the lane"

      assert {:ok, _res} = PublisherPool.admit(p, k(1), 50, 60_000)
    end

    test "registering the SAME process twice returns one generation, not two" do
      # A second reference for one lifetime would consume the bound with a generation no death can
      # clear: only one :DOWN ever arrives for that process.
      p = open_pool()
      transport = held_transport()

      assert {:ok, generation} = PublisherPool.register_transport(p, transport)
      assert {:ok, ^generation} = PublisherPool.register_transport(p, transport)

      assert %{accepting: ^generation, known: [^generation]} = PublisherPool.generations(p)
    end

    test "when the ACCEPTING generation dies the lane falls back to one that is still live" do
      # The other shape of the wedge. Closing outright on any fence was wrong whenever another
      # generation remained: that registrar has already registered -- registration happens once,
      # from init/1 -- so nothing would ever re-open the lane, and it would sit closed beside send
      # capability it refused to use.
      p = open_pool()
      older = held_transport()
      newer = held_transport()

      assert {:ok, older_gen} = PublisherPool.register_transport(p, older)
      assert {:ok, newer_gen} = PublisherPool.register_transport(p, newer)
      assert %{accepting: ^newer_gen} = PublisherPool.generations(p)

      # Kill the ACCEPTING one, leaving the older one alive.
      Process.exit(newer, :kill)

      assert eventually(fn -> PublisherPool.generations(p).accepting === older_gen end, 300),
             "the lane closed instead of falling back to the generation still alive"

      assert Process.alive?(older)
      assert {:ok, _res} = PublisherPool.admit(p, k(1), 50, 60_000)
    end

    test "a DEAD generation is reaped to make room, and its charge survives the reaping" do
      # Reaping is why the bound is never tripped by an undelivered :DOWN. It must do exactly what
      # the :DOWN does -- end the attempts, KEEP the reservations -- or a lane could recover its
      # grant simply by restarting its transport twice quickly.
      p = open_pool()
      first = held_transport()
      assert {:ok, _gen} = PublisherPool.register_transport(p, first)
      assert {:ok, _res} = PublisherPool.admit(p, k(1), 50, 60_000)

      second = held_transport()
      assert {:ok, _gen2} = PublisherPool.register_transport(p, second)

      # Kill BOTH, then register a third WITHOUT waiting for either :DOWN. Two dead generations
      # are already at the bound, so this only succeeds if registration reaps them itself.
      Process.exit(first, :kill)
      Process.exit(second, :kill)
      assert eventually(fn -> not Process.alive?(first) and not Process.alive?(second) end, 300)

      assert {:ok, third} = PublisherPool.register_transport(p, held_transport())
      assert %{accepting: ^third, known: [^third]} = PublisherPool.generations(p)

      # The charge taken under the FIRST generation is still held: reaping fenced its attempt and
      # kept its reservation, exactly as a :DOWN would.
      assert %{outstanding_frames: 1, outstanding_bytes: 50} = PublisherPool.capacity(p)
    end
  end
end
