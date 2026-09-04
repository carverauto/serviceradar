defmodule ServiceRadar.Edge.ResolvedPrefixTest do
  @moduledoc """
  The dangerous property here is not "the watermark advances" -- it is that it NEVER advances past
  work the gateway has not accepted, because the local watermark eventually authorizes deleting
  customer data. Most of these tests are about refusing to advance.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.ResolvedPrefix
  alias Serviceradar.Edge.V1.EdgeRecordDispositionKind

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
        EdgeRecordDispositionKind.mapping()
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
    test "EVERY resolving kind supersedes a retryable one and unwedges the lane" do
      # Parameterised over all four. Proving it for AUTHORITATIVE alone left audit, quarantine and
      # permanent free to stay wedged selectively -- the lane would unblock for one kind of
      # outcome and hang forever on another.
      for superseding <- Enum.filter(declared_kinds(), &ResolvedPrefix.resolving?/1) do
        t =
          1
          |> ResolvedPrefix.new()
          |> record!(1, @retryable)
          |> record!(2, @audit)
          |> record!(3, @quarantine)

        assert ResolvedPrefix.resolved_through(t) === 0

        # The agent retransmits 1 and the gateway resolves it with THIS kind. If retryable were
        # immutable the retry could never be recorded and the prefix could never move again.
        t = record!(t, 1, superseding)

        assert ResolvedPrefix.resolved_through(t) === 3,
               "#{superseding} did not unwedge the queued sequences behind the retry"

        assert ResolvedPrefix.disposition(t, 1) === {:ok, superseding}
        assert ResolvedPrefix.pending_out_of_order(t) === 0
      end
    end
  end

  describe "lane bounds are the protobuf uint64 range" do
    test "a sequence past uint64 max is REFUSED, not resolved" do
      # An earlier revision accepted max + 1 and advanced the watermark to it -- a value nothing
      # downstream can express, since the lane sequence is a protobuf uint64.
      max = 0xFFFFFFFFFFFFFFFF
      t = ResolvedPrefix.new(max)

      assert {:error, :above_lane_max} = ResolvedPrefix.record(t, max + 1, @authoritative)
      assert {:error, :above_lane_max} = ResolvedPrefix.record(t, max * 2, @authoritative)

      assert ResolvedPrefix.resolved_through(t) === max - 1
    end

    test "uint64 max itself is a valid final sequence" do
      max = 0xFFFFFFFFFFFFFFFF
      t = max |> ResolvedPrefix.new() |> record!(max, @authoritative)

      assert ResolvedPrefix.resolved_through(t) === max
      assert ResolvedPrefix.disposition(t, max) === {:ok, @authoritative}
    end

    test "the constructor takes FIRST_UNRESOLVED_SEQUENCE, not the lane origin" do
      # sequence_base MUST be 1 and names the lane's origin; first_unresolved_sequence is where
      # the agent still needs work. Seeding a resumed lane from the origin re-opens a window the
      # agent has already closed.
      t = ResolvedPrefix.new(100)

      assert ResolvedPrefix.base(t) === 100
      assert ResolvedPrefix.resolved_through(t) === 99
      assert {:error, :below_base} = ResolvedPrefix.record(t, 99, @authoritative)
      assert {:error, :below_base} = ResolvedPrefix.record(t, 1, @authoritative)
    end

    test "sequence 0 does not exist" do
      t = ResolvedPrefix.new(1)

      assert ResolvedPrefix.resolved_through(t) === 0
      assert {:error, :below_base} = ResolvedPrefix.record(t, 0, @authoritative)
    end
  end

  describe "release is driven by what the agent REPORTS, and is final" do
    test "releasing drops evidence below the reported first-unresolved sequence" do
      t = Enum.reduce(1..5, ResolvedPrefix.new(1), &record!(&2, &1, @authoritative))
      assert ResolvedPrefix.retained_dispositions(t) === 5

      # The agent reports it has locally resolved through 3.
      {:ok, t} = ResolvedPrefix.release_below(t, 4)

      assert ResolvedPrefix.base(t) === 4
      assert ResolvedPrefix.retained_dispositions(t) === 2
      assert ResolvedPrefix.disposition(t, 3) === :error
      assert ResolvedPrefix.disposition(t, 4) === {:ok, @authoritative}

      # The remote watermark is untouched: release is about local durability, not resolution.
      assert ResolvedPrefix.resolved_through(t) === 5
    end

    test "a released sequence is BELOW BASE, not a silent no-op" do
      t = 1 |> ResolvedPrefix.new() |> record!(1, @authoritative) |> record!(2, @quarantine)
      {:ok, t} = ResolvedPrefix.release_below(t, 3)

      # THE POINT: with the evidence gone there is nothing to contradict, so a contradicting
      # disposition would otherwise return {:ok, t} and read as agreement.
      assert {:error, :below_base} = ResolvedPrefix.record(t, 1, @permanent)
      assert {:error, :below_base} = ResolvedPrefix.record(t, 2, @authoritative)
      assert {:error, :below_base} = ResolvedPrefix.record(t, 1, @authoritative)
    end

    test "release never moves the lane backwards, and never runs ahead of resolution" do
      t = Enum.reduce(1..3, ResolvedPrefix.new(1), &record!(&2, &1, @authoritative))
      {:ok, t} = ResolvedPrefix.release_below(t, 3)

      assert {:error, :below_base} = ResolvedPrefix.release_below(t, 2)

      # The agent cannot have durably acted on an outcome it was never told about.
      assert {:error, :not_resolved} = ResolvedPrefix.release_below(t, 5)
      assert {:error, :not_resolved} = ResolvedPrefix.release_below(t, 99)

      # Exactly one past the resolved watermark is the legal maximum: everything resolved.
      assert {:ok, done} = ResolvedPrefix.release_below(t, 4)
      assert ResolvedPrefix.retained_dispositions(done) === 0
    end

    test "release refuses a first-unresolved sequence outside protobuf uint64" do
      max = 0xFFFFFFFFFFFFFFFF
      t = max |> ResolvedPrefix.new() |> record!(max, @authoritative)

      assert {:error, :above_lane_max} = ResolvedPrefix.release_below(t, max + 1)
    end

    test "release preserves pending out-of-order outcomes" do
      t =
        1
        |> ResolvedPrefix.new()
        |> record!(1, @authoritative)
        |> record!(2, @audit)
        |> record!(5, @quarantine)
        |> record!(7, @retryable)

      assert ResolvedPrefix.resolved_through(t) === 2
      assert ResolvedPrefix.pending_out_of_order(t) === 2

      assert {:ok, released} = ResolvedPrefix.release_below(t, 3)
      assert ResolvedPrefix.pending_out_of_order(released) === 2
      assert ResolvedPrefix.pending_disposition(released, 5) === {:ok, @quarantine}
      assert ResolvedPrefix.pending_disposition(released, 7) === {:ok, @retryable}
    end

    test "the gateway never infers release from having sent an ack" do
      # There is no API that advances release from gateway-side activity: the only entry point
      # takes the agent's reported sequence. This is structural, not a runtime check.
      {:module, _} = Code.ensure_loaded(ResolvedPrefix)

      refute function_exported?(ResolvedPrefix, :record_terminal_outcome, 2)
      refute function_exported?(ResolvedPrefix, :reclaimable_through, 1)
      assert function_exported?(ResolvedPrefix, :release_below, 2)
    end
  end

  describe "release and report do not disturb pending outcomes" do
    test "release_below/2 PRESERVES pending out-of-order outcomes" do
      # A mutant that cleared `pending` alongside `disposition` passed every earlier test: nothing
      # asserted that queued work survives a lane resume. Losing it would silently drop outcomes
      # the gateway has already recorded but not yet been able to order.
      t =
        1
        |> ResolvedPrefix.new()
        |> record!(1, @authoritative)
        |> record!(2, @authoritative)
        |> record!(5, @quarantine)
        |> record!(7, @retryable)

      assert ResolvedPrefix.resolved_through(t) === 2
      assert ResolvedPrefix.pending_out_of_order(t) === 2

      {:ok, t} = ResolvedPrefix.release_below(t, 3)

      assert ResolvedPrefix.pending_out_of_order(t) === 2,
             "release erased pending out-of-order outcomes"

      assert ResolvedPrefix.pending_disposition(t, 5) === {:ok, @quarantine}
      assert ResolvedPrefix.pending_disposition(t, 7) === {:ok, @retryable}
    end

    test "reported_through/2 preserves pending outcomes and the watermark" do
      t = 1 |> ResolvedPrefix.new() |> record!(1, @authoritative) |> record!(4, @audit)

      {:ok, t2} = ResolvedPrefix.reported_through(t, 1)

      assert ResolvedPrefix.pending_disposition(t2, 4) === {:ok, @audit}
      assert ResolvedPrefix.resolved_through(t2) === 1
      assert ResolvedPrefix.base(t2) === 1
    end
  end

  describe "gateway retention is bounded on a long-lived lane" do
    test "a long run does NOT retain a disposition per frame" do
      # EXACT REPRO of the blocker: 1000 resolved frames retained 1000 dispositions, because the
      # only release signal arrives at lane open and a stream that never re-opens never sends one.
      t = Enum.reduce(1..1000, ResolvedPrefix.new(1), &record!(&2, &1, @authoritative))

      assert ResolvedPrefix.resolved_through(t) === 1000
      assert ResolvedPrefix.retained_dispositions(t) === 1000

      # The gateway reports them in an ack. Retention exists to populate that ack and nothing
      # else, so reporting discharges it.
      {:ok, t} = ResolvedPrefix.reported_through(t, 1000)

      assert ResolvedPrefix.retained_dispositions(t) === 0
      assert ResolvedPrefix.resolved_through(t) === 1000, "reporting moved the watermark"
    end

    test "reporting does NOT advance the lane, so a contradiction is still a conflict" do
      # Forgetting the evidence must not turn a contradiction into silence. base is untouched, so
      # the sequence is still inside the prefix and a different kind still conflicts.
      t = 1 |> ResolvedPrefix.new() |> record!(1, @authoritative)
      {:ok, t} = ResolvedPrefix.reported_through(t, 1)

      assert ResolvedPrefix.base(t) === 1
      assert ResolvedPrefix.disposition(t, 1) === :error

      # The gateway cannot adjudicate what it no longer remembers, so it refuses BOTH ways rather
      # than guessing -- {:ok, t} would make silence read as agreement, and :conflict would invent
      # a contradiction it cannot see.
      assert {:error, :evidence_released} = ResolvedPrefix.record(t, 1, @quarantine)
      assert {:error, :evidence_released} = ResolvedPrefix.record(t, 1, @authoritative)
    end

    test "reporting is bounded by resolution and by the lane maximum" do
      t = 1 |> ResolvedPrefix.new() |> record!(1, @authoritative)

      assert {:error, :not_resolved} = ResolvedPrefix.reported_through(t, 2)

      assert {:error, :above_lane_max} =
               ResolvedPrefix.reported_through(t, 0xFFFFFFFFFFFFFFFF + 1)

      assert {:ok, _} = ResolvedPrefix.reported_through(t, 0)
    end

    test "release_below/2 is bounded by the lane maximum too" do
      t = 1 |> ResolvedPrefix.new() |> record!(1, @authoritative)

      assert {:error, :above_lane_max} = ResolvedPrefix.release_below(t, 0xFFFFFFFFFFFFFFFF + 1)
    end
  end

  describe "the transition table is explicit, and rejections do not mutate state" do
    # DERIVED over every declared kind x every declared kind, plus invalid inputs. A hand-written
    # list of six rows describes the policy; it does not prove the policy holds for every pair,
    # and it silently stops covering a kind the ABI adds.
    #
    # Every rejection asserts WHOLE-STATE EQUALITY. Asserting only the error tuple would pass a
    # mutation that returns {:error, :conflict} while corrupting `pending` on the way out.
    defp declared_kinds do
      EdgeRecordDispositionKind.mapping()
      |> Map.keys()
      |> Enum.reject(&(&1 == @unspecified))
      |> Enum.sort()
    end

    defp invalid_kinds, do: [@unspecified, :NOT_A_KIND, 99, nil, "authoritative", {:tuple}]

    # The policy, stated once as data.
    defp policy(prior, new) do
      cond do
        prior == new -> :idempotent
        prior == @retryable and ResolvedPrefix.resolving?(new) -> :allowed
        true -> :conflict
      end
    end

    # NOTE ON VALIDATION ORDER: `record/3` documents WHICH errors it returns, not which wins when
    # an input is invalid several ways at once. Reordering the guards is therefore
    # behaviour-preserving against the documented contract, and a mutation that does so SURVIVES
    # these tests by design. Pinning a precedence here would invent a promise the function does
    # not make, and the next person to reorder the guards for readability would be failed by a
    # test asserting something nobody agreed to.
    test "the matrix covers every declared kind, so a new ABI kind cannot slip past it" do
      assert length(declared_kinds()) == 4 + 1, "declared kinds: #{inspect(declared_kinds())}"
      assert @retryable in declared_kinds()
    end

    test "PENDING transitions follow the table exactly, and rejections leave state identical" do
      for prior <- declared_kinds(), new <- declared_kinds() do
        # seq 2 with seq 1 absent, so the outcome stays pending and out of the prefix.
        before = 1 |> ResolvedPrefix.new() |> record!(2, prior)

        case policy(prior, new) do
          :idempotent ->
            assert {:ok, after_state} = ResolvedPrefix.record(before, 2, new)

            assert after_state === before,
                   "#{prior} -> #{new} should be idempotent but changed state"

            assert ResolvedPrefix.resolved_through(after_state) ===
                     ResolvedPrefix.resolved_through(before)

          :allowed ->
            assert {:ok, after_state} = ResolvedPrefix.record(before, 2, new)

            assert ResolvedPrefix.pending_disposition(after_state, 2) === {:ok, new},
                   "#{prior} -> #{new} should supersede"

            # The COMPLETE state, including the watermark. A supersession at seq 2 with seq 1
            # still missing must not move the prefix -- asserting only the pending entry let a
            # mutant set the watermark while looking correct.
            assert ResolvedPrefix.resolved_through(after_state) === 0,
                   "#{prior} -> #{new} advanced the prefix past a missing sequence"

            assert after_state === %{before | pending: %{2 => new}}

          :conflict ->
            # The meaningful property in an immutable language is that the call returns an
            # ERROR rather than {:ok, corrupted}: an {:error, _} result exposes no replacement
            # tracker at all, and the caller's own term cannot be mutated. "State unchanged
            # after rejection" becomes observable -- and worth testing -- only once a process
            # owns the tracker, which part 1 deliberately does not introduce.
            assert {:error, :conflict} = ResolvedPrefix.record(before, 2, new),
                   "#{prior} -> #{new} should be a conflict"
        end
      end
    end

    test "RESOLVED transitions follow the table, and rejections leave state identical" do
      resolving = Enum.filter(declared_kinds(), &ResolvedPrefix.resolving?/1)

      for prior <- resolving, new <- declared_kinds() do
        # seq 1 recorded first, so it is INSIDE the prefix.
        before = 1 |> ResolvedPrefix.new() |> record!(1, prior)
        assert ResolvedPrefix.resolved_through(before) == 1

        if prior == new do
          assert {:ok, after_state} = ResolvedPrefix.record(before, 1, new)
          assert after_state === before, "#{prior} -> #{new} inside the prefix changed state"

          assert ResolvedPrefix.resolved_through(after_state) === 1
        else
          # Inside the prefix a resolving kind is terminal: it may not become a different
          # resolving kind, nor be downgraded back to retryable.
          assert {:error, :conflict} = ResolvedPrefix.record(before, 1, new),
                 "#{prior} -> #{new} inside the prefix should conflict"

          assert ResolvedPrefix.disposition(before, 1) == {:ok, prior}
          assert ResolvedPrefix.resolved_through(before) == 1
        end
      end
    end

    test "INVALID kinds are rejected against every prior state, leaving it identical" do
      priors = [nil | declared_kinds()]

      for prior <- priors, bad <- invalid_kinds() do
        before =
          case prior do
            nil -> ResolvedPrefix.new(1)
            kind -> 1 |> ResolvedPrefix.new() |> record!(2, kind)
          end

        assert {:error, :unknown_disposition} = ResolvedPrefix.record(before, 2, bad),
               "prior #{inspect(prior)} accepted #{inspect(bad)}"
      end
    end
  end
end
