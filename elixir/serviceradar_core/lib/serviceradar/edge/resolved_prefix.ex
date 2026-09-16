defmodule ServiceRadar.Edge.ResolvedPrefix do
  @moduledoc """
  The GATEWAY's contiguous resolved-prefix tracker (unify-sweep-results-proto task 3.5, consumed
  by 3.3(c)'s out-of-order PubAck accounting).

  Frames publish asynchronously and earn their durable outcome OUT OF ORDER. This advances the
  resolved watermark across a contiguous run of RESOLVING dispositions, so the gateway can report
  a prefix the agent may act on without claiming anything about the sequences behind a gap.

  Pure data and functions: no I/O, no process. Not safe for concurrent use -- the process that
  owns the lane owns the term.

  Dispositions are RECOVERABLE, not merely remembered: a resumed lane rebuilds them from the
  durable stream and DLQ. That is what makes bounded retention safe -- forgetting a reported
  disposition loses nothing that cannot be recomputed.

  ## It holds GATEWAY state only

  An earlier revision also tracked an agent-local "reclaimable" watermark, advanced by a
  `record_terminal_outcome/2` the gateway could never call. That was a design error, not a missing
  feature: local durability is the AGENT's fact, and the gateway has no way to observe it. The
  consequences were real -- every resolved disposition was retained forever, and the only way to
  make the watermark move would have been to equate sending an ack with the agent having durably
  acted on it, which is exactly the false equivalence the two-watermark split existed to prevent.

  Reclaim therefore belongs to the AGENT, and this module keeps only what the gateway can see.

  OWED, NOT DONE: the agent-side reclaim tracker does not exist yet. Saying "reclaim lives with
  the agent" describes where it BELONGS, not something already implemented -- the Go agent still
  has no counterpart, and nothing in this repository advances a reclaim watermark today. Removing
  it from here was necessary because it was unreachable, but it leaves that work outstanding
  rather than relocated.

  ## Release is driven by what the agent REPORTS

  The gateway learns the agent's local progress from `EdgeRecordLaneOpen.first_unresolved_sequence`
  on open and resume. `release_below/2` takes that value and drops the evidence beneath it. That is
  an observation, not an inference: the agent is telling the gateway how far it has resolved
  locally.

  Releasing also advances `base`, so a released sequence is genuinely out of range. Recording one
  afterwards fails closed with `:below_base` rather than silently succeeding as a no-op -- a
  released sequence has no retained disposition to contradict, so "no conflict found" would
  otherwise read as agreement.

  ## Dispositions are the frozen ABI, not a local approximation

  Outcomes are `EdgeRecordDispositionKind` values used DIRECTLY. There is no local
  accepted/rejected boolean, because the ABI distinguishes five kinds whose meanings are not
  interchangeable:

      ACCEPTED_AUTHORITATIVE (1)  primary stream      resolves
      ACCEPTED_AUDIT_ONLY    (2)  audit stream        resolves
      ACCEPTED_QUARANTINE    (3)  quarantine DLQ      resolves
      REJECTED_PERMANENT     (4)  reject-audit DLQ    resolves
      REJECTED_RETRYABLE     (5)  transient           NEVER resolves

  Task 3.5 lists the resolving PubAcks exhaustively, including the SECURITY-quarantine one, which
  collapses onto `ACCEPTED_QUARANTINE` on the wire. Both quarantine variants therefore resolve
  here; the security-quarantine ROUTING path is preserved elsewhere, since the wire disposition
  alone cannot express it.

  A `REJECTED_RETRYABLE` refusal is transient, so treating it as resolved would let the prefix
  advance past work the gateway has not accepted, and would eventually authorize reclaiming
  customer data that was never delivered. Retryable therefore CAPS the prefix, exactly like a
  missing outcome. Unspecified and undeclared kinds fail closed.

  ## The Go `gwprefix` is retained deliberately

  It has no Go consumers -- the gateway is Elixir -- but it is kept as a COMPARISON ORACLE until
  this port is integrated and verified. Removing it is a focused follow-up once that is done, not
  part of introducing this.
  """

  alias Serviceradar.Edge.V1.EdgeRecordDispositionKind

  @resolving [
    :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE,
    :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY,
    :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE,
    :EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT
  ]

  @retryable :EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE
  @unspecified :EDGE_RECORD_DISPOSITION_KIND_UNSPECIFIED

  @u64_max 0xFFFFFFFFFFFFFFFF

  @enforce_keys [:base, :resolved, :pending, :disposition]
  defstruct [:base, :resolved, :pending, :disposition]

  @opaque t :: %__MODULE__{
            base: pos_integer(),
            resolved: non_neg_integer(),
            pending: %{optional(pos_integer()) => atom()},
            disposition: %{optional(pos_integer()) => atom()}
          }

  @doc """
  A tracker for a lane whose first UNRESOLVED sequence is `first_unresolved_sequence`.

  This is `EdgeRecordLaneOpen.first_unresolved_sequence`, NOT `sequence_base`. The two are
  different facts and only coincide on a fresh lane: `sequence_base` MUST be 1 and names the
  lane's origin, while `first_unresolved_sequence` is where the agent still needs work. Seeding a
  resumed lane from the origin would re-open a window the agent has already closed.

  `resolved` starts at `first_unresolved_sequence - 1`, meaning "nothing resolved yet" rather than
  "sequence 0 resolved" -- lanes are 1-based and sequence 0 does not exist.
  """
  @spec new(pos_integer()) :: t()
  def new(first_unresolved_sequence \\ 1)

  def new(first_unresolved_sequence)
      when is_integer(first_unresolved_sequence) and first_unresolved_sequence >= 1 and
             first_unresolved_sequence <= @u64_max do
    %__MODULE__{
      base: first_unresolved_sequence,
      resolved: first_unresolved_sequence - 1,
      pending: %{},
      disposition: %{}
    }
  end

  @doc """
  Records the gateway's disposition for one sequence and advances the prefix across
  newly-contiguous resolving outcomes.

  A `REJECTED_RETRYABLE` disposition is retained but never resolves, so it caps the prefix exactly
  like a missing outcome.

  Errors: `:unknown_disposition`, `:below_base`, `:above_lane_max`, `:conflict`,
  `:evidence_released`. Which one is
  returned when an input is invalid in several ways at once is UNSPECIFIED -- callers may branch
  on the reason but must not depend on a precedence between them.
  """
  @spec record(t(), pos_integer(), atom()) :: {:ok, t()} | {:error, atom()}
  def record(%__MODULE__{} = t, seq, disposition) do
    cond do
      not declared?(disposition) -> {:error, :unknown_disposition}
      not is_integer(seq) -> {:error, :below_base}
      seq < t.base -> {:error, :below_base}
      # A lane sequence is a protobuf uint64. Accepting more let the prefix advance past the
      # representable range while nothing downstream could express it.
      seq > @u64_max -> {:error, :above_lane_max}
      seq <= t.resolved -> record_inside_prefix(t, seq, disposition)
      true -> record_pending(t, seq, disposition)
    end
  end

  # Inside the prefix, a repeat either matches the retained kind or contradicts it.
  #
  # The third case is REPORTED-THEN-FORGOTTEN: `reported_through/2` drops evidence without
  # advancing the lane, so the sequence is still inside the prefix with nothing retained. The
  # gateway genuinely cannot adjudicate it -- it no longer knows what it decided -- so it says so
  # instead of guessing. Returning {:ok, t} would make silence read as agreement, which is the
  # hole `release_below/2` advancing base exists to close; returning :conflict would invent a
  # contradiction it cannot see. The caller rebuilds from the durable stream and DLQ if it needs
  # the answer.
  defp record_inside_prefix(t, seq, disposition) do
    case Map.fetch(t.disposition, seq) do
      {:ok, ^disposition} -> {:ok, t}
      {:ok, _other} -> {:error, :conflict}
      :error -> {:error, :evidence_released}
    end
  end

  defp record_pending(t, seq, disposition) do
    case Map.fetch(t.pending, seq) do
      {:ok, ^disposition} ->
        {:ok, t}

      # A RETRYABLE outcome is PROVISIONAL, not a verdict: it explicitly leaves the sequence
      # eligible for redelivery. When the agent retransmits and the gateway resolves it, that
      # resolving kind SUPERSEDES the provisional one and the prefix advances -- including across
      # sequences queued behind it. Treating retryable as immutable would wedge the lane forever:
      # the retry could never be recorded, so the prefix could never move again.
      {:ok, @retryable} ->
        if resolving?(disposition) do
          {:ok, advance_resolved(%{t | pending: Map.put(t.pending, seq, disposition)})}
        else
          {:error, :conflict}
        end

      # A RESOLVING kind is terminal: it may not change to a different resolving kind, nor be
      # downgraded back to retryable.
      {:ok, _other} ->
        {:error, :conflict}

      :error ->
        {:ok, advance_resolved(%{t | pending: Map.put(t.pending, seq, disposition)})}
    end
  end

  @doc """
  Releases evidence for every sequence below `first_unresolved_sequence`, as reported by the agent
  in a lane open or resume.

  This is the ONLY local-durability signal the gateway can observe. It never infers release from
  having sent an ack: transmitting a disposition says nothing about the agent having durably acted
  on it.

  `base` advances with it, so a released sequence is out of range and recording one afterwards
  fails with `:below_base` instead of succeeding as a silent no-op.

  Refuses a value that would move the lane BACKWARDS (`:below_base`), exceed the protobuf uint64
  lane range (`:above_lane_max`), or move past what the gateway has resolved (`:not_resolved`) --
  the agent cannot have durably acted on an outcome it was never told.
  """
  @spec release_below(t(), pos_integer()) :: {:ok, t()} | {:error, atom()}
  def release_below(%__MODULE__{} = t, first_unresolved_sequence) do
    cond do
      not is_integer(first_unresolved_sequence) ->
        {:error, :below_base}

      first_unresolved_sequence < t.base ->
        {:error, :below_base}

      first_unresolved_sequence > @u64_max ->
        {:error, :above_lane_max}

      first_unresolved_sequence > t.resolved + 1 ->
        {:error, :not_resolved}

      true ->
        {:ok,
         %{
           t
           | base: first_unresolved_sequence,
             disposition:
               Map.reject(t.disposition, fn {seq, _} -> seq < first_unresolved_sequence end)
         }}
    end
  end

  @doc """
  Drops retained dispositions the gateway has already REPORTED in an `EdgeDeliveryAckV1`.

  Retention exists for one purpose: populating the next ack. Once the dispositions for a run have
  been reported, the gateway does not need them again, and holding them turns a long-lived lane
  into unbounded growth -- 1000 resolved frames retained 1000 dispositions, because the only other
  release signal arrives at lane open and a stream that never re-opens never sends one.

  THIS IS NOT A DURABILITY CLAIM, and the distinction matters because the opposite mistake was the
  last one. It does NOT advance any reclaim watermark, does NOT authorize the agent to release
  spool bytes, and says nothing about the agent having acted. It bounds the GATEWAY's own memory
  only. Recovery does not depend on this retention: a resumed lane rebuilds its dispositions from
  the durable stream and DLQ, which is where they actually live.

  `base` is untouched, so a reported sequence stays inside the prefix. Re-recording one afterwards
  returns `:evidence_released`: the gateway no longer knows what it decided, so it refuses to
  adjudicate rather than letting silence read as agreement. That is why this is separate from
  `release_below/2`, which advances the lane and is driven by the agent.

  Refuses a sequence past the resolved watermark (`:not_resolved`) or past the lane maximum
  (`:above_lane_max`); a value below the current base is accepted as a no-op.
  """
  @spec reported_through(t(), non_neg_integer()) :: {:ok, t()} | {:error, atom()}
  def reported_through(%__MODULE__{} = t, seq) do
    cond do
      not is_integer(seq) -> {:error, :not_resolved}
      seq > @u64_max -> {:error, :above_lane_max}
      seq > t.resolved -> {:error, :not_resolved}
      true -> {:ok, %{t | disposition: Map.reject(t.disposition, fn {s, _} -> s <= seq end)}}
    end
  end

  @doc "The contiguous resolved watermark. Stops at a gap OR at a retryable outcome."
  @spec resolved_through(t()) :: non_neg_integer()
  def resolved_through(%__MODULE__{resolved: r}), do: r

  @doc "The lane's first unresolved sequence, as last reported by the agent."
  @spec base(t()) :: pos_integer()
  def base(%__MODULE__{base: b}), do: b

  @doc "The frozen outcome kind of a resolved, not-yet-released sequence."
  @spec disposition(t(), pos_integer()) :: {:ok, atom()} | :error
  def disposition(%__MODULE__{} = t, seq), do: Map.fetch(t.disposition, seq)

  @doc "The recorded outcome of a sequence still outside the prefix."
  @spec pending_disposition(t(), pos_integer()) :: {:ok, atom()} | :error
  def pending_disposition(%__MODULE__{} = t, seq), do: Map.fetch(t.pending, seq)

  @doc "How many outcomes are recorded but not yet inside the prefix."
  @spec pending_out_of_order(t()) :: non_neg_integer()
  def pending_out_of_order(%__MODULE__{pending: p}), do: map_size(p)

  @doc "How many resolved-but-not-released dispositions are retained."
  @spec retained_dispositions(t()) :: non_neg_integer()
  def retained_dispositions(%__MODULE__{disposition: d}), do: map_size(d)

  @doc "Whether a disposition kind resolves its sequence."
  @spec resolving?(atom()) :: boolean()
  def resolving?(disposition), do: disposition in @resolving

  # A non-zero member of the GENERATED descriptor. Checked against the enum mapping rather than a
  # local list, so a kind added to the proto is recognised through regeneration, and an undeclared
  # value can never be mistaken for one.
  defp declared?(disposition) when is_atom(disposition) and disposition != @unspecified do
    Map.has_key?(EdgeRecordDispositionKind.mapping(), disposition)
  end

  defp declared?(_), do: false

  # Walks the contiguous run of RESOLVING dispositions, stopping at the first gap or retryable.
  defp advance_resolved(t) do
    next = t.resolved + 1

    case Map.fetch(t.pending, next) do
      {:ok, d} ->
        if resolving?(d) do
          advance_resolved(%{
            t
            | pending: Map.delete(t.pending, next),
              # Retain the kind: the prefix advancing must not erase WHAT happened.
              disposition: Map.put(t.disposition, next, d),
              resolved: next
          })
        else
          t
        end

      :error ->
        t
    end
  end
end
