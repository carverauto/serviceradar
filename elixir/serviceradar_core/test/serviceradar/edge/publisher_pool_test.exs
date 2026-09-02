defmodule ServiceRadar.Edge.PublisherPoolTest do
  @moduledoc """
  The property that matters is ISOLATION: exhausting one class must not affect another, in either
  direction. Most of these tests start two pools and check the second is untouched.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.PublisherPool

  defp pool(class, frames \\ 2, bytes \\ 600) do
    {:ok, pid} =
      PublisherPool.start_link(
        class: class,
        frame_credits: frames,
        byte_credits: bytes,
        # Unnamed, so tests run concurrently without colliding on the registered name.
        name: nil
      )

    pid
  end

  describe "capacity is per class and unborrowable" do
    test "exhausting BULK leaves interactive and recovery untouched" do
      bulk = pool(:bulk, 1, 300)
      interactive = pool(:interactive, 1, 300)
      recovery = pool(:recovery, 1, 300)

      assert :ok = PublisherPool.admit(bulk, 1, 300, 500)
      assert {:error, :frame_credits_exhausted} = PublisherPool.admit(bulk, 2, 1, 500)

      # THE POINT: a bulk backlog must not consume the reserve of another class.
      assert %{available_frames: 1, available_bytes: 300} = PublisherPool.capacity(interactive)
      assert %{available_frames: 1, available_bytes: 300} = PublisherPool.capacity(recovery)

      assert :ok = PublisherPool.admit(interactive, 1, 300, 500)
      assert :ok = PublisherPool.admit(recovery, 1, 300, 500)
    end

    test "exhausting RECOVERY does not consume the interactive reserve either" do
      # Borrowing is wrong in BOTH directions: recovery is unborrowable BY others, and must not
      # silently draw on others in turn.
      # TWO frames but only 300 bytes, so the BYTE ceiling is the binding one -- with one frame
      # the frame check fires first and the byte path is never reached.
      recovery = pool(:recovery, 2, 300)
      interactive = pool(:interactive, 1, 300)

      assert :ok = PublisherPool.admit(recovery, 1, 300, 500)
      assert {:error, :byte_credits_exhausted} = PublisherPool.admit(recovery, 2, 300, 500)

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

      assert :ok = PublisherPool.admit(p, 1, 200, 500)
      before = PublisherPool.capacity(p)

      assert {:error, :byte_credits_exhausted} = PublisherPool.admit(p, 2, 400, 500)
      assert {:error, :already_outstanding} = PublisherPool.admit(p, 1, 10, 500)
      assert {:error, :not_outstanding} = PublisherPool.settle(p, 99, :primary_publication)
      assert {:error, :unknown_outcome} = PublisherPool.settle(p, 1, :nonsense)
      assert {:error, :not_settled} = PublisherPool.settle(p, 1, :retryable_rejection)
      assert {:error, :not_outstanding} = PublisherPool.rearm(p, 99, 900)

      assert PublisherPool.capacity(p) === before,
             "a rejected call changed the pool's state"

      # NOT VACUOUS: an accepted call DOES change it, so the comparison can fail.
      assert :ok = PublisherPool.settle(p, 1, :primary_publication)
      refute PublisherPool.capacity(p) === before
    end

    test "the pool survives every rejection -- none of them crashes it" do
      p = pool(:bulk, 1, 100)

      for call <- [
            fn -> PublisherPool.admit(p, 0, 1, 500) end,
            fn -> PublisherPool.admit(p, 1, -1, 500) end,
            fn -> PublisherPool.admit(p, 1, 1, nil) end,
            fn -> PublisherPool.settle(p, 1, nil) end,
            fn -> PublisherPool.rearm(p, 1, nil) end
          ] do
        assert {:error, _} = call.()
        assert Process.alive?(p)
      end

      # ...and it still works afterwards.
      assert :ok = PublisherPool.admit(p, 1, 100, 500)
    end
  end

  describe "the window semantics carry through the process boundary" do
    test "expiry reports without releasing, and rearm moves the deadline only" do
      p = pool(:bulk, 1, 300)

      assert :ok = PublisherPool.admit(p, 1, 300, 100)
      assert PublisherPool.expired(p, 500) === [1]

      # Still full: expiry released nothing.
      assert %{available_frames: 0, available_bytes: 0} = PublisherPool.capacity(p)
      assert {:error, :frame_credits_exhausted} = PublisherPool.admit(p, 2, 1, 500)

      assert :ok = PublisherPool.rearm(p, 1, 900)
      assert PublisherPool.expired(p, 500) === []
      assert %{available_frames: 0, available_bytes: 0} = PublisherPool.capacity(p)

      assert :ok = PublisherPool.settle(p, 1, :primary_publication)
      assert %{available_frames: 1, available_bytes: 300} = PublisherPool.capacity(p)
    end
  end
end
