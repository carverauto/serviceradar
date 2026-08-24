defmodule ServiceRadar.Edge.PublishWindow do
  @moduledoc """
  The gateway's bounded in-flight publish window (unify-sweep-results-proto task 3.3(c)).

  Publishing must be PIPELINED -- multiple outstanding un-acknowledged sequences at once -- rather
  than serializing every frame on one request and waiting for its PubAck. This is the accounting
  that makes that safe: it bounds how much may be outstanding at any moment by frame count, by
  bytes, and by a per-frame PubAck deadline.

  Pure data and functions: no I/O, no process, no clock. `now` and deadlines are passed in, so the
  window is deterministic and a test does not have to sleep. The process that owns the lane owns
  the term; supervision belongs to the publisher that will drive this.

  ## The bounds come from the GRANT, and their LEGALITY is not decided here

  `granted_frame_credits` and `granted_byte_credits` arrive in `EdgeRecordLaneOpenAck`, so the
  window is sized FROM the ack rather than from configuration that could disagree with the wire.

  It does NOT adjudicate whether a grant is legal. Task 1.7-e owns the lane-handshake admission
  bounds -- the exact nonce range, the credit caps, and the return relation
  `1 <= granted <= requested` -- and those are NOT YET FROZEN. An earlier version of this module
  validated the grant against uint32/uint64 wire maxima and documented a zero grant as "a real
  answer", which was wrong twice: the caps are separate normative values 1.7-e has still to state,
  and its return relation makes zero a REFUSAL rather than a legal grant. 1.7-e says a different
  semantics "SHALL be chosen and stated HERE, not discovered from whichever verdict the current Go
  code returns" -- and inventing the caps here is precisely that failure.

  So `ValidateLaneOpenAck` decides legality; this module does accounting. The only checks kept are
  TYPE preconditions (a non-negative integer), which are a programming contract rather than a claim
  about the wire.

  ## A deadline does NOT release credits

  This is the trap worth stating plainly. When a PubAck does not arrive in time, the frame is
  still outstanding: the publisher republishes THE SAME bytes on THE SAME slot, so a lost-ACK
  redelivery deduplicates. If expiry released its credits, the window would hand the same budget
  out twice and the real in-flight total would exceed the grant -- a bound that relaxes exactly
  when the broker is already struggling.

  So `expired/2` REPORTS; only `settle/2` releases. Expiry is a signal to republish, not a
  reclaim.

  ## Transition policy, stated once

      admit a new sequence, within both bounds   -> {:ok, window}
      admit a sequence already outstanding       -> {:error, :already_outstanding}
      admit beyond the frame grant               -> {:error, :frame_credits_exhausted}
      admit beyond the byte grant                -> {:error, :byte_credits_exhausted}
      settle an outstanding sequence             -> {:ok, window}
      settle anything else                       -> {:error, :not_outstanding}

  `settle/2` does NOT distinguish "never admitted" from "already settled", and does not pretend
  to: once a slot leaves the window there is nothing retained to tell the two apart. Reporting
  them separately would require keeping every settled sequence forever, which is the unbounded
  growth this module exists to prevent. Both are `:not_outstanding`, and the docstring says so
  rather than leaving a caller to infer it.
  """

  @u64_max 0xFFFFFFFFFFFFFFFF

  @enforce_keys [:frame_credits, :byte_credits, :outstanding, :bytes_outstanding]
  defstruct [:frame_credits, :byte_credits, :outstanding, :bytes_outstanding]

  @opaque t :: %__MODULE__{
            frame_credits: non_neg_integer(),
            byte_credits: non_neg_integer(),
            # sequence => {bytes, deadline}
            outstanding: %{optional(pos_integer()) => {non_neg_integer(), integer()}},
            bytes_outstanding: non_neg_integer()
          }

  @doc """
  A window sized by the credits an ALREADY-VALIDATED `EdgeRecordLaneOpenAck` granted.

  Only type preconditions are checked. Whether a grant is admissible -- the caps, and the
  `1 <= granted <= requested` relation -- belongs to task 1.7-e and `ValidateLaneOpenAck`; see the
  moduledoc for why this module must not decide it.

  A zero grant is ACCEPTED here and admits nothing. That is not a claim that zero is legal: 1.7-e's
  return relation makes it a refusal, and the validator upstream is where that refusal happens. A
  window handed zero simply has no capacity, which is the safe behaviour for a value that should
  never have reached it.
  """
  @spec new(non_neg_integer(), non_neg_integer()) :: {:ok, t()} | {:error, atom()}
  def new(granted_frame_credits, granted_byte_credits) do
    cond do
      not is_integer(granted_frame_credits) or granted_frame_credits < 0 ->
        {:error, :frame_credits}

      not is_integer(granted_byte_credits) or granted_byte_credits < 0 ->
        {:error, :byte_credits}

      true ->
        {:ok,
         %__MODULE__{
           frame_credits: granted_frame_credits,
           byte_credits: granted_byte_credits,
           outstanding: %{},
           bytes_outstanding: 0
         }}
    end
  end

  @doc """
  Admits one frame into the window, charging its bytes and recording its PubAck deadline.

  `deadline_at` is a monotonic instant supplied by the caller; this module never reads a clock.

  Refuses rather than overcommitting: a frame that would exceed either grant is not admitted, and
  the caller waits for a settlement instead of publishing anyway.
  """
  @spec admit(t(), pos_integer(), non_neg_integer(), integer()) :: {:ok, t()} | {:error, atom()}
  def admit(%__MODULE__{} = w, seq, bytes, deadline_at) do
    cond do
      not is_integer(seq) or seq < 1 or seq > @u64_max ->
        {:error, :sequence}

      not is_integer(bytes) or bytes < 0 ->
        {:error, :bytes}

      not is_integer(deadline_at) ->
        {:error, :deadline}

      Map.has_key?(w.outstanding, seq) ->
        # A slot is allocated once. A second admit is a caller bug, not a retry: a retry
        # republishes the SAME slot, which is already outstanding and still charged.
        {:error, :already_outstanding}

      map_size(w.outstanding) + 1 > w.frame_credits ->
        {:error, :frame_credits_exhausted}

      w.bytes_outstanding + bytes > w.byte_credits ->
        {:error, :byte_credits_exhausted}

      true ->
        {:ok,
         %{
           w
           | outstanding: Map.put(w.outstanding, seq, {bytes, deadline_at}),
             bytes_outstanding: w.bytes_outstanding + bytes
         }}
    end
  end

  @doc """
  Releases one frame's credits once its publication is settled.

  PRECONDITION, which this module cannot check: the caller must have a VALIDATED PubAck for this
  sequence, or a terminal disposition that ends the attempt. It is not enough that a reply arrived
  -- an ack from an unexpected stream, or one that failed sequence validation, is not a settlement,
  and releasing on it would return budget for a frame whose fate is unknown. The publisher owns
  that validation; this records the consequence.

  This is the ONLY thing that returns budget. See the moduledoc on why a deadline does not.
  """
  @spec settle(t(), pos_integer()) :: {:ok, t()} | {:error, atom()}
  def settle(%__MODULE__{} = w, seq) do
    case Map.fetch(w.outstanding, seq) do
      {:ok, {bytes, _deadline}} ->
        {:ok,
         %{
           w
           | outstanding: Map.delete(w.outstanding, seq),
             bytes_outstanding: w.bytes_outstanding - bytes
         }}

      :error ->
        {:error, :not_outstanding}
    end
  end

  @doc """
  Replaces an outstanding frame's PubAck deadline, leaving its credits charged.

  This is the republish path, and without it the retry was UNREPRESENTABLE: `admit/4` refuses an
  outstanding slot (`:already_outstanding`) and `settle/2` would release credits for a frame that
  is still in flight, so an expired frame could be reported forever but never re-armed.

  Charges nothing and releases nothing -- the bytes were already committed and the publication is
  the same publication on the same slot. Only the deadline moves.

  Refuses a sequence that is not outstanding: there is no frame to re-arm, and silently admitting
  one here would bypass both bounds.
  """
  @spec rearm(t(), pos_integer(), integer()) :: {:ok, t()} | {:error, atom()}
  def rearm(%__MODULE__{} = w, seq, deadline_at) do
    if is_integer(deadline_at) do
      case Map.fetch(w.outstanding, seq) do
        {:ok, {bytes, _old}} ->
          {:ok, %{w | outstanding: Map.put(w.outstanding, seq, {bytes, deadline_at})}}

        :error ->
          {:error, :not_outstanding}
      end
    else
      {:error, :deadline}
    end
  end

  @doc """
  The outstanding sequences whose PubAck deadline has passed, oldest first.

  REPORTS ONLY. The frames stay outstanding and stay charged, because the publisher republishes
  the same bytes on the same slot and the publication is still in flight.
  """
  @spec expired(t(), integer()) :: [pos_integer()]
  def expired(%__MODULE__{} = w, now) when is_integer(now) do
    w.outstanding
    |> Enum.filter(fn {_seq, {_bytes, deadline}} -> deadline <= now end)
    |> Enum.sort_by(fn {seq, {_bytes, deadline}} -> {deadline, seq} end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Whether another frame of `bytes` would be admitted right now.

  `false` for a malformed size rather than raising or guessing: asking "may I admit garbage" has a
  correct answer, and it is no.
  """
  @spec admits?(t(), non_neg_integer()) :: boolean()
  def admits?(%__MODULE__{} = w, bytes) when is_integer(bytes) and bytes >= 0 do
    map_size(w.outstanding) + 1 <= w.frame_credits and
      w.bytes_outstanding + bytes <= w.byte_credits
  end

  def admits?(%__MODULE__{}, _bytes), do: false

  @doc "How many frames are outstanding."
  @spec outstanding_frames(t()) :: non_neg_integer()
  def outstanding_frames(%__MODULE__{outstanding: o}), do: map_size(o)

  @doc "How many bytes are outstanding."
  @spec outstanding_bytes(t()) :: non_neg_integer()
  def outstanding_bytes(%__MODULE__{bytes_outstanding: b}), do: b

  @doc "Frame credits not currently committed."
  @spec available_frames(t()) :: non_neg_integer()
  def available_frames(%__MODULE__{} = w), do: w.frame_credits - map_size(w.outstanding)

  @doc "Byte credits not currently committed."
  @spec available_bytes(t()) :: non_neg_integer()
  def available_bytes(%__MODULE__{} = w), do: w.byte_credits - w.bytes_outstanding

  @doc "Whether a sequence is currently outstanding."
  @spec outstanding?(t(), pos_integer()) :: boolean()
  def outstanding?(%__MODULE__{} = w, seq), do: Map.has_key?(w.outstanding, seq)
end
