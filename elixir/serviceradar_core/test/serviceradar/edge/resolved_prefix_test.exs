defmodule ServiceRadar.Edge.ResolvedPrefixTest do
  @moduledoc """
  The dangerous property here is not "the watermark advances" -- it is that it NEVER advances past
  work the gateway has not accepted, because the local watermark eventually authorizes deleting
  customer data. Most of these tests are about refusing to advance.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.ResolvedPrefix

  @authoritative :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE
  @audit :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY
  @quarantine :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE
  @permanent :EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT
  @retryable :EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE
  @unspecified :EDGE_RECORD_DISPOSITION_KIND_UNSPECIFIED

  defp record!(t, seq, d) do
    {:ok, t} = ResolvedPrefix.record(t, seq, d)
    t
  end

  defp terminal!(t, seq) do
    {:ok, t} = ResolvedPrefix.record_terminal_outcome(t, seq)
    t
  end

  describe "the resolving set is exactly the four ABI kinds" do
    test "every resolving kind advances the prefix; retryable and unspecified do not" do
      for d <- [@authoritative, @audit, @quarantine, @permanent] do
        t = 1 |> ResolvedPrefix.new() |> record!(1, d)
        assert ResolvedPrefix.resolved_through(t) == 1, "#{d} did not resolve"
        assert ResolvedPrefix.resolving?(d)
      end

      t = 1 |> ResolvedPrefix.new() |> record!(1, @retryable)
      assert ResolvedPrefix.resolved_through(t) == 0
      refute ResolvedPrefix.resolving?(@retryable)
    end

    test "the resolving set is derived against the generated enum, not a local guess" do
      declared =
        Serviceradar.Edge.V1.EdgeRecordDispositionKind.mapping()
        |> Map.keys()
        |> Enum.reject(&(&1 == @unspecified))

      # Exactly one declared kind must be non-resolving. If the proto gains a kind, this fails
      # until someone decides -- deliberately -- whether it resolves.
      non_resolving = Enum.reject(declared, &ResolvedPrefix.resolving?/1)

      assert non_resolving == [@retryable],
             "non-resolving kinds are #{inspect(non_resolving)}; a new kind needs a decision"
    end

    test "unspecified and undeclared kinds fail closed" do
      t = ResolvedPrefix.new(1)

      assert {:error, :unknown_disposition} = ResolvedPrefix.record(t, 1, @unspecified)
      assert {:error, :unknown_disposition} = ResolvedPrefix.record(t, 1, :NOT_A_KIND)
      assert {:error, :unknown_disposition} = ResolvedPrefix.record(t, 1, 99)
      assert {:error, :unknown_disposition} = ResolvedPrefix.record(t, 1, nil)
    end
  end

  describe "the prefix is contiguous" do
    test "an out-of-order outcome does not advance past the gap" do
      t = 1 |> ResolvedPrefix.new() |> record!(3, @authoritative) |> record!(2, @authoritative)

      # 2 and 3 are recorded, but 1 is missing: the prefix has not moved at all.
      assert ResolvedPrefix.resolved_through(t) == 0
      assert ResolvedPrefix.pending_out_of_order(t) == 2

      t = record!(t, 1, @authoritative)

      # Filling the gap collapses the whole run at once.
      assert ResolvedPrefix.resolved_through(t) == 3
      assert ResolvedPrefix.pending_out_of_order(t) == 0
    end

    test "a RETRYABLE outcome caps the prefix exactly like a missing outcome" do
      t =
        1
        |> ResolvedPrefix.new()
        |> record!(1, @authoritative)
        |> record!(2, @retryable)
        |> record!(3, @authoritative)
        |> record!(4, @authoritative)

      # THE POINT: 3 and 4 are durably resolved, but the prefix stops at 1. Advancing to 4 would
      # eventually authorize reclaiming sequence 2, which the gateway never accepted.
      assert ResolvedPrefix.resolved_through(t) == 1
      assert ResolvedPrefix.pending_out_of_order(t) == 3
    end

    test "the prefix advancing does not erase WHAT happened" do
      t =
        1
        |> ResolvedPrefix.new()
        |> record!(1, @authoritative)
        |> record!(2, @quarantine)
        |> record!(3, @permanent)

      assert ResolvedPrefix.resolved_through(t) == 3

      # All five kinds stay distinguishable inside the prefix; collapsing them to "accepted"
      # would lose the difference between a primary write and a quarantine.
      assert ResolvedPrefix.disposition(t, 1) == {:ok, @authoritative}
      assert ResolvedPrefix.disposition(t, 2) == {:ok, @quarantine}
      assert ResolvedPrefix.disposition(t, 3) == {:ok, @permanent}
    end
  end

  describe "retryable is provisional, not a verdict" do
    test "a resolving kind SUPERSEDES a retryable one and unwedges the lane" do
      t =
        1
        |> ResolvedPrefix.new()
        |> record!(1, @retryable)
        |> record!(2, @authoritative)
        |> record!(3, @authoritative)

      assert ResolvedPrefix.resolved_through(t) == 0

      # The agent retransmits 1 and the gateway resolves it. If retryable were immutable the
      # retry could never be recorded and the prefix could never move again -- the lane would be
      # wedged forever.
      t = record!(t, 1, @authoritative)

      assert ResolvedPrefix.resolved_through(t) == 3,
             "the queued sequences behind the retry did not advance"
    end

    test "a resolving kind may NOT change to another resolving kind" do
      t = 1 |> ResolvedPrefix.new() |> record!(2, @authoritative)

      assert {:error, :conflict} = ResolvedPrefix.record(t, 2, @quarantine)
      assert {:error, :conflict} = ResolvedPrefix.record(t, 2, @permanent)
    end

    test "a resolving kind may NOT be downgraded back to retryable" do
      t = 1 |> ResolvedPrefix.new() |> record!(2, @authoritative)
      assert {:error, :conflict} = ResolvedPrefix.record(t, 2, @retryable)
    end

    test "recording the same outcome twice is idempotent, inside and outside the prefix" do
      t = 1 |> ResolvedPrefix.new() |> record!(2, @retryable)
      assert {:ok, ^t} = ResolvedPrefix.record(t, 2, @retryable)

      t = 1 |> ResolvedPrefix.new() |> record!(1, @authoritative)
      assert {:ok, same} = ResolvedPrefix.record(t, 1, @authoritative)
      assert ResolvedPrefix.resolved_through(same) == 1
    end

    test "contradicting a sequence already inside the prefix is a conflict" do
      t = 1 |> ResolvedPrefix.new() |> record!(1, @authoritative)
      assert {:error, :conflict} = ResolvedPrefix.record(t, 1, @quarantine)
    end
  end

  describe "the two watermarks are separate" do
    test "a gateway resolution does NOT by itself reclaim anything" do
      t = 1 |> ResolvedPrefix.new() |> record!(1, @authoritative) |> record!(2, @authoritative)

      assert ResolvedPrefix.resolved_through(t) == 2

      # THE POINT: the remote prefix moved, but no local bytes may be released. Conflating these
      # would delete spool evidence on the strength of a PubAck alone.
      assert ResolvedPrefix.reclaimable_through(t) == 0
    end

    test "one local terminal event does not vouch for an earlier sequence" do
      t =
        1
        |> ResolvedPrefix.new()
        |> record!(1, @quarantine)
        |> record!(2, @authoritative)
        |> terminal!(2)

      # Sequence 1's local quarantine transaction is still pending, so the watermark stays below
      # it and its evidence is retained.
      assert ResolvedPrefix.reclaimable_through(t) == 0
      assert ResolvedPrefix.disposition(t, 1) == {:ok, @quarantine}

      t = terminal!(t, 1)

      # Now the whole contiguous run releases, and the released evidence is dropped.
      assert ResolvedPrefix.reclaimable_through(t) == 2
      assert ResolvedPrefix.disposition(t, 1) == :error
      assert ResolvedPrefix.disposition(t, 2) == :error
    end

    test "reclaim never exceeds resolution, and an unresolved sequence is refused" do
      t = 1 |> ResolvedPrefix.new() |> record!(1, @authoritative)

      assert {:error, :not_resolved} = ResolvedPrefix.record_terminal_outcome(t, 2)

      t = terminal!(t, 1)
      assert ResolvedPrefix.reclaimable_through(t) <= ResolvedPrefix.resolved_through(t)
    end

    test "recording a terminal outcome twice is idempotent" do
      t = 1 |> ResolvedPrefix.new() |> record!(1, @authoritative) |> terminal!(1)
      assert {:ok, same} = ResolvedPrefix.record_terminal_outcome(t, 1)
      assert ResolvedPrefix.reclaimable_through(same) == 1
    end

    test "a retryable cap holds the reclaim watermark down too" do
      t =
        1
        |> ResolvedPrefix.new()
        |> record!(1, @retryable)
        |> record!(2, @authoritative)

      # 2 is resolved remotely but sits behind the cap, so it is not inside the prefix and
      # cannot be reclaimed.
      assert {:error, :not_resolved} = ResolvedPrefix.record_terminal_outcome(t, 2)
      assert ResolvedPrefix.reclaimable_through(t) == 0
    end
  end

  describe "lane bounds" do
    test "a lane starting above 1 refuses anything below its base" do
      t = ResolvedPrefix.new(100)

      assert ResolvedPrefix.resolved_through(t) == 99
      assert {:error, :below_base} = ResolvedPrefix.record(t, 99, @authoritative)
      assert {:error, :below_base} = ResolvedPrefix.record_terminal_outcome(t, 99)

      t = record!(t, 100, @authoritative)
      assert ResolvedPrefix.resolved_through(t) == 100
    end

    test "sequence 0 does not exist, so a fresh lane reports nothing resolved" do
      t = ResolvedPrefix.new(1)

      # 0 rather than 1: "nothing resolved yet", not "sequence 0 resolved".
      assert ResolvedPrefix.resolved_through(t) == 0
      assert ResolvedPrefix.reclaimable_through(t) == 0
      assert {:error, :below_base} = ResolvedPrefix.record(t, 0, @authoritative)
    end

    test "u64 max is a valid final sequence and terminates" do
      # The Go implementation hung here with a `s <= seq` counter that wrapped. Termination is
      # decided by SET MEMBERSHIP instead, so the final sequence completes rather than looping.
      max = 0xFFFFFFFFFFFFFFFF
      t = max |> ResolvedPrefix.new() |> record!(max, @authoritative)

      assert ResolvedPrefix.resolved_through(t) == max

      t = terminal!(t, max)
      assert ResolvedPrefix.reclaimable_through(t) == max
      assert ResolvedPrefix.retained_dispositions(t) == 0
    end
  end

  describe "retained state is released, not accumulated" do
    test "evidence is dropped exactly as the reclaim watermark passes it" do
      t = Enum.reduce(1..10, ResolvedPrefix.new(1), &record!(&2, &1, @authoritative))

      assert ResolvedPrefix.resolved_through(t) == 10
      assert ResolvedPrefix.retained_dispositions(t) == 10

      t = Enum.reduce(1..7, t, &terminal!(&2, &1))

      assert ResolvedPrefix.reclaimable_through(t) == 7

      # NOT VACUOUS: an implementation that never released would report 10 here, and the tracker
      # would grow without bound over a long-lived lane.
      assert ResolvedPrefix.retained_dispositions(t) == 3
    end

    test "a long out-of-order burst collapses to no pending state once the gap fills" do
      t = Enum.reduce(2..50, ResolvedPrefix.new(1), &record!(&2, &1, @authoritative))

      assert ResolvedPrefix.pending_out_of_order(t) == 49
      assert ResolvedPrefix.resolved_through(t) == 0

      t = record!(t, 1, @authoritative)

      assert ResolvedPrefix.resolved_through(t) == 50
      assert ResolvedPrefix.pending_out_of_order(t) == 0
      assert ResolvedPrefix.pending_disposition(t, 25) == :error
    end
  end
end
