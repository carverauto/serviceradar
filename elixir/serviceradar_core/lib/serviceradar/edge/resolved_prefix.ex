defmodule ServiceRadar.Edge.ResolvedPrefix do
  @moduledoc """
  The gateway-side contiguous resolved-prefix tracker (unify-sweep-results-proto task 3.3(c)).

  Frames publish asynchronously and may earn their durable outcome OUT OF ORDER. This advances
  the resolved watermark across a contiguous run of RESOLVING dispositions, so the gateway can
  report a prefix the agent may act on without claiming anything about the sequences behind a gap.

  It holds no I/O and can be rebuilt from the durable stream/DLQ. Not safe for concurrent use --
  wrap it in the process that owns the lane.

  ## Elixir, because the gateway is Elixir

  A Go `gwprefix` package exists in this repo with the same semantics and ZERO consumers: the
  agent-gateway has been Elixir for over a year and the consumers are Elixir
  (EventWriter / core-elx / Broadway), so nothing Go was ever going to call it. This is the
  implementation the gateway can actually use. The Go one should be deleted rather than kept in
  parallel -- two implementations of a watermark that authorizes deleting customer data is a
  drift risk with no upside, and there are no shared vectors binding them.

  ## Dispositions are the frozen ABI, not a local approximation

  Outcomes are `EdgeRecordDispositionKind` values used DIRECTLY. There is no local
  accepted/rejected boolean, because the ABI distinguishes five kinds whose meanings are not
  interchangeable:

      ACCEPTED_AUTHORITATIVE (1)  primary stream      resolves
      ACCEPTED_AUDIT_ONLY    (2)  audit stream        resolves
      ACCEPTED_QUARANTINE    (3)  quarantine DLQ      resolves
      REJECTED_PERMANENT     (4)  reject-audit DLQ    resolves
      REJECTED_RETRYABLE     (5)  transient           NEVER resolves

  Collapsing them is actively dangerous. A `REJECTED_RETRYABLE` refusal is transient, so treating
  it as resolved would let the prefix advance past work the gateway has not accepted, and would
  eventually authorize reclaiming customer data that was never delivered. Retryable therefore
  CAPS the prefix, exactly like a missing outcome.

  Unspecified and undeclared kinds fail closed.

  ## Two watermarks, deliberately separate

  Remote resolution and local reclaim are distinct facts:

    * `resolved_through/1` is what the GATEWAY durably resolved. It says nothing about local
      spool bytes.
    * `reclaimable_through/1` is the contiguous run for which the AGENT has durably recorded its
      OWN terminal action. Only this authorizes releasing bytes.

  A gateway PubAck does not by itself reclaim anything, and one local terminal event does not
  vouch for an earlier sequence: each advances the local watermark only after ITS OWN action is
  recorded.
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

  @enforce_keys [:base, :resolved, :reclaimable, :pending, :disposition, :local_terminal]
  defstruct [:base, :resolved, :reclaimable, :pending, :disposition, :local_terminal]

  @opaque t :: %__MODULE__{
            base: pos_integer(),
            resolved: non_neg_integer(),
            reclaimable: non_neg_integer(),
            pending: %{optional(non_neg_integer()) => atom()},
            disposition: %{optional(non_neg_integer()) => atom()},
            local_terminal: MapSet.t()
          }

  @doc """
  A tracker whose lane begins at `first_sequence` (>= 1).

  Both watermarks start at `first_sequence - 1`, meaning "nothing resolved yet" rather than
  "sequence 0 resolved" -- lanes are 1-based and sequence 0 does not exist.
  """
  @spec new(pos_integer()) :: t()
  def new(first_sequence \\ 1) when is_integer(first_sequence) do
    base = if first_sequence < 1, do: 1, else: first_sequence

    %__MODULE__{
      base: base,
      resolved: base - 1,
      reclaimable: base - 1,
      pending: %{},
      disposition: %{},
      local_terminal: MapSet.new()
    }
  end

  @doc """
  Records the gateway's disposition for one sequence and advances the REMOTE prefix across
  newly-contiguous resolving outcomes.

  A `REJECTED_RETRYABLE` disposition is retained but never resolves, so it caps the prefix
  exactly like a missing outcome. Recording does not advance reclamation.

  Errors: `:unknown_disposition`, `:below_base`, `:conflict`. Which one is returned when an
  input is invalid in several ways at once is UNSPECIFIED -- callers may branch on the reason
  but must not depend on a precedence between them.
  """
  @spec record(t(), non_neg_integer(), atom()) :: {:ok, t()} | {:error, atom()}
  def record(%__MODULE__{} = t, seq, disposition) do
    cond do
      not declared?(disposition) -> {:error, :unknown_disposition}
      not is_integer(seq) or seq < t.base -> {:error, :below_base}
      seq <= t.resolved -> record_inside_prefix(t, seq, disposition)
      true -> record_pending(t, seq, disposition)
    end
  end

  # Already inside the prefix: idempotent when it matches, a conflict when it does not. The
  # prefix advancing must not erase WHAT happened, which is why the kind is retained and
  # comparable here at all.
  defp record_inside_prefix(t, seq, disposition) do
    case Map.fetch(t.disposition, seq) do
      {:ok, ^disposition} -> {:ok, t}
      {:ok, _other} -> {:error, :conflict}
      # Retained evidence already released by reclamation; nothing left to contradict.
      :error -> {:ok, t}
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
  Marks that the AGENT durably recorded ITS OWN terminal action for exactly this sequence, then
  advances the local reclaim watermark across the contiguous run of such sequences.

  It records ONE sequence. Recording sequence 2 does not vouch for sequence 1: if sequence 1's
  local quarantine transaction is still pending, the watermark stays below it and sequence 1's
  evidence is retained.

  Errors: `:below_base`, `:not_resolved`.
  """
  @spec record_terminal_outcome(t(), non_neg_integer()) :: {:ok, t()} | {:error, atom()}
  def record_terminal_outcome(%__MODULE__{} = t, seq) do
    cond do
      not is_integer(seq) or seq < t.base ->
        {:error, :below_base}

      seq > t.resolved ->
        # The gateway has not resolved it, so there is nothing for the agent to have acted on.
        {:error, :not_resolved}

      seq <= t.reclaimable ->
        {:ok, t}

      true ->
        {:ok, advance_reclaimable(%{t | local_terminal: MapSet.put(t.local_terminal, seq)})}
    end
  end

  @doc "The REMOTE contiguous resolved watermark. Stops at a gap OR a retryable outcome."
  @spec resolved_through(t()) :: non_neg_integer()
  def resolved_through(%__MODULE__{resolved: r}), do: r

  @doc """
  The LOCAL watermark: how far spool bytes may be released. Never exceeds `resolved_through/1`.
  """
  @spec reclaimable_through(t()) :: non_neg_integer()
  def reclaimable_through(%__MODULE__{reclaimable: r}), do: r

  @doc "The frozen outcome kind of a resolved, not-yet-reclaimed sequence."
  @spec disposition(t(), non_neg_integer()) :: {:ok, atom()} | :error
  def disposition(%__MODULE__{} = t, seq), do: Map.fetch(t.disposition, seq)

  @doc "The recorded outcome of a sequence still outside the prefix."
  @spec pending_disposition(t(), non_neg_integer()) :: {:ok, atom()} | :error
  def pending_disposition(%__MODULE__{} = t, seq), do: Map.fetch(t.pending, seq)

  @doc "How many outcomes are recorded but not yet inside the prefix."
  @spec pending_out_of_order(t()) :: non_neg_integer()
  def pending_out_of_order(%__MODULE__{pending: p}), do: map_size(p)

  @doc "How many resolved-but-not-reclaimed dispositions are retained."
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

  # Walks the contiguous run of locally-recorded terminal outcomes, releasing each sequence's
  # retained evidence as it passes.
  #
  # Overflow-safe by construction: termination is decided by SET MEMBERSHIP, not by a `s <= seq`
  # counter. u64 max is a valid final sequence (lanes never wrap), and after processing it `next`
  # exceeds the range -- which can never be a member, because base is at least 1 and
  # record_terminal_outcome/2 refuses anything below base.
  defp advance_reclaimable(t) do
    next = t.reclaimable + 1

    if next <= @u64_max and MapSet.member?(t.local_terminal, next) do
      advance_reclaimable(%{
        t
        | local_terminal: MapSet.delete(t.local_terminal, next),
          disposition: Map.delete(t.disposition, next),
          reclaimable: next
      })
    else
      t
    end
  end
end
