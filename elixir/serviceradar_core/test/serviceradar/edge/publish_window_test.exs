defmodule ServiceRadar.Edge.PublishWindowTest do
  @moduledoc """
  The dangerous properties are the ones where the window hands out more budget than it holds, or
  hands the same budget out twice. Most of these tests are about refusing to admit.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.PublishWindow

  # A reservation key is the COMPLETE authenticated slot; these tests vary only the sequence, so
  # the other three coordinates are fixed. `fp/1` is the publication fingerprint: same sequence =>
  # same record, which is what makes a re-admit a RETRY rather than a conflict.
  defp k(seq), do: PublishWindow.key(<<0xA1>>, "agent-1", <<0xB2>>, seq, fp(seq))
  defp fp(seq), do: {:record, seq}
  # A DIFFERENT agent and spool at the same sequence number.
  defp k2(seq), do: PublishWindow.key(<<0xA1>>, "agent-2", <<0xC3>>, seq, fp(seq))
  # A DIFFERENT record on the SAME slot -- a different publication, not a conflict.
  defp k_other_record(seq),
    do: PublishWindow.key(<<0xA1>>, "agent-1", <<0xB2>>, seq, {:other_record, seq})

  # ONE generation per test process, so repeated admits in a test share a transport the way a
  # real lane does. Tests that need a SECOND generation mint their own with make_ref/0.
  defp gen do
    case Process.get(:generation) do
      nil ->
        ref = make_ref()
        Process.put(:generation, ref)
        ref

      ref ->
        ref
    end
  end

  defp window(frames \\ 4, bytes \\ 1000) do
    {:ok, w} = PublishWindow.new(frames, bytes)
    w
  end

  @primary :primary_publication
  @retryable :retryable_rejection

  # The outstanding set, without reaching through the opaque struct in every test.
  defp outstanding_seqs(w) do
    1..60
    |> Map.new(fn s -> {s, PublishWindow.outstanding?(w, k(s))} end)
    |> Enum.filter(fn {_s, out} -> out end)
    |> Map.new()
  end

  # Admits AND activates: an admission is provisional until its caller takes delivery, and every
  # test below is modelling a caller that did. The provisional phase has its own tests.
  defp admit!(w, seq, bytes, deadline) do
    {:ok, w, reservation} = PublishWindow.admit(w, k(seq), bytes, deadline, self(), gen())
    {:ok, w} = PublishWindow.activate(w, reservation)
    Process.put({:reservation, seq}, reservation)
    w
  end

  # The reservation admit! issued for that sequence. Settling and re-arming need the epoch token,
  # not just the key -- that is what stops a late ack from releasing a later reservation.
  defp r(seq), do: Process.get({:reservation, seq})

  # Admit AND activate, i.e. model a caller that took delivery. Direct `admit/4` leaves the
  # attempt PROVISIONAL, which is deliberately inert -- the provisional phase has its own tests.
  defp admit_active!(w, key, bytes, deadline) do
    {:ok, w, reservation} = PublishWindow.admit(w, key, bytes, deadline, self(), gen())
    {:ok, w} = PublishWindow.activate(w, reservation)
    {w, reservation}
  end

  # A well-formed reservation for a publication that is NOT outstanding.
  defp absent(seq), do: {k(seq), 1}

  # The conserved quantities. Deliberately NOT the whole struct: `next_token` advances with every
  # admission and never rewinds, which is the property that stops a settled epoch's late ack from
  # releasing a later reservation. Comparing structs would therefore fail on a window that
  # conserved credits perfectly. Outstanding frames and bytes still catch a leak, and a settled
  # entry left behind in the map still shows up as an outstanding frame.
  defp accounting(w) do
    %{
      outstanding_frames: PublishWindow.outstanding_frames(w),
      outstanding_bytes: PublishWindow.outstanding_bytes(w),
      available_frames: PublishWindow.available_frames(w),
      available_bytes: PublishWindow.available_bytes(w)
    }
  end

  describe "the grant is the bound" do
    test "credits come from the lane-open ack, and zero admits nothing" do
      # Zero is NOT legal -- 1.7-e's `1 <= granted` makes it a refusal. It reaches here because
      # nothing on this side validates a lane ack, and a window handed zero simply has no capacity.
      {:ok, none} = PublishWindow.new(0, 0)

      assert PublishWindow.available_frames(none) === 0
      refute PublishWindow.admits?(none, 0)

      assert {:error, :frame_credits_exhausted} =
               PublishWindow.admit(none, k(1), 0, 100, self(), gen())
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

      assert {:error, :frame_credits_exhausted} =
               PublishWindow.admit(w, k(5), 1, 500, self(), gen())

      # Settling one makes room for exactly one.
      {:ok, w} = PublishWindow.settle(w, r(1), @primary, self())
      assert {:ok, w, _res} = PublishWindow.admit(w, k(5), 1, 500, self(), gen())

      assert {:error, :frame_credits_exhausted} =
               PublishWindow.admit(w, k(6), 1, 500, self(), gen())
    end

    # NAMED for what it does: `bytes` is SUPPLIED by the caller and accounted as given. Nothing
    # binds it to the encoded frame size -- task 3.4 owns that, with the remaining 3.3(c)
    # integration -- so calling it "actual size" claimed a binding this module does not have.
    test "the BYTE grant is hard against the SUPPLIED byte count" do
      w = 100 |> window(1000) |> admit!(1, 600, 500)

      assert PublishWindow.available_bytes(w) === 400
      assert PublishWindow.admits?(w, 400)
      refute PublishWindow.admits?(w, 401)

      assert {:error, :byte_credits_exhausted} =
               PublishWindow.admit(w, k(2), 401, 500, self(), gen())

      assert {:ok, w, _res} = PublishWindow.admit(w, k(2), 400, 500, self(), gen())
      assert PublishWindow.available_bytes(w) === 0
    end

    test "a second admit WHILE an attempt is in flight is refused" do
      # Two requests on the wire under ONE charge is the bound violation: the first acknowledgement
      # frees the credit while the second is still live, and the next admission goes past the
      # grant. A retry has to wait for the current attempt to end.
      w = admit!(window(), 1, 100, 500)

      assert {:error, :attempt_in_flight} = PublishWindow.admit(w, k(1), 100, 900, self(), gen())
    end

    test "after the attempt ENDS, re-admitting is the republish path, not a double charge" do
      w = admit!(window(), 1, 100, 500)
      {:ok, w} = PublishWindow.attempt_failed(w, r(1), self())

      # Credits are STILL charged -- the record is owed a republish -- so the retry adds none.
      assert PublishWindow.outstanding_frames(w) === 1
      assert PublishWindow.outstanding_bytes(w) === 100

      {retried, retry} = admit_active!(w, k(1), 100, 900)
      assert PublishWindow.outstanding_frames(retried) === 1
      assert PublishWindow.outstanding_bytes(retried) === 100
      assert PublishWindow.expired(retried, 500) === []

      # A NEW attempt token: the previous attempt's late acknowledgement cannot settle this one.
      refute retry === r(1)
      assert {:error, :not_outstanding} = PublishWindow.settle(retried, r(1), @primary, self())
    end

    test "a DIFFERENT record on the same slot is a separate publication, and IS admitted" do
      # The spec requires this frame to be published: Nats-Msg-Id binds record_sha256, so JetStream
      # does not deduplicate it away and it "SHALL reach EventWriter", which rejects it as a
      # transport-integrity violation. Refusing it here would move EventWriter's adjudication into
      # the gateway and destroy the evidence -- which an earlier :slot_conflict did.
      w = admit!(window(), 1, 100, 500)

      {w2, _res} = admit_active!(w, k_other_record(1), 100, 500)

      # Charged on its OWN credits, like any other frame: two publications, two reservations.
      assert PublishWindow.outstanding_frames(w2) === 2
      assert PublishWindow.outstanding_bytes(w2) === 200
    end

    test "the second record is refused when the lane is FULL -- on credits, not on identity" do
      # NOT VACUOUS alongside the test above: the refusal must come from the grant being spent,
      # not from the slot being occupied, so it reports a credit error.
      w = admit!(window(1, 1_000), 1, 100, 500)

      assert {:error, :frame_credits_exhausted} =
               PublishWindow.admit(w, k_other_record(1), 100, 500, self(), gen())
    end

    test "malformed inputs are refused" do
      w = window()

      assert {:error, :publication} = PublishWindow.admit(w, k(0), 1, 500, self(), gen())
      assert {:error, :publication} = PublishWindow.admit(w, k(-1), 1, 500, self(), gen())

      assert {:error, :publication} =
               PublishWindow.admit(w, k(0xFFFFFFFFFFFFFFFF + 1), 1, 500, self(), gen())

      assert {:error, :bytes} = PublishWindow.admit(w, k(1), -1, 500, self(), gen())
      assert {:error, :deadline} = PublishWindow.admit(w, k(1), 1, nil, self(), gen())
    end
  end

  describe "a deadline REPORTS; only settling releases" do
    test "an expired frame stays outstanding and stays charged" do
      # THE TRAP. If expiry released credits, the window would hand the same budget out twice --
      # the publisher republishes the same bytes on the same slot, so the frame is still in
      # flight. The bound would relax exactly when the broker is already struggling.
      w = 2 |> window(1000) |> admit!(1, 400, 100) |> admit!(2, 400, 900)

      assert PublishWindow.expired(w, 500) === [r(1)]

      assert PublishWindow.outstanding_frames(w) === 2
      assert PublishWindow.outstanding_bytes(w) === 800
      assert PublishWindow.available_frames(w) === 0

      # Still refused, because nothing was released.
      assert {:error, :frame_credits_exhausted} =
               PublishWindow.admit(w, k(3), 1, 900, self(), gen())
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
      # expired/2 reports RESERVATIONS: {{slot, fingerprint}, token}. Not lane sequences, and not
      # bare keys -- the token is what a settle or re-arm must carry.
      assert Enum.all?(result, fn {{{scope, agent, spool, seq}, _fingerprint}, token} ->
               is_binary(scope) and is_binary(agent) and is_binary(spool) and is_integer(seq) and
                 is_integer(token)
             end)

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
      {:abandon, 2},
      {:activate, 2},
      {:admit, 6},
      {:attempt_failed, 3},
      {:admits?, 2},
      {:available_bytes, 1},
      {:available_frames, 1},
      {:expired, 2},
      {:fence_generation, 2},
      {:key, 5},
      {:live_generations, 1},
      {:reservation, 2},
      {:new, 2},
      {:outstanding?, 2},
      {:outstanding_bytes, 1},
      {:outstanding_frames, 1},
      {:rearm, 4},
      {:revoke_pending, 2},
      {:settle, 4},
      {:wire_disposition, 1},
      {:internal_outcomes, 0}
    ]

    test "the public surface is EXACTLY the classified inventory, PER KIND" do
      {:module, _} = Code.ensure_loaded(PublishWindow)

      # Compared SEPARATELY, not as one merged set. Merging them lets a kind substitution pass:
      # turning `def settle/4` into `defmacro settle/4` leaves {:settle, 4} present either way,
      # while changing the call semantics to compile-time expansion. The guard exists to make any
      # change of public surface explicit, and the KIND is part of that surface.
      functions = Enum.sort(PublishWindow.__info__(:functions))
      macros = Enum.sort(PublishWindow.__info__(:macros))

      assert functions === Enum.sort(@public_functions),
             "exported FUNCTIONS drifted: added #{inspect(functions -- @public_functions)}, " <>
               "removed #{inspect(@public_functions -- functions)}. " <>
               "credits are released by settle/4 and by abandon/2 -- and by nothing else. " <>
               "abandon/2 exists ONLY for an admission its caller never received, and takes a " <>
               "token-bearing reservation so it can enforce that."

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
      assert PublishWindow.expired(w, 100) === [r(1)]
      assert PublishWindow.expired(w, 300) === [r(1), r(2), r(3)]
    end

    test "settling releases exactly that frame's bytes" do
      w = 4 |> window(1000) |> admit!(1, 250, 500) |> admit!(2, 125, 500)

      {:ok, w} = PublishWindow.settle(w, r(1), @primary, self())

      assert PublishWindow.outstanding_bytes(w) === 125
      assert PublishWindow.available_bytes(w) === 875
      refute PublishWindow.outstanding?(w, k(1))
      assert PublishWindow.outstanding?(w, k(2))
    end

    test "settling anything not outstanding is refused, not a silent no-op" do
      w = admit!(window(), 1, 100, 500)
      {:ok, settled} = PublishWindow.settle(w, r(1), @primary, self())

      # Never admitted, and already settled, are BOTH :not_outstanding. Telling them apart would
      # require retaining every settled sequence forever, which is the growth this bounds.
      assert {:error, :not_outstanding} = PublishWindow.settle(w, absent(99), @primary, self())
      assert {:error, :not_outstanding} = PublishWindow.settle(settled, r(1), @primary, self())
    end
  end

  describe "the deadline boundary is exactly as documented" do
    test "a deadline AT `now` has passed; one strictly after has not" do
      # The contract says `deadline <= now`, so the boundary is promised and therefore pinned.
      # `<` vs `<=` is a one-character change that silently shifts every timeout by one tick.
      w = admit!(window(), 1, 10, 100)

      assert PublishWindow.expired(w, 99) === []
      assert PublishWindow.expired(w, 100) === [r(1)]
      assert PublishWindow.expired(w, 101) === [r(1)]
    end
  end

  describe "settling releases exactly one frame's worth" do
    test "differently sized frames: settling one releases THAT frame's bytes only" do
      # Sizes are deliberately distinct, so releasing the wrong frame's bytes -- or all of them --
      # produces a different number rather than coincidentally the same one.
      w = 4 |> window(1000) |> admit!(1, 100, 500) |> admit!(2, 250, 500) |> admit!(3, 50, 500)

      assert PublishWindow.outstanding_bytes(w) === 400

      {:ok, w} = PublishWindow.settle(w, r(2), @primary, self())

      assert PublishWindow.outstanding_bytes(w) === 150,
             "settling frame 2 did not release exactly its 250 bytes"

      assert PublishWindow.outstanding_frames(w) === 2
      assert PublishWindow.outstanding?(w, k(1))
      assert PublishWindow.outstanding?(w, k(3))
      refute PublishWindow.outstanding?(w, k(2))
    end

    test "a SECOND settlement releases nothing further" do
      w = 4 |> window(1000) |> admit!(1, 300, 500) |> admit!(2, 100, 500)
      {:ok, once} = PublishWindow.settle(w, r(1), @primary, self())

      assert PublishWindow.outstanding_bytes(once) === 100
      assert PublishWindow.available_bytes(once) === 900

      assert {:error, :not_outstanding} = PublishWindow.settle(once, r(1), @primary, self())

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
      assert PublishWindow.expired(w, 1_000) === [r(1), r(2), r(3)]

      # ...and the window is still completely full, because expiry released nothing.
      assert PublishWindow.available_frames(w) === 0
      assert PublishWindow.available_bytes(w) === 0
      refute PublishWindow.admits?(w, 1)

      assert {:error, :frame_credits_exhausted} =
               PublishWindow.admit(w, k(4), 100, 1_000, self(), gen())

      # Settling ONE frame admits exactly ONE replacement, not more.
      {:ok, w} = PublishWindow.settle(w, r(2), @primary, self())

      assert PublishWindow.available_frames(w) === 1
      assert PublishWindow.available_bytes(w) === 100
      assert {:ok, w, _res} = PublishWindow.admit(w, k(4), 100, 1_000, self(), gen())

      assert {:error, :frame_credits_exhausted} =
               PublishWindow.admit(w, k(5), 1, 1_000, self(), gen())
    end
  end

  describe "an expired frame can be re-armed without releasing credits" do
    test "rearm/3 moves the deadline and charges nothing" do
      # Without this the retry was UNREPRESENTABLE: admit/4 refuses an outstanding slot and
      # settle/3 would release credits for a frame still in flight, so an expired frame could be
      # reported forever and never re-armed.
      w = 2 |> window(1000) |> admit!(1, 400, 100) |> admit!(2, 400, 100)

      assert PublishWindow.expired(w, 500) === [r(1), r(2)]

      {:ok, w} = PublishWindow.rearm(w, r(1), 900, self())

      # No longer expired at 500, and nothing about the budget moved.
      assert PublishWindow.expired(w, 500) === [r(2)]
      assert PublishWindow.outstanding_frames(w) === 2
      assert PublishWindow.outstanding_bytes(w) === 800
      assert PublishWindow.available_bytes(w) === 200
      assert PublishWindow.available_frames(w) === 0
    end

    test "re-arming does NOT create capacity, so the bound still holds" do
      w = 1 |> window(100) |> admit!(1, 100, 10)

      {:ok, w} = PublishWindow.rearm(w, r(1), 999, self())

      refute PublishWindow.admits?(w, 1)

      assert {:error, :frame_credits_exhausted} =
               PublishWindow.admit(w, k(2), 0, 999, self(), gen())
    end

    test "re-arming something not outstanding is refused" do
      w = admit!(window(), 1, 100, 500)
      {:ok, settled} = PublishWindow.settle(w, r(1), @primary, self())

      assert {:error, :not_outstanding} = PublishWindow.rearm(w, absent(99), 900, self())
      assert {:error, :not_outstanding} = PublishWindow.rearm(settled, r(1), 900, self())
      assert {:error, :deadline} = PublishWindow.rearm(w, r(1), nil, self())
    end

    test "a re-armed frame settles exactly once, releasing its original bytes" do
      w = 2 |> window(1000) |> admit!(1, 375, 100)
      {:ok, w} = PublishWindow.rearm(w, r(1), 900, self())
      {:ok, w} = PublishWindow.settle(w, r(1), @primary, self())

      assert PublishWindow.outstanding_bytes(w) === 0
      assert {:error, :not_outstanding} = PublishWindow.settle(w, r(1), @primary, self())
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
          case PublishWindow.admit(w, k(i), size, 500, self(), gen()) do
            {:ok, w2, res} -> elem(PublishWindow.activate(w2, res), 1)
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
              [seq | _] ->
                {:ok, res} = PublishWindow.reservation(w, k(seq))
                elem(PublishWindow.settle(w, res, @primary, self()), 1)

              [] ->
                w
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

      refute function_exported?(PublishWindow, :settle, 5)
      assert function_exported?(PublishWindow, :settle, 4)

      # ARITY ALONE NO LONGER SAYS IT. settle/4 exists again, but its fourth argument is the
      # attempt's OWNER -- the fence that makes termination the owner's to report, not an
      # acknowledgement dressed up as proof. So this guard is behavioural now: an Ack-shaped map
      # offered in that position settles nothing, which is the property the removed parameter was
      # really about.
      w = window(1, 100)
      {w, res} = admit_active!(w, k(1), 50, 500)
      ack = %{"stream" => "TELEMETRY_EDGE_RECORD_V1_BULK", "seq" => 5}

      assert {:error, :not_outstanding} = PublishWindow.settle(w, res, @primary, ack)

      # NOT VACUOUS: the owner settles the same reservation.
      assert {:ok, _w} = PublishWindow.settle(w, res, @primary, self())
    end

    test "a RETRYABLE outcome does not settle at all" do
      w = admit!(window(), 1, 100, 500)

      assert {:error, :not_settled} = PublishWindow.settle(w, r(1), @retryable, self())
      assert PublishWindow.outstanding_bytes(w) === 100

      assert {:ok, w} = PublishWindow.rearm(w, r(1), 900, self())
      assert PublishWindow.outstanding_bytes(w) === 100
    end

    test "every settling outcome releases; the retryable one does not" do
      for outcome <- PublishWindow.internal_outcomes() do
        w = admit!(window(), 1, 100, 500)
        result = PublishWindow.settle(w, r(1), outcome, self())

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
        assert {:error, :unknown_outcome} = PublishWindow.settle(w, r(1), bad, self()),
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
          {:ok, acc} = PublishWindow.settle(acc, r(seq), @primary, self())
          acc
        end)

      assert accounting(settled) === accounting(start)
    end

    test "settling out of order conserves exactly as well" do
      start = window(4, 400)
      w = Enum.reduce([1, 2, 3, 4], start, &admit!(&2, &1, 100, 500))

      settled =
        Enum.reduce([3, 1, 4, 2], w, fn seq, acc ->
          {:ok, acc} = PublishWindow.settle(acc, r(seq), @primary, self())
          acc
        end)

      assert accounting(settled) === accounting(start)
    end

    test "credits are conserved even when some admits are REFUSED" do
      # The 40-step test carries the per-transition bound property. What is distinct here: five
      # 300-byte frames are offered to a 2-frame/700-byte window, so an admit is REFUSED mid-run,
      # and conservation must survive that.
      #
      # The evidence is an EXACT RESULT TRACE, not a count of failures. A pooled counter let a
      # false-success admit pass: if admit/4 returned {:ok, w} without recording or charging the
      # frame, no admit would be refused, the later settle of that never-admitted sequence would
      # supply the only failure, and `final === start` would still hold because nothing was ever
      # charged. Asserting WHICH operation failed WITH WHICH reason closes that direction.
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

      {final, trace} =
        Enum.reduce(ops, {start, []}, fn
          {:admit, seq, bytes}, {w, acc} ->
            case PublishWindow.admit(w, k(seq), bytes, 500, self(), gen()) do
              {:ok, w2, res} ->
                {elem(PublishWindow.activate(w2, res), 1), [{:admit, seq, :ok} | acc]}

              {:error, reason} ->
                {w, [{:admit, seq, reason} | acc]}
            end

          {:settle, seq}, {w, acc} ->
            reservation =
              case PublishWindow.reservation(w, k(seq)) do
                {:ok, res} -> res
                :error -> absent(seq)
              end

            case PublishWindow.settle(w, reservation, @primary, self()) do
              {:ok, w2} -> {w2, [{:settle, seq, :ok} | acc]}
              {:error, reason} -> {w, [{:settle, seq, reason} | acc]}
            end
        end)

      # Every operation, in order, with its exact outcome. The two failures are at specific
      # positions for specific reasons: sequence 3 cannot be admitted because the FRAME grant is
      # full, and therefore cannot later be settled.
      assert Enum.reverse(trace) === [
               {:admit, 1, :ok},
               {:admit, 2, :ok},
               {:admit, 3, :frame_credits_exhausted},
               {:settle, 1, :ok},
               {:admit, 4, :ok},
               {:settle, 2, :ok},
               {:settle, 3, :not_outstanding},
               {:admit, 5, :ok},
               {:settle, 4, :ok},
               {:settle, 5, :ok}
             ]

      assert accounting(final) === accounting(start),
             "credits were not conserved across a run containing refusals"
    end
  end

  describe "reservations are keyed on the PUBLICATION" do
    test "two agents at the same sequence are INDEPENDENT reservations" do
      # The bug this closes: one lane pool serves every agent and spool in its class, so a bare
      # sequence aliased across them. Agent 2 at sequence 1 looked like agent 1's frame retrying --
      # it published on agent 1's credits, and its ack released agent 1's reservation.
      w = window(2, 1_000)

      {w, first} = admit_active!(w, k(1), 100, 500)
      {w, second} = admit_active!(w, k2(1), 100, 500)

      # Two frames, not one: the second was charged rather than mistaken for a retry.
      assert PublishWindow.outstanding_frames(w) === 2
      assert PublishWindow.outstanding_bytes(w) === 200

      # Settling one leaves the other outstanding. Under sequence keying, one ack cleared both.
      {:ok, w} = PublishWindow.settle(w, second, @primary, self())
      assert PublishWindow.outstanding_frames(w) === 1
      assert PublishWindow.expired(w, 500) === [first]
    end

    test "the second agent is REFUSED when the lane is full, never admitted on the first's credits" do
      w = window(1, 1_000)
      {w, _res} = admit_active!(w, k(1), 100, 500)

      # One frame of credit, already held by another agent's publication: a capacity refusal.
      assert {:error, :frame_credits_exhausted} =
               PublishWindow.admit(w, k2(1), 100, 500, self(), gen())
    end

    test "a slot differing ONLY in scope is still a different reservation" do
      w = window(2, 1_000)
      a = PublishWindow.key(<<0xA1>>, "agent-1", <<0xB2>>, 1, fp(1))
      b = PublishWindow.key(<<0xFF>>, "agent-1", <<0xB2>>, 1, fp(1))

      {w, _res} = admit_active!(w, a, 100, 500)
      {w, _res2} = admit_active!(w, b, 100, 500)

      # NOT VACUOUS: IDENTICAL fingerprints, so only the scope separates them. If scope were
      # dropped from the key these would collide and the second would be taken for a retry,
      # leaving one frame outstanding instead of two.
      assert PublishWindow.outstanding_frames(w) === 2
    end

    test "an incomplete slot is refused rather than keyed on whatever is present" do
      w = window(2, 1_000)

      for bad <- [
            PublishWindow.key(nil, "agent-1", <<0xB2>>, 1, fp(1)),
            PublishWindow.key(<<0xA1>>, nil, <<0xB2>>, 1, fp(1)),
            PublishWindow.key(<<0xA1>>, "agent-1", nil, 1, fp(1)),
            PublishWindow.key(<<0xA1>>, "", <<0xB2>>, 1, fp(1)),
            {{<<0xA1>>, "agent-1", <<0xB2>>, 0}, fp(1)},
            1,
            {1, 2}
          ] do
        assert {:error, :publication} = PublishWindow.admit(w, bad, 100, 500, self(), gen()),
               "admitted a malformed publication key: #{inspect(bad)}"
      end
    end
  end

  describe "a reservation settles exactly once, even when the key is reused" do
    test "a LATE ack from a settled epoch does not release the reservation holding the key now" do
      # The ABA. Two concurrent retries of publication A share one reservation. A's first ack
      # settles it; the key is now free; publication A is admitted again (the agent republishes);
      # A's SECOND, late ack arrives. Carrying only the key, it released the new reservation --
      # one attempt's acknowledgement cancelling another's, and credits handed out twice.
      w = admit!(window(), 1, 100, 500)
      first = r(1)

      {:ok, w} = PublishWindow.settle(w, first, @primary, self())
      assert PublishWindow.outstanding_frames(w) === 0

      # The same publication is admitted again: same key, NEW epoch.
      {w, second} = admit_active!(w, k(1), 100, 900)
      assert PublishWindow.outstanding_frames(w) === 1
      refute second === first

      # The late ack names the OLD epoch and must not touch the new reservation.
      assert {:error, :not_outstanding} = PublishWindow.settle(w, first, @primary, self())
      assert PublishWindow.outstanding_frames(w) === 1

      # NOT VACUOUS: the CURRENT reservation still settles.
      assert {:ok, w} = PublishWindow.settle(w, second, @primary, self())
      assert PublishWindow.outstanding_frames(w) === 0
    end

    test "a STALE expired-then-rearm cannot move a later reservation's deadline" do
      # An observer reads an expired reservation, it settles, something else reserves the key, and
      # the observer then re-arms what it read. With only the key that moved the NEW reservation's
      # deadline, silently extending a frame nobody had re-armed.
      w = admit!(window(), 1, 100, 100)

      [stale] = PublishWindow.expired(w, 100)
      {:ok, w} = PublishWindow.settle(w, stale, @primary, self())
      {w, fresh} = admit_active!(w, k(1), 100, 100)

      assert {:error, :not_outstanding} = PublishWindow.rearm(w, stale, 9_000, self())

      # The new reservation is still on ITS deadline, not the stale re-arm's.
      assert PublishWindow.expired(w, 100) === [fresh]

      # NOT VACUOUS: re-arming the CURRENT reservation does move it.
      {:ok, w} = PublishWindow.rearm(w, fresh, 9_000, self())
      assert PublishWindow.expired(w, 100) === []
    end

    test "only the CURRENT attempt can settle the reservation" do
      w = admit!(window(), 1, 100, 500)
      first = r(1)

      {:ok, w} = PublishWindow.attempt_failed(w, first, self())
      {w, retry} = admit_active!(w, k(1), 100, 900)

      # The superseded attempt cannot settle, and cannot end the live one either.
      assert {:error, :not_outstanding} = PublishWindow.settle(w, first, @primary, self())
      assert {:error, :not_outstanding} = PublishWindow.attempt_failed(w, first, self())

      # NOT VACUOUS: the current attempt still settles, exactly once.
      assert {:ok, w} = PublishWindow.settle(w, retry, @primary, self())
      assert PublishWindow.outstanding_frames(w) === 0
    end

    test "attempt tokens do NOT repeat across a fresh window" do
      # A per-window counter restarted at 1, so after a lane restart a stale reservation compared
      # EQUAL to a fresh one -- and settling the stale one released the fresh one's credits.
      w1 = admit!(window(), 1, 100, 500)
      stale = r(1)

      # A brand-new window, as a restarted pool builds.
      _w2 = admit!(window(), 1, 100, 500)
      fresh = r(1)

      refute stale === fresh, "attempt tokens repeated across window incarnations"

      # And the stale handle cannot settle in the window it did not come from.
      assert {:error, :not_outstanding} = PublishWindow.settle(w1, fresh, @primary, self())
    end

    test "abandon refuses a CONFIRMED attempt" do
      # INVERTED, because the previous version of this test enshrined a bug: it activated the
      # attempt and then asserted abandonment SUCCEEDED. In a one-credit window that means
      # activate A, abandon A, admit B -- while A may already be publishing, so one grant covers
      # two publications.
      w = admit!(window(), 1, 100, 500)

      assert {:error, :not_outstanding} = PublishWindow.abandon(w, r(1))
      assert PublishWindow.outstanding_frames(w) === 1
    end

    test "abandon releases only the PROVISIONAL attempt it names" do
      w = window()
      {:ok, w, provisional} = PublishWindow.admit(w, k(1), 100, 500, self(), gen())
      {key, token} = provisional

      # Token-bound: a superseded attempt cannot release whatever holds the key now.
      #
      # The WRONG token is derived from the real one rather than written as the literal 1, which
      # is what this asserted before and is a real token often enough to matter. Attempt tokens
      # come from `System.unique_integer([:monotonic, :positive])`, which is per-VM and starts at
      # 1 -- so whenever this test happened to run before much else had drawn from that source,
      # `{k(1), 1}` WAS the live reservation and abandoning it correctly succeeded. The suite then
      # failed here on a window that was behaving exactly as specified.
      #
      # The other `{key, 1}` literals in this file are safe and stay: they name keys that are not
      # outstanding at all, so the token is never reached.
      assert {:error, :not_outstanding} = PublishWindow.abandon(w, {key, token + 1})

      assert {:ok, released} = PublishWindow.abandon(w, provisional)
      assert PublishWindow.outstanding_frames(released) === 0
      assert PublishWindow.outstanding_bytes(released) === 0

      assert {:error, :not_outstanding} = PublishWindow.abandon(released, provisional)
    end
  end

  describe "an admission is PROVISIONAL until its caller takes delivery" do
    test "a provisional attempt holds its slot but is otherwise inert" do
      # THE LEAK. A provisional token reported as expired was enough for an observer to end the
      # attempt, admit a retry, and put two requests on the wire under one charge -- while the
      # caller handed the first token had not yet received it.
      w = window()
      {:ok, w, res} = PublishWindow.admit(w, k(1), 100, 100, self(), gen())

      # It DOES hold the slot: the credits are charged from admission.
      assert PublishWindow.outstanding_frames(w) === 1
      assert PublishWindow.outstanding_bytes(w) === 100

      # ...and nothing else can act on it.
      assert PublishWindow.expired(w, 9_999) === []
      assert PublishWindow.reservation(w, k(1)) === :error
      assert {:error, :not_outstanding} = PublishWindow.settle(w, res, @primary, self())
      assert {:error, :not_outstanding} = PublishWindow.rearm(w, res, 900, self())
      assert {:error, :not_outstanding} = PublishWindow.attempt_failed(w, res, self())

      # Nor can a retry slip into the slot it is holding.
      assert {:error, :attempt_in_flight} = PublishWindow.admit(w, k(1), 100, 900, self(), gen())

      # NOT VACUOUS: activation makes every one of those work.
      {:ok, w} = PublishWindow.activate(w, res)
      assert PublishWindow.expired(w, 9_999) === [res]
      assert PublishWindow.reservation(w, k(1)) === {:ok, res}
      assert {:ok, _} = PublishWindow.settle(w, res, @primary, self())
    end

    test "revoking a provisional retry restores the reservation without releasing it" do
      w = admit!(window(), 1, 100, 500)
      {:ok, w} = PublishWindow.attempt_failed(w, r(1), self())
      {:ok, w, provisional} = PublishWindow.admit(w, k(1), 100, 900, self(), gen())

      # revoke_pending is the retry half of revocation: credits stay, the attempt goes.
      assert {:ok, w} = PublishWindow.revoke_pending(w, provisional)
      assert PublishWindow.outstanding_frames(w) === 1
      assert PublishWindow.outstanding_bytes(w) === 100

      # ...and the slot is free for the next attempt.
      assert {:ok, _w, _next} = PublishWindow.admit(w, k(1), 100, 900, self(), gen())
    end

    test "revoke_pending refuses a CONFIRMED attempt" do
      # Its whole authority is "the handoff did not complete". An active attempt is one the caller
      # holds, and may already be on the wire.
      w = admit!(window(), 1, 100, 500)
      assert {:error, :not_outstanding} = PublishWindow.revoke_pending(w, r(1))
    end

    test "activate refuses anything but its own provisional attempt" do
      w = window()
      {:ok, w, res} = PublishWindow.admit(w, k(1), 100, 500, self(), gen())
      {:ok, w} = PublishWindow.activate(w, res)

      # Twice is not idempotent-by-accident: the second call finds no provisional attempt.
      assert {:error, :not_outstanding} = PublishWindow.activate(w, res)
      assert {:error, :not_outstanding} = PublishWindow.activate(w, {k(2), 1})
    end
  end

  describe "only the attempt's OWNER may end it" do
    # A LIVE process that is not this one. It has to be alive: the window compares pids, and a
    # dead pid compares exactly the same, so spawning-and-letting-die would prove something
    # weaker than intended.
    defp bystander do
      pid = spawn(fn -> Process.sleep(:infinity) end)

      # NOT spawn_link. A process exiting NORMALLY does not kill what it is linked to, and an
      # ExUnit test process exits normally on success -- so a linked infinite sleeper outlives
      # the test that created it and accumulates across the suite.
      on_exit(fn -> Process.exit(pid, :kill) end)
      pid
    end

    test "a process that did not admit the attempt cannot end it" do
      w = window(1, 100)
      {w, res} = admit_active!(w, k(1), 50, 500)

      assert {:error, :not_outstanding} = PublishWindow.attempt_failed(w, res, bystander())

      # NOT VACUOUS: the identical call from the OWNER succeeds, so the refusal is about who
      # asked and not about the reservation being unusable.
      assert {:ok, _w} = PublishWindow.attempt_failed(w, res, self())
    end

    test "a process that did not admit the attempt cannot settle it" do
      w = window(1, 100)
      {w, res} = admit_active!(w, k(1), 50, 500)

      assert {:error, :not_outstanding} = PublishWindow.settle(w, res, @primary, bystander())
      assert {:ok, _w} = PublishWindow.settle(w, res, @primary, self())
    end

    test "a process that did not admit the attempt cannot move its deadline" do
      w = window(1, 100)
      {w, res} = admit_active!(w, k(1), 50, 500)

      assert {:error, :not_outstanding} = PublishWindow.rearm(w, res, 900, bystander())
      assert {:ok, _w} = PublishWindow.rearm(w, res, 900, self())
    end

    test "an owner that is not a process is refused at admission" do
      w = window(1, 100)

      assert {:error, :owner} = PublishWindow.admit(w, k(1), 50, 500, :not_a_pid, gen())
      assert {:error, :owner} = PublishWindow.admit(w, k(1), 50, 500, nil, gen())
      assert {:ok, _w, _res} = PublishWindow.admit(w, k(1), 50, 500, self(), gen())
    end
  end

  describe "a passed deadline REPORTS, and authorises nothing" do
    test "an expired attempt stays in flight until its owner terminates it" do
      # THE SCENARIO THE SPEC NAMES. Expiry cannot distinguish "never sent" from "in flight",
      # "delayed", or "acknowledged with the acknowledgement lost", so it must not free the slot
      # -- otherwise a retry publishes while the first request is still live, two requests under
      # one charge.
      w = window(1, 100)
      {w, res} = admit_active!(w, k(1), 50, 100)

      # A sweep can SEE it...
      assert PublishWindow.expired(w, 101) === [res]

      sweep = bystander()

      # ...and that is the entire extent of what it can do with it.
      assert {:error, :not_outstanding} = PublishWindow.attempt_failed(w, res, sweep)
      assert {:error, :not_outstanding} = PublishWindow.settle(w, res, @primary, sweep)

      # So the attempt is still in flight and the retry is still refused.
      assert {:error, :attempt_in_flight} = PublishWindow.admit(w, k(1), 50, 900, self(), gen())

      # Only the owner reporting TERMINATION opens the retry.
      assert {:ok, w} = PublishWindow.attempt_failed(w, res, self())
      assert {:ok, _w, _retry} = PublishWindow.admit(w, k(1), 50, 900, self(), gen())
    end
  end

  describe "a dead transport generation ends attempts WITHOUT releasing them" do
    test "THE RESTART INVARIANT: a fenced generation frees no capacity" do
      # Grant of ONE frame. A is admitted and reaches the transport; that transport then dies.
      # The old accounting used to vanish with it, so a replacement started with the full grant
      # and B could publish alongside an A that may already be on the wire.
      w = window(1, 100)
      {w, res_a} = admit_active!(w, k(1), 50, 500)
      assert %{outstanding_frames: 1, available_frames: 0} = accounting(w)

      {:ok, w, fenced} = PublishWindow.fence_generation(w, gen())
      assert fenced === 1

      # THE POINT: the charge SURVIVES. A's bytes may already be at the broker, so releasing
      # here would hand back a broker-ambiguous frame.
      assert %{outstanding_frames: 1, outstanding_bytes: 50, available_frames: 0} = accounting(w)

      # So B is still refused -- the replacement transport inherits the REMAINING capacity, not a
      # fresh grant.
      assert {:error, :frame_credits_exhausted} =
               PublishWindow.admit(w, k(2), 50, 900, self(), make_ref())

      # A itself may retry on the charge it already holds, on the NEW generation, costing nothing.
      newgen = make_ref()
      assert {:ok, w, retry} = PublishWindow.admit(w, k(1), 50, 900, self(), newgen)
      assert %{outstanding_frames: 1, outstanding_bytes: 50} = accounting(w)

      # Only once A SETTLES does B become admissible.
      {:ok, w} = PublishWindow.activate(w, retry)
      {:ok, w} = PublishWindow.settle(w, retry, @primary, self())
      assert %{outstanding_frames: 0, available_frames: 1} = accounting(w)
      assert {:ok, _w, _b} = PublishWindow.admit(w, k(2), 50, 900, self(), newgen)
      # NOT VACUOUS: res_a's token is dead, so the fenced attempt cannot also settle.
      assert {:error, :not_outstanding} = PublishWindow.settle(w, res_a, @primary, self())
    end

    test "the BYTE twin: a fenced generation frees no bytes either" do
      # Same property on the other bound. A frame-only assertion would pass while byte credits
      # leaked, and the byte grant is what actually bounds a large record.
      w = window(4, 100)
      {w, _res} = admit_active!(w, k(1), 80, 500)
      assert %{outstanding_bytes: 80, available_bytes: 20} = accounting(w)

      {:ok, w, 1} = PublishWindow.fence_generation(w, gen())

      assert %{outstanding_bytes: 80, available_bytes: 20} = accounting(w),
             "fencing released byte credits for a record that may already be at the broker"

      assert {:error, :byte_credits_exhausted} =
               PublishWindow.admit(w, k(2), 80, 900, self(), make_ref())
    end

    test "fencing touches ONLY its own generation" do
      # A replacement transport's attempts must survive the fencing of the one it replaced,
      # which is why the generation is recorded per attempt rather than as one current value.
      old_gen = gen()
      new_gen = make_ref()

      w = window(4, 1000)
      {w, _old} = admit_active!(w, k(1), 50, 500)

      {:ok, w, res_new} = PublishWindow.admit(w, k(2), 50, 500, self(), new_gen)
      {:ok, w} = PublishWindow.activate(w, res_new)

      {:ok, w, fenced} = PublishWindow.fence_generation(w, old_gen)
      assert fenced === 1, "fencing crossed into another generation"

      # The new generation's attempt is untouched: still live, still settleable by its owner.
      assert PublishWindow.reservation(w, k(2)) === {:ok, res_new}
      assert {:ok, _w} = PublishWindow.settle(w, res_new, @primary, self())

      # The old one is idle-but-charged: no live attempt, credits still held.
      assert PublishWindow.reservation(w, k(1)) === :error
      assert PublishWindow.outstanding?(w, k(1))
    end

    test "a PENDING attempt on the dead generation is fenced too" do
      # Its caller never took delivery and its transport is gone, so it will issue nothing. Left
      # pending it would hold the slot against a retry forever, because only that caller could
      # revoke it and it is about to receive an error instead.
      w = window(1, 100)
      {:ok, w, _pending} = PublishWindow.admit(w, k(1), 50, 500, self(), gen())

      {:ok, w, fenced} = PublishWindow.fence_generation(w, gen())
      assert fenced === 1

      assert PublishWindow.outstanding?(w, k(1)), "the reservation was released, not fenced"
      assert {:ok, _w, _retry} = PublishWindow.admit(w, k(1), 50, 900, self(), make_ref())
    end

    test "fencing a generation with nothing on it is a no-op, and says so" do
      w = window(2, 200)
      {w, _res} = admit_active!(w, k(1), 50, 500)
      before = accounting(w)

      {:ok, w, fenced} = PublishWindow.fence_generation(w, make_ref())

      assert fenced === 0
      assert accounting(w) === before
    end

    test "live_generations/1 reports what is actually in flight" do
      other = make_ref()
      w = window(4, 1000)
      {w, _a} = admit_active!(w, k(1), 10, 500)
      {:ok, w, r2} = PublishWindow.admit(w, k(2), 10, 500, self(), other)
      {:ok, w} = PublishWindow.activate(w, r2)

      assert Enum.sort(PublishWindow.live_generations(w)) === Enum.sort([gen(), other])

      # An idle-but-charged reservation has NO generation: it is owed a republish, not tied to a
      # transport. That is what keeps the metadata bounded after a fence.
      {:ok, w, 1} = PublishWindow.fence_generation(w, gen())
      assert PublishWindow.live_generations(w) === [other]
    end

    test "admit REFUSES a generation that is not a reference" do
      w = window(1, 100)
      assert {:error, :generation} = PublishWindow.admit(w, k(1), 50, 500, self(), nil)
      assert {:error, :generation} = PublishWindow.admit(w, k(1), 50, 500, self(), :current)
      assert {:ok, _w, _r} = PublishWindow.admit(w, k(1), 50, 500, self(), make_ref())
    end
  end
end
