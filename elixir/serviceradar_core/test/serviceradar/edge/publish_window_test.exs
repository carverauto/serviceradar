defmodule ServiceRadar.Edge.PublishWindowTest do
  @moduledoc """
  The dangerous properties are the ones where the window hands out more budget than it holds, or
  hands the same budget out twice. Most of these tests are about refusing to admit.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.PublishWindow

  defp window(frames \\ 4, bytes \\ 1000) do
    {:ok, w} = PublishWindow.new(frames, bytes)
    w
  end

  @primary :primary_publication
  @retryable :retryable_rejection

  # The outstanding set, without reaching through the opaque struct in every test.
  defp outstanding_seqs(w) do
    1..60
    |> Map.new(fn s -> {s, PublishWindow.outstanding?(w, s)} end)
    |> Enum.filter(fn {_s, out} -> out end)
    |> Map.new()
  end

  defp admit!(w, seq, bytes, deadline) do
    {:ok, w} = PublishWindow.admit(w, seq, bytes, deadline)
    w
  end

  describe "the grant is the bound" do
    test "credits come from the lane-open ack, and zero admits nothing" do
      # Zero is NOT legal -- 1.7-e's `1 <= granted` makes it a refusal. It reaches here because
      # nothing on this side validates a lane ack, and a window handed zero simply has no capacity.
      {:ok, none} = PublishWindow.new(0, 0)

      assert PublishWindow.available_frames(none) === 0
      refute PublishWindow.admits?(none, 0)
      assert {:error, :frame_credits_exhausted} = PublishWindow.admit(none, 1, 0, 100)
    end

    test "grant LEGALITY is not decided here; only type preconditions are" do
      # An earlier version refused grants above uint32/uint64 maxima and called a zero grant "a
      # real answer". Both froze semantics task 1.7-e owns and has not stated: the caps are
      # separate normative values, and 1.7-e's return relation `1 <= granted <= requested` makes
      # zero a REFUSAL. nothing on this side adjudicates; this module accounts.
      assert {:ok, _} = PublishWindow.new(0xFFFFFFFF + 1, 10)
      assert {:ok, _} = PublishWindow.new(1, 0xFFFFFFFFFFFFFFFF + 1)

      # A zero grant is accepted and simply has no capacity -- safe behaviour for a value that
      # should never have reached here, NOT a claim that zero is legal.
      {:ok, none} = PublishWindow.new(0, 0)
      refute PublishWindow.admits?(none, 0)

      # Type preconditions remain: these are programming errors, not wire judgements.
      assert {:error, :frame_credits} = PublishWindow.new(-1, 10)
      assert {:error, :byte_credits} = PublishWindow.new(1, -1)
      assert {:error, :frame_credits} = PublishWindow.new(nil, 10)
    end
  end

  describe "publishing is pipelined, but bounded" do
    test "several frames are outstanding at once" do
      w = window() |> admit!(1, 100, 500) |> admit!(2, 100, 500) |> admit!(3, 100, 500)

      # THE POINT of part 2: not one-in-flight-at-a-time.
      assert PublishWindow.outstanding_frames(w) === 3
      assert PublishWindow.outstanding_bytes(w) === 300
    end

    test "the FRAME grant is hard" do
      w = Enum.reduce(1..4, window(4, 100_000), &admit!(&2, &1, 1, 500))

      assert PublishWindow.available_frames(w) === 0
      refute PublishWindow.admits?(w, 1)

      assert {:error, :frame_credits_exhausted} = PublishWindow.admit(w, 5, 1, 500)

      # Settling one makes room for exactly one.
      {:ok, w} = PublishWindow.settle(w, 1, @primary)
      assert {:ok, w} = PublishWindow.admit(w, 5, 1, 500)
      assert {:error, :frame_credits_exhausted} = PublishWindow.admit(w, 6, 1, 500)
    end

    # NAMED for what it does: `bytes` is SUPPLIED by the caller and accounted as given. Nothing
    # binds it to the encoded frame size -- task 3.4 owns that, with the remaining 3.3(c)
    # integration -- so calling it "actual size" claimed a binding this module does not have.
    test "the BYTE grant is hard against the SUPPLIED byte count" do
      w = 100 |> window(1000) |> admit!(1, 600, 500)

      assert PublishWindow.available_bytes(w) === 400
      assert PublishWindow.admits?(w, 400)
      refute PublishWindow.admits?(w, 401)

      assert {:error, :byte_credits_exhausted} = PublishWindow.admit(w, 2, 401, 500)
      assert {:ok, w} = PublishWindow.admit(w, 2, 400, 500)
      assert PublishWindow.available_bytes(w) === 0
    end

    test "a frame is admitted once; a second admit of the same slot is refused" do
      # A retry republishes the SAME slot, which is already outstanding and still charged.
      # Admitting it again would double-charge and double-count.
      w = admit!(window(), 1, 100, 500)

      assert {:error, :already_outstanding} = PublishWindow.admit(w, 1, 100, 500)
      assert {:error, :already_outstanding} = PublishWindow.admit(w, 1, 999, 900)

      assert PublishWindow.outstanding_frames(w) === 1
      assert PublishWindow.outstanding_bytes(w) === 100
    end

    test "malformed inputs are refused" do
      w = window()

      assert {:error, :sequence} = PublishWindow.admit(w, 0, 1, 500)
      assert {:error, :sequence} = PublishWindow.admit(w, -1, 1, 500)
      assert {:error, :sequence} = PublishWindow.admit(w, 0xFFFFFFFFFFFFFFFF + 1, 1, 500)
      assert {:error, :bytes} = PublishWindow.admit(w, 1, -1, 500)
      assert {:error, :deadline} = PublishWindow.admit(w, 1, 1, nil)
    end
  end

  describe "a deadline REPORTS; only settling releases" do
    test "an expired frame stays outstanding and stays charged" do
      # THE TRAP. If expiry released credits, the window would hand the same budget out twice --
      # the publisher republishes the same bytes on the same slot, so the frame is still in
      # flight. The bound would relax exactly when the broker is already struggling.
      w = 2 |> window(1000) |> admit!(1, 400, 100) |> admit!(2, 400, 900)

      assert PublishWindow.expired(w, 500) === [1]

      assert PublishWindow.outstanding_frames(w) === 2
      assert PublishWindow.outstanding_bytes(w) === 800
      assert PublishWindow.available_frames(w) === 0

      # Still refused, because nothing was released.
      assert {:error, :frame_credits_exhausted} = PublishWindow.admit(w, 3, 1, 900)
    end

    test "expired/2 CANNOT release: its return type carries no window" do
      # The strongest form of this invariant is structural, not behavioural. `expired/2` returns a
      # list of sequences, so there is no channel through which it could hand back a window with
      # credits released -- a mutation that makes it release is either equivalent (it discards the
      # result) or must change the signature, which breaks every caller.
      #
      # Pinning the shape makes that guarantee deliberate instead of incidental: if someone later
      # widens the return to {list, window}, this fails and the change has to be argued.
      w = admit!(window(), 1, 100, 100)
      result = PublishWindow.expired(w, 999)

      assert is_list(result)
      assert Enum.all?(result, &is_integer/1)
      refute match?({_, %PublishWindow{}}, result)
    end

    # The EXACT exported surface. Not a name filter: matching on "release"/"drop"/"reclaim" is
    # fail-open by spelling, so `free_credits/2` or `settle_expired/2` would pass the very guard
    # meant to catch them. An exact inventory makes ANY new public function fail until someone
    # classifies it -- which is the point, because the question "does this release credits?" has
    # to be answered deliberately rather than inferred from what it was called.
    # MACROS ARE PUBLIC SURFACE TOO, and `__info__(:functions)` omits them entirely -- so a
    # `defmacro release_expired(...)` would add a releasing entry point the function-only
    # inventory could never see. Empty today, and ASSERTED empty rather than assumed.
    @public_macros []

    @public_functions [
      {:__struct__, 0},
      {:__struct__, 1},
      {:admit, 4},
      {:admits?, 2},
      {:available_bytes, 1},
      {:available_frames, 1},
      {:expired, 2},
      {:new, 2},
      {:outstanding?, 2},
      {:outstanding_bytes, 1},
      {:outstanding_frames, 1},
      {:rearm, 3},
      {:settle, 3},
      {:wire_disposition, 1},
      {:internal_outcomes, 0}
    ]

    test "the public surface is EXACTLY the classified inventory, PER KIND" do
      {:module, _} = Code.ensure_loaded(PublishWindow)

      # Compared SEPARATELY, not as one merged set. Merging them lets a kind substitution pass:
      # turning `def settle/3` into `defmacro settle/3` leaves {:settle, 3} present either way,
      # while changing the call semantics to compile-time expansion. The guard exists to make any
      # change of public surface explicit, and the KIND is part of that surface.
      functions = Enum.sort(PublishWindow.__info__(:functions))
      macros = Enum.sort(PublishWindow.__info__(:macros))

      assert functions === Enum.sort(@public_functions),
             "exported FUNCTIONS drifted: added #{inspect(functions -- @public_functions)}, " <>
               "removed #{inspect(@public_functions -- functions)}. " <>
               "settle/3 is the ONLY one that may release credits."

      assert macros === Enum.sort(@public_macros),
             "exported MACROS drifted: added #{inspect(macros -- @public_macros)}, " <>
               "removed #{inspect(@public_macros -- macros)}"
    end

    test "expiry is inclusive of the deadline instant and ordered oldest first" do
      w =
        4
        |> window(1000)
        |> admit!(3, 10, 300)
        |> admit!(1, 10, 100)
        |> admit!(2, 10, 200)

      assert PublishWindow.expired(w, 99) === []
      # Inclusive: a deadline AT `now` has passed.
      assert PublishWindow.expired(w, 100) === [1]
      assert PublishWindow.expired(w, 300) === [1, 2, 3]
    end

    test "settling releases exactly that frame's bytes" do
      w = 4 |> window(1000) |> admit!(1, 250, 500) |> admit!(2, 125, 500)

      {:ok, w} = PublishWindow.settle(w, 1, @primary)

      assert PublishWindow.outstanding_bytes(w) === 125
      assert PublishWindow.available_bytes(w) === 875
      refute PublishWindow.outstanding?(w, 1)
      assert PublishWindow.outstanding?(w, 2)
    end

    test "settling anything not outstanding is refused, not a silent no-op" do
      w = admit!(window(), 1, 100, 500)
      {:ok, settled} = PublishWindow.settle(w, 1, @primary)

      # Never admitted, and already settled, are BOTH :not_outstanding. Telling them apart would
      # require retaining every settled sequence forever, which is the growth this bounds.
      assert {:error, :not_outstanding} = PublishWindow.settle(w, 99, @primary)
      assert {:error, :not_outstanding} = PublishWindow.settle(settled, 1, @primary)
    end
  end

  describe "the deadline boundary is exactly as documented" do
    test "a deadline AT `now` has passed; one strictly after has not" do
      # The contract says `deadline <= now`, so the boundary is promised and therefore pinned.
      # `<` vs `<=` is a one-character change that silently shifts every timeout by one tick.
      w = admit!(window(), 1, 10, 100)

      assert PublishWindow.expired(w, 99) === []
      assert PublishWindow.expired(w, 100) === [1]
      assert PublishWindow.expired(w, 101) === [1]
    end
  end

  describe "settling releases exactly one frame's worth" do
    test "differently sized frames: settling one releases THAT frame's bytes only" do
      # Sizes are deliberately distinct, so releasing the wrong frame's bytes -- or all of them --
      # produces a different number rather than coincidentally the same one.
      w = 4 |> window(1000) |> admit!(1, 100, 500) |> admit!(2, 250, 500) |> admit!(3, 50, 500)

      assert PublishWindow.outstanding_bytes(w) === 400

      {:ok, w} = PublishWindow.settle(w, 2, @primary)

      assert PublishWindow.outstanding_bytes(w) === 150,
             "settling frame 2 did not release exactly its 250 bytes"

      assert PublishWindow.outstanding_frames(w) === 2
      assert PublishWindow.outstanding?(w, 1)
      assert PublishWindow.outstanding?(w, 3)
      refute PublishWindow.outstanding?(w, 2)
    end

    test "a SECOND settlement releases nothing further" do
      w = 4 |> window(1000) |> admit!(1, 300, 500) |> admit!(2, 100, 500)
      {:ok, once} = PublishWindow.settle(w, 1, @primary)

      assert PublishWindow.outstanding_bytes(once) === 100
      assert PublishWindow.available_bytes(once) === 900

      assert {:error, :not_outstanding} = PublishWindow.settle(once, 1, @primary)

      # The evidence that matters is the OBSERVABLE CAPACITY afterwards, not a comparison of an
      # immutable input to itself: a double-release would show up as 600 bytes outstanding or as
      # capacity that grew twice for one frame.
      assert PublishWindow.outstanding_bytes(once) === 100
      assert PublishWindow.available_bytes(once) === 900
      assert PublishWindow.outstanding_frames(once) === 1
    end
  end

  describe "a full window that has entirely expired is still full" do
    test "expiring everything admits nothing; settling one admits exactly one" do
      w = 3 |> window(300) |> admit!(1, 100, 10) |> admit!(2, 100, 20) |> admit!(3, 100, 30)

      # Everything is past its deadline...
      assert PublishWindow.expired(w, 1_000) === [1, 2, 3]

      # ...and the window is still completely full, because expiry released nothing.
      assert PublishWindow.available_frames(w) === 0
      assert PublishWindow.available_bytes(w) === 0
      refute PublishWindow.admits?(w, 1)
      assert {:error, :frame_credits_exhausted} = PublishWindow.admit(w, 4, 100, 1_000)

      # Settling ONE frame admits exactly ONE replacement, not more.
      {:ok, w} = PublishWindow.settle(w, 2, @primary)

      assert PublishWindow.available_frames(w) === 1
      assert PublishWindow.available_bytes(w) === 100
      assert {:ok, w} = PublishWindow.admit(w, 4, 100, 1_000)
      assert {:error, :frame_credits_exhausted} = PublishWindow.admit(w, 5, 1, 1_000)
    end
  end

  describe "an expired frame can be re-armed without releasing credits" do
    test "rearm/3 moves the deadline and charges nothing" do
      # Without this the retry was UNREPRESENTABLE: admit/4 refuses an outstanding slot and
      # settle/3 would release credits for a frame still in flight, so an expired frame could be
      # reported forever and never re-armed.
      w = 2 |> window(1000) |> admit!(1, 400, 100) |> admit!(2, 400, 100)

      assert PublishWindow.expired(w, 500) === [1, 2]

      {:ok, w} = PublishWindow.rearm(w, 1, 900)

      # No longer expired at 500, and nothing about the budget moved.
      assert PublishWindow.expired(w, 500) === [2]
      assert PublishWindow.outstanding_frames(w) === 2
      assert PublishWindow.outstanding_bytes(w) === 800
      assert PublishWindow.available_bytes(w) === 200
      assert PublishWindow.available_frames(w) === 0
    end

    test "re-arming does NOT create capacity, so the bound still holds" do
      w = 1 |> window(100) |> admit!(1, 100, 10)

      {:ok, w} = PublishWindow.rearm(w, 1, 999)

      refute PublishWindow.admits?(w, 1)
      assert {:error, :frame_credits_exhausted} = PublishWindow.admit(w, 2, 0, 999)
    end

    test "re-arming something not outstanding is refused" do
      w = admit!(window(), 1, 100, 500)
      {:ok, settled} = PublishWindow.settle(w, 1, @primary)

      assert {:error, :not_outstanding} = PublishWindow.rearm(w, 99, 900)
      assert {:error, :not_outstanding} = PublishWindow.rearm(settled, 1, 900)
      assert {:error, :deadline} = PublishWindow.rearm(w, 1, nil)
    end

    test "a re-armed frame settles exactly once, releasing its original bytes" do
      w = 2 |> window(1000) |> admit!(1, 375, 100)
      {:ok, w} = PublishWindow.rearm(w, 1, 900)
      {:ok, w} = PublishWindow.settle(w, 1, @primary)

      assert PublishWindow.outstanding_bytes(w) === 0
      assert {:error, :not_outstanding} = PublishWindow.settle(w, 1, @primary)
    end
  end

  describe "admits?/2 answers for malformed sizes instead of raising" do
    test "a nonsense size is not admissible" do
      w = window(4, 1000)

      refute PublishWindow.admits?(w, -1)
      refute PublishWindow.admits?(w, nil)
      refute PublishWindow.admits?(w, "100")
      refute PublishWindow.admits?(w, 1.5)

      # ...and a legal size still is, so the clause above did not swallow everything.
      assert PublishWindow.admits?(w, 100)
    end
  end

  describe "the bound is never TRANSIENTLY exceeded" do
    test "no admit sequence ever reports more outstanding than granted" do
      # Checks the invariant after EVERY operation, not only at the end: a window that
      # overcommitted and then corrected itself would pass an end-state assertion.
      frames = 3
      bytes = 300

      Enum.reduce(1..40, window(frames, bytes), fn i, w ->
        size = rem(i * 37, 150) + 1

        # Each operation's RETURNED state is asserted before the next one runs. The previous
        # version asserted after the admit and then settled, leaving the settled state unchecked
        # until the following iteration -- so a settlement that overcommitted was never seen at
        # the point it happened.
        w =
          case PublishWindow.admit(w, i, size, 500) do
            {:ok, w2} -> w2
            {:error, _} -> w
          end

        assert PublishWindow.outstanding_frames(w) <= frames
        assert PublishWindow.outstanding_bytes(w) <= bytes

        w =
          if rem(i, 3) === 0 do
            # Never settle because a frame EXPIRED -- the frame is still in flight, and a test
            # that models it teaches the anti-pattern while looking like coverage. settle/3 takes
            # no evidence at all now; the caller owns that verification.
            case Map.keys(outstanding_seqs(w)) do
              [seq | _] -> elem(PublishWindow.settle(w, seq, @primary), 1)
              [] -> w
            end
          else
            w
          end

        assert PublishWindow.outstanding_frames(w) <= frames
        assert PublishWindow.outstanding_bytes(w) <= bytes

        w
      end)
    end
  end

  describe "settling is ACCOUNTING ONLY, and says so" do
    test "there is NO PubAck parameter, because an Ack-shaped map was not proof" do
      # The previous arity took a raw map and called it evidence. It proved nothing: one
      # bulk-stream ack settled all five terminal outcomes, and the same ack could settle a second
      # lane sequence under a different outcome. Removing the parameter is the honest fix -- a
      # weaker imitation of proof in front of a real gap is worse than an acknowledged gap.
      {:module, _} = Code.ensure_loaded(PublishWindow)

      refute function_exported?(PublishWindow, :settle, 4)
      assert function_exported?(PublishWindow, :settle, 3)
    end

    test "a RETRYABLE outcome does not settle at all" do
      w = admit!(window(), 1, 100, 500)

      assert {:error, :not_settled} = PublishWindow.settle(w, 1, @retryable)
      assert PublishWindow.outstanding_bytes(w) === 100

      assert {:ok, w} = PublishWindow.rearm(w, 1, 900)
      assert PublishWindow.outstanding_bytes(w) === 100
    end

    test "every settling outcome releases; the retryable one does not" do
      for outcome <- PublishWindow.internal_outcomes() do
        w = admit!(window(), 1, 100, 500)
        result = PublishWindow.settle(w, 1, outcome)

        if outcome === @retryable do
          assert {:error, :not_settled} = result
        else
          assert {:ok, settled} = result, "#{outcome} did not settle"
          assert PublishWindow.outstanding_bytes(settled) === 0
        end
      end
    end

    test "an unknown internal outcome fails closed" do
      w = admit!(window(), 1, 100, 500)

      for bad <- [nil, :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE, :future, 99, "x"] do
        assert {:error, :unknown_outcome} = PublishWindow.settle(w, 1, bad),
               "#{inspect(bad)} was accepted"
      end

      assert PublishWindow.outstanding_bytes(w) === 100
    end

    test "the six-to-five mapping is EXACT and BIDIRECTIONAL against the generated enum" do
      # The previous version checked only both quarantines plus retryable, so primary, audit and
      # permanent could be remapped with it still green -- and it compared hard-coded atoms, so a
      # rename or removal in the generated enum also left it green.
      expected = %{
        primary_publication: :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE,
        audit_publication: :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY,
        quarantine_publication: :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE,
        security_quarantine_publication: :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE,
        permanent_rejection: :EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT,
        retryable_rejection: :EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE
      }

      # FORWARD: the module's outcome inventory is exactly these six, and each maps as stated.
      assert Enum.sort(PublishWindow.internal_outcomes()) === Enum.sort(Map.keys(expected))

      for {outcome, wire} <- expected do
        assert PublishWindow.wire_disposition(outcome) === {:ok, wire},
               "#{outcome} no longer maps to #{wire}"
      end

      # BACKWARD: every wire member reached is a real member of the GENERATED enum, and the five
      # distinct targets are exactly the enum's non-unspecified members. A rename or removal
      # upstream fails here instead of leaving hard-coded atoms agreeing with themselves.
      declared =
        Serviceradar.Edge.V1.EdgeRecordDispositionKind.mapping()
        |> Map.keys()
        |> Enum.reject(&(&1 === :EDGE_RECORD_DISPOSITION_KIND_UNSPECIFIED))
        |> Enum.sort()

      assert expected |> Map.values() |> Enum.uniq() |> Enum.sort() === declared,
             "the outcomes do not cover exactly the declared wire members"

      # SIX to FIVE: the collapse is real, and it is the quarantine pair that collapses.
      assert map_size(expected) === 6
      assert expected |> Map.values() |> Enum.uniq() |> length() === 5

      assert expected.quarantine_publication === expected.security_quarantine_publication
      refute :quarantine_publication === :security_quarantine_publication

      assert PublishWindow.wire_disposition(:nope) === :error
    end
  end

  describe "credits are conserved" do
    test "admit/settle round-trips return the window to its starting state" do
      start = window(8, 5000)

      w =
        Enum.reduce(1..8, start, fn seq, acc -> admit!(acc, seq, seq * 10, 500) end)

      assert PublishWindow.outstanding_frames(w) === 8
      assert PublishWindow.outstanding_bytes(w) === Enum.sum(Enum.map(1..8, &(&1 * 10)))

      settled =
        Enum.reduce(1..8, w, fn seq, acc ->
          {:ok, acc} = PublishWindow.settle(acc, seq, @primary)
          acc
        end)

      # === on the whole struct: a leak of one byte or one frame shows here, and so would a
      # settled sequence left behind in the map.
      assert settled === start
    end

    test "settling out of order conserves exactly as well" do
      start = window(4, 400)
      w = Enum.reduce([1, 2, 3, 4], start, &admit!(&2, &1, 100, 500))

      settled =
        Enum.reduce([3, 1, 4, 2], w, fn seq, acc ->
          {:ok, acc} = PublishWindow.settle(acc, seq, @primary)
          acc
        end)

      assert settled === start
    end

    test "credits are conserved even when some admits are REFUSED" do
      # Renamed to what it proves. It used to be titled "outstanding bytes never exceed the
      # grant", but it asserted the bounds only on the FINAL state -- which the equality below
      # shows is an EMPTY window, making `0 <= 700` and `0 <= 2` trivially true. Those assertions
      # could not detect a transient overcommit that a later transition corrected. The 40-step
      # test carries the per-transition bound property; this one carries something different.
      #
      # What is distinct here: five 300-byte frames are offered to a 2-frame/700-byte window, so
      # admits are REFUSED mid-run. Conservation must survive that -- a refusal that charged
      # anything, or a settle-after-refusal that released something never charged, shows up as a
      # window that does not return to its starting state.
      ops = [
        {:admit, 1, 300},
        {:admit, 2, 300},
        {:admit, 3, 300},
        {:settle, 1},
        {:admit, 4, 300},
        {:settle, 2},
        {:settle, 3},
        {:admit, 5, 300},
        {:settle, 4},
        {:settle, 5}
      ]

      start = window(2, 700)

      {final, refusals} =
        Enum.reduce(ops, {start, 0}, fn
          {:admit, seq, bytes}, {w, refused} ->
            case PublishWindow.admit(w, seq, bytes, 500) do
              {:ok, w2} -> {w2, refused}
              {:error, _} -> {w, refused + 1}
            end

          {:settle, seq}, {w, refused} ->
            case PublishWindow.settle(w, seq, @primary) do
              {:ok, w2} -> {w2, refused}
              {:error, _} -> {w, refused + 1}
            end
        end)

      # NOT VACUOUS, and this is the part the old version never checked: the run must actually
      # have hit refusals, or it is just the clean round-trip test above under another name.
      assert refusals > 0, "no admit or settle was refused; the window was never pressured"

      assert final === start, "credits were not conserved across a run containing refusals"
    end
  end
end
