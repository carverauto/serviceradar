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

  NOTHING VALIDATES THE GRANT ON THIS SIDE TODAY. Go has `ValidateLaneOpenAck`; this runtime has no
  peer. Elixir has `SemanticValidate.validate_lane_open/1`, an enum/shape check on the REQUEST half
  only -- there is no lane-ack validator here at all. An earlier revision wrote "legality is the
  lane-open validator's", which reads as though something upstream checks it; nothing does, and 1.7-e
  owes that peer.

  So the grant reaching this window is UNVALIDATED, and this module still declines to validate it:
  an accounting module inventing the caps is how the gap gets papered over instead of closed. The
  only checks kept are TYPE preconditions (a non-negative integer) -- a programming contract, not a
  claim about the wire.

  ## A deadline does NOT release credits

  This is the trap worth stating plainly. When a PubAck does not arrive in time, the frame is
  still outstanding: the publisher republishes THE SAME bytes on THE SAME slot, so a lost-ACK
  redelivery deduplicates. If expiry released its credits, the window would hand the same budget
  out twice and the real in-flight total would exceed the grant -- a bound that relaxes exactly
  when the broker is already struggling.

  So `expired/2` REPORTS; only `settle/3` releases. Expiry is a signal to republish, not a
  reclaim.

  ## Transition policy, stated once

      admit a new PUBLICATION, within bounds     -> {:ok, window, reservation}
      admit the same publication again           -> {:ok, window, reservation}  (retry: re-arms,
                                                    no new credits, SAME token)
      a different record on the same slot        -> a DIFFERENT publication, admitted on its own
                                                    credits (the spec REQUIRES it to be published)
      admit beyond the frame grant               -> {:error, :frame_credits_exhausted}
      admit beyond the byte grant                -> {:error, :byte_credits_exhausted}
      settle with a settling outcome             -> {:ok, window}
      settle with `:retryable_rejection`         -> {:error, :not_settled}
      settle an unknown internal outcome         -> {:error, :unknown_outcome}
      settle anything not outstanding            -> {:error, :not_outstanding}

  PRECEDENCE: the outcome is checked FIRST, so an unknown outcome on a sequence that is also not
  outstanding reports `:unknown_outcome`, not `:not_outstanding`. The last row holds only for a
  known settling outcome.

  `settle/3` does NOT distinguish "never admitted" from "already settled", and does not pretend
  to: once a slot leaves the window there is nothing retained to tell the two apart. Reporting
  them separately would require keeping every settled sequence forever, which is the unbounded
  growth this module exists to prevent. Both are `:not_outstanding`, and the docstring says so
  rather than leaving a caller to infer it.
  """

  @u64_max 0xFFFFFFFFFFFFFFFF

  # The SIX INTERNAL OUTCOMES of task 3.5, not the five wire dispositions. The mapping is not
  # one-to-one: quarantine_publication and security_quarantine_publication BOTH map to
  # ACCEPTED_QUARANTINE on the wire, so the wire member cannot say which destination a PubAck had
  # to come from. Taking the wire disposition here made the required destination unidentifiable.
  #
  # An ALLOWLIST, so an outcome added later cannot release credits by default.
  @settling_outcomes %{
    primary_publication: :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE,
    audit_publication: :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY,
    quarantine_publication: :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE,
    security_quarantine_publication: :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE,
    permanent_rejection: :EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT
  }

  @retryable_outcome :retryable_rejection

  @enforce_keys [:frame_credits, :byte_credits, :outstanding, :bytes_outstanding]
  defstruct [:frame_credits, :byte_credits, :outstanding, :bytes_outstanding, :next_token]

  @typedoc """
  A reservation key: the PUBLICATION -- the authenticated slot AND the record identity. See
  `key/5` for why it is neither the slot nor the sequence alone.
  """
  @type key :: {{binary(), binary(), binary(), pos_integer()}, term()}

  @typedoc """
  A handle to ONE reservation epoch: the publication key plus the token issued when it was
  admitted. Settling and re-arming require it, so an acknowledgement that arrives after its
  reservation was already settled cannot release a LATER reservation that happens to reuse the
  key -- the ABA the bare key allowed.
  """
  @type reservation :: {key(), pos_integer()}

  @opaque t :: %__MODULE__{
            frame_credits: non_neg_integer(),
            byte_credits: non_neg_integer(),
            # publication key => {bytes, deadline, token}
            outstanding: %{optional(key()) => {non_neg_integer(), integer(), pos_integer()}},
            bytes_outstanding: non_neg_integer(),
            next_token: pos_integer()
          }

  @doc """
  A window sized by the credits an `EdgeRecordLaneOpenAck` granted.

  NOT "already-validated": nothing on this side validates a lane ack (see the moduledoc), so the
  grant reaching here has passed no check at all.

  Only type preconditions are checked. Whether a grant is admissible -- the caps, and the
  `1 <= granted <= requested` relation -- is task 1.7-e's to define and an Elixir lane-ack
  validator's to enforce. NEITHER EXISTS YET, so no check runs on this side at all; see the
  moduledoc.

  A zero grant is NOT REJECTED HERE, and that is not a claim that zero is legal -- 1.7-e's return
  relation `1 <= granted` makes it a refusal. It is that this module does not adjudicate grants at
  all, and no validator on this side does either yet, so a zero can reach here. When it does the
  window simply has no capacity and admits nothing, which is the safe behaviour for a value that
  should have been refused upstream.
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
           bytes_outstanding: 0,
           # Monotonic per window. Tokens are never reused, which is what makes a settlement from
           # an earlier epoch distinguishable from one for the reservation holding the key now.
           next_token: 1
         }}
    end
  end

  @doc """
  Admits one frame into the window, charging `bytes` and recording its PubAck deadline.

  `bytes` is whatever the caller passes. NOTHING here binds it to the actual encoded frame size.
  That binding is owed by TASK 3.4 -- which requires publishing the exact
  `EdgeDeliveryFrameV1.record_bytes` and bounding asynchronous publication by encoded bytes --
  together with the remaining 3.3(c) publisher integration. Until it exists the byte bound is only
  as accurate as its caller.

  `deadline_at` is a monotonic instant supplied by the caller; this module never reads a clock and
  does NOT own the deadline POLICY -- how long an attempt may wait is the publisher's.

  Refuses rather than overcommitting: a frame that would exceed either grant is not admitted, and
  the caller waits for a settlement instead of publishing anyway.
  """
  @spec admit(t(), key(), non_neg_integer(), integer()) ::
          {:ok, t(), reservation()} | {:error, atom()}
  def admit(%__MODULE__{} = w, key, bytes, deadline_at) do
    cond do
      not valid_key?(key) ->
        {:error, :publication}

      not is_integer(bytes) or bytes < 0 ->
        {:error, :bytes}

      not is_integer(deadline_at) ->
        {:error, :deadline}

      true ->
        reserve(w, key, bytes, deadline_at)
    end
  end

  defp reserve(w, key, bytes, deadline_at) do
    case Map.fetch(w.outstanding, key) do
      {:ok, {reserved_bytes, _deadline, token}} ->
        # The SAME publication on the same slot: the republish path. No new credits -- the bytes
        # are already committed -- and the deadline MOVES, because a retry that kept the expired
        # one would be reported expired forever. The token is unchanged: this is the same
        # reservation epoch, so both attempts settle the same thing exactly once.
        {:ok,
         %{w | outstanding: Map.put(w.outstanding, key, {reserved_bytes, deadline_at, token})},
         {key, token}}

      :error ->
        admit_new(w, key, bytes, deadline_at)
    end
  end

  defp admit_new(w, key, bytes, deadline_at) do
    cond do
      map_size(w.outstanding) + 1 > w.frame_credits ->
        {:error, :frame_credits_exhausted}

      w.bytes_outstanding + bytes > w.byte_credits ->
        {:error, :byte_credits_exhausted}

      true ->
        token = w.next_token

        {:ok,
         %{
           w
           | outstanding: Map.put(w.outstanding, key, {bytes, deadline_at, token}),
             bytes_outstanding: w.bytes_outstanding + bytes,
             next_token: token + 1
         }, {key, token}}
    end
  end

  @doc """
  The CURRENT reservation for a publication key, if it is outstanding.

  An observer holding a key needs the epoch token to settle or re-arm, and it must read it now
  rather than remember one: a token read earlier may belong to an epoch that has since settled,
  which is exactly the staleness the token exists to reject.
  """
  @spec reservation(t(), key()) :: {:ok, reservation()} | :error
  def reservation(%__MODULE__{} = w, key) do
    case Map.fetch(w.outstanding, key) do
      {:ok, {_bytes, _deadline, token}} -> {:ok, {key, token}}
      :error -> :error
    end
  end

  @doc """
  A reservation key: the PUBLICATION, which is the authenticated slot AND the record identity.

  Not the slot alone. Two things go wrong if the slot alone is the key, and they pull in opposite
  directions:

    * Keyed on the lane SEQUENCE, different agents alias -- one pool serves every agent and spool
      in its class, so agent B at sequence 1 looked like agent A retrying, published on A's
      credits, and settled A's reservation.
    * Keyed on the SLOT, a second record on that slot is refused -- but the spec REQUIRES it to be
      published: `Nats-Msg-Id` binds `record_sha256`, so JetStream does not deduplicate it away and
      "the frame SHALL reach EventWriter", which rejects it as a transport-integrity violation.
      Adjudicating that here would move EventWriter's decision into the gateway and silently drop
      the evidence.

  Keying on the publication satisfies both: a retry is the same key (same bytes, same digest) and
  costs nothing extra, while a different record is a different key and is admitted or refused on
  its own credits like any other frame.
  """
  @spec key(binary(), binary(), binary(), pos_integer(), term()) :: key()
  def key(network_scope_id, authenticated_agent_id, spool_id, sequence, fingerprint),
    do: {{network_scope_id, authenticated_agent_id, spool_id, sequence}, fingerprint}

  defp valid_key?({{scope, agent, spool, seq}, _fingerprint})
       when is_binary(scope) and is_binary(agent) and is_binary(spool) and is_integer(seq) and
              seq >= 1 and
              seq <= @u64_max,
       do: scope != "" and agent != "" and spool != ""

  defp valid_key?(_), do: false

  @doc """
  Releases one frame's credits, given the internal outcome that ended the attempt.

  ## THIS DOES NOT ENFORCE TASK 3.5's PubAck REQUIREMENT

  Stated plainly because an earlier revision claimed it did. 3.5 requires the PubAck for the EXACT
  RECORD IDENTITY and the outcome-specific primary/audit/quarantine/security-quarantine/reject-audit
  DESTINATION. This module has neither: an outstanding entry is `{bytes, deadline}` against an edge
  lane sequence, with no record identity, no attempt token, and no expected destination.

  Passing an Ack-shaped map here proved nothing, and the previous version's own test demonstrated
  it -- ONE bulk-stream ack settled all five terminal outcomes, and the same ack could settle a
  second lane sequence under a different outcome. Detaching the map from the request that produced
  it discards exactly the correlation that made it evidence. The ack's `seq` is the JETSTREAM
  STREAM sequence, not the edge lane sequence, so the two cannot even be compared directly.

  So the parameter is GONE rather than weakened. This helper is ACCOUNTING ONLY: it records that an
  attempt ended and returns its credits.

  THE CALLER MUST have verified, before calling: that a validated PubAck exists for this exact
  publication attempt, that it came from the destination the outcome requires, and that it
  corresponds to this record identity. None of that is checkable here, and pretending otherwise put
  a false guarantee in front of a real gap. That enforcement is OWED by TASK 3.5 together with the
  remaining 3.3(c) publisher integration, and remains OPEN.

  `outcome` is one of task 3.5's SIX INTERNAL OUTCOMES, not a wire disposition -- the wire has five
  members and cannot distinguish `quarantine_publication` from `security_quarantine_publication`,
  so it cannot name the destination a PubAck had to come from.

    * `:retryable_rejection` does NOT settle: it is transient, the frame stays outstanding and
      stays charged, and the publisher re-arms and republishes
    * an outcome outside the allowlist is refused, so one added later cannot release credits
      before anyone has classified it
  """
  @spec settle(t(), reservation(), atom()) :: {:ok, t()} | {:error, atom()}
  def settle(%__MODULE__{} = w, reservation, outcome) do
    cond do
      outcome == @retryable_outcome ->
        {:error, :not_settled}

      not Map.has_key?(@settling_outcomes, outcome) ->
        {:error, :unknown_outcome}

      true ->
        release(w, reservation)
    end
  end

  @doc """
  The wire disposition an internal outcome maps to.

  FIVE wire members for SIX outcomes: `quarantine_publication` and
  `security_quarantine_publication` both report `ACCEPTED_QUARANTINE`, so the SECURITY-quarantine
  ROUTING path must be preserved separately -- the wire disposition alone cannot express it.
  """
  @spec wire_disposition(atom()) :: {:ok, atom()} | :error
  def wire_disposition(@retryable_outcome),
    do: {:ok, :EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE}

  def wire_disposition(outcome), do: Map.fetch(@settling_outcomes, outcome)

  @doc "Every internal outcome this module knows, settling and not."
  @spec internal_outcomes() :: [atom()]
  def internal_outcomes, do: [@retryable_outcome | Map.keys(@settling_outcomes)]

  defp release(w, {key, token}) do
    case Map.fetch(w.outstanding, key) do
      # The token must match. Without it a late acknowledgement from an already-settled attempt
      # released a LATER reservation that had reused the key -- one publication's ack cancelling
      # another's.
      {:ok, {bytes, _deadline, ^token}} ->
        {:ok,
         %{
           w
           | outstanding: Map.delete(w.outstanding, key),
             bytes_outstanding: w.bytes_outstanding - bytes
         }}

      _ ->
        {:error, :not_outstanding}
    end
  end

  @doc """
  Replaces an outstanding frame's PubAck deadline, leaving its credits charged.

  Charges nothing and releases nothing -- the bytes were already committed and the publication is
  the same publication on the same slot. Only the deadline moves.

  `admit/5` also re-arms when it recognises a retry by fingerprint, which is the path the publisher
  takes. This remains for a caller that has verified sameness by other means and wants to move a
  deadline without re-presenting the record.

  Refuses a slot that is not outstanding: there is no frame to re-arm, and silently admitting
  one here would bypass both bounds.
  """
  @spec rearm(t(), reservation(), integer()) :: {:ok, t()} | {:error, atom()}
  def rearm(%__MODULE__{} = w, {key, token}, deadline_at) do
    if is_integer(deadline_at) do
      case Map.fetch(w.outstanding, key) do
        # Token-checked for the same reason release/2 is: an observer can read an expired
        # reservation, watch it settle, and then move the deadline of whatever reserved the key
        # next.
        {:ok, {bytes, _old, ^token}} ->
          {:ok, %{w | outstanding: Map.put(w.outstanding, key, {bytes, deadline_at, token})}}

        _ ->
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
  @spec expired(t(), integer()) :: [reservation()]
  def expired(%__MODULE__{} = w, now) when is_integer(now) do
    w.outstanding
    |> Enum.filter(fn {_key, {_bytes, deadline, _token}} -> deadline <= now end)
    |> Enum.sort_by(fn {key, {_bytes, deadline, _token}} -> {deadline, key} end)
    |> Enum.map(fn {key, {_bytes, _deadline, token}} -> {key, token} end)
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
