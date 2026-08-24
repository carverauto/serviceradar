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

  defp admit!(w, seq, bytes, deadline) do
    {:ok, w} = PublishWindow.admit(w, seq, bytes, deadline)
    w
  end

  describe "the grant is the bound" do
    test "credits come from the lane-open ack, and zero admits nothing" do
      # A grant of zero is a real answer, not a missing value to default away.
      {:ok, none} = PublishWindow.new(0, 0)

      assert PublishWindow.available_frames(none) === 0
      refute PublishWindow.admits?(none, 0)
      assert {:error, :frame_credits_exhausted} = PublishWindow.admit(none, 1, 0, 100)
    end

    test "credits outside their wire range are refused" do
      # granted_frame_credits is uint32, granted_byte_credits uint64: a larger value could not
      # have come from a lane-open ack, so accepting it would size a window from a number the
      # wire cannot carry.
      assert {:error, :frame_credits} = PublishWindow.new(0xFFFFFFFF + 1, 10)
      assert {:error, :byte_credits} = PublishWindow.new(1, 0xFFFFFFFFFFFFFFFF + 1)
      assert {:error, :frame_credits} = PublishWindow.new(-1, 10)
      assert {:error, :byte_credits} = PublishWindow.new(1, -1)

      # ...and the maxima themselves are legal.
      assert {:ok, _} = PublishWindow.new(0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF)
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
      {:ok, w} = PublishWindow.settle(w, 1)
      assert {:ok, w} = PublishWindow.admit(w, 5, 1, 500)
      assert {:error, :frame_credits_exhausted} = PublishWindow.admit(w, 6, 1, 500)
    end

    test "the BYTE grant is hard, and is charged by actual size" do
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
    @public_surface [
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
      {:settle, 2}
    ]

    test "the public surface is EXACTLY the classified inventory" do
      {:module, _} = Code.ensure_loaded(PublishWindow)

      actual = :functions |> PublishWindow.__info__() |> Enum.sort()

      added = actual -- @public_surface
      removed = @public_surface -- actual

      assert added === [],
             "new public function(s) #{inspect(added)}: classify whether they release credits, " <>
               "then add them here. settle/2 is the ONLY one that may."

      assert removed === [],
             "public function(s) #{inspect(removed)} disappeared; callers depend on this surface"
    end

    test "expired/2 is a pure report: the window is unchanged by asking" do
      w = admit!(window(), 1, 100, 100)

      assert PublishWindow.expired(w, 999) === [1]
      assert PublishWindow.expired(w, 999) === [1]
      assert PublishWindow.outstanding?(w, 1)
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

      {:ok, w} = PublishWindow.settle(w, 1)

      assert PublishWindow.outstanding_bytes(w) === 125
      assert PublishWindow.available_bytes(w) === 875
      refute PublishWindow.outstanding?(w, 1)
      assert PublishWindow.outstanding?(w, 2)
    end

    test "settling anything not outstanding is refused, not a silent no-op" do
      w = admit!(window(), 1, 100, 500)
      {:ok, settled} = PublishWindow.settle(w, 1)

      # Never admitted, and already settled, are BOTH :not_outstanding. Telling them apart would
      # require retaining every settled sequence forever, which is the growth this bounds.
      assert {:error, :not_outstanding} = PublishWindow.settle(w, 99)
      assert {:error, :not_outstanding} = PublishWindow.settle(settled, 1)
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

      {:ok, w} = PublishWindow.settle(w, 2)

      assert PublishWindow.outstanding_bytes(w) === 150,
             "settling frame 2 did not release exactly its 250 bytes"

      assert PublishWindow.outstanding_frames(w) === 2
      assert PublishWindow.outstanding?(w, 1)
      assert PublishWindow.outstanding?(w, 3)
      refute PublishWindow.outstanding?(w, 2)
    end

    test "a SECOND settlement releases nothing further" do
      w = 4 |> window(1000) |> admit!(1, 300, 500) |> admit!(2, 100, 500)
      {:ok, once} = PublishWindow.settle(w, 1)

      assert PublishWindow.outstanding_bytes(once) === 100
      assert PublishWindow.available_bytes(once) === 900

      assert {:error, :not_outstanding} = PublishWindow.settle(once, 1)

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
      {:ok, w} = PublishWindow.settle(w, 2)

      assert PublishWindow.available_frames(w) === 1
      assert PublishWindow.available_bytes(w) === 100
      assert {:ok, w} = PublishWindow.admit(w, 4, 100, 1_000)
      assert {:error, :frame_credits_exhausted} = PublishWindow.admit(w, 5, 1, 1_000)
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
          {:ok, acc} = PublishWindow.settle(acc, seq)
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
          {:ok, acc} = PublishWindow.settle(acc, seq)
          acc
        end)

      assert settled === start
    end

    test "outstanding bytes never exceed the grant across an interleaved run" do
      ops = [
        {:admit, 1, 300},
        {:admit, 2, 300},
        {:settle, 1, 0},
        {:admit, 3, 300},
        {:admit, 4, 300},
        {:settle, 2, 0},
        {:settle, 3, 0},
        {:admit, 5, 300},
        {:settle, 4, 0},
        {:settle, 5, 0}
      ]

      final =
        ops
        |> Enum.reduce(window(2, 700), fn
          {:admit, seq, bytes}, w ->
            case PublishWindow.admit(w, seq, bytes, 500) do
              {:ok, w2} -> w2
              {:error, _} -> w
            end

          {:settle, seq, _}, w ->
            case PublishWindow.settle(w, seq) do
              {:ok, w2} -> w2
              {:error, _} -> w
            end
        end)
        |> tap(fn w ->
          assert PublishWindow.outstanding_bytes(w) <= 700
          assert PublishWindow.outstanding_frames(w) <= 2
        end)

      # NOT VACUOUS: a window that admitted nothing would satisfy the bounds trivially, so the
      # run must actually have cycled work through.
      assert PublishWindow.outstanding_frames(final) === 0
      assert final === window(2, 700)
    end
  end
end
