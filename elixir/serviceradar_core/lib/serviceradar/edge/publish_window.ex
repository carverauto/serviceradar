defmodule ServiceRadar.Edge.PublishWindow do
  @moduledoc """
  The gateway's bounded in-flight publish window (unify-sweep-results-proto task 3.3(c)).

  Publishing must be PIPELINED -- multiple outstanding un-acknowledged sequences at once -- rather
  than serializing every frame on one request and waiting for its PubAck. This is the accounting
  that is meant to make that safe: it bounds how much may be ADMITTED at once by frame count, by
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

  So `expired/2` REPORTS; only `settle/4` releases. Expiry is a signal to republish, not a
  reclaim.

  ## FENCING A STARTED ATTEMPT

  The spec requires a retry to be fenced by the previous attempt's REQUEST -- its owner, its
  start, and its termination -- rather than by a deadline. Those three map onto this module as:

    * OWNER -- the pid recorded at `admit/5`, the process that will issue the request.
    * START -- the `:pending` -> `:active` transition in `activate/2`. Before it the caller has not
      received the reservation, so no request can have been issued. That is exactly why
      `abandon/2` and `revoke_pending/2` are provisional-only.
    * TERMINATION -- the owner itself reporting that the request finished, through
      `attempt_failed/3` or `settle/4`. Both match on `^owner`, as does `rearm/4`, so no other
      process can end or extend a started attempt.

  What that buys is the interleaving this module used to describe as reachable: a caller receives
  attempt 1 and is descheduled, its deadline passes, a sweep ends attempt 1 and admits attempt 2,
  and the first caller resumes and publishes. Two publications, one charge. A sweep that reads an
  expired reservation out of `expired/2` now holds `{key, token}` and nothing more; it is not the
  owner, so `attempt_failed/3` refuses it. A deadline can therefore be REPORTED but never acted
  on -- which is the point, because expiry cannot distinguish "never sent" from "in flight",
  "delayed", or "acknowledged with the acknowledgement lost".

  ## OWNER DEATH IS NOT TERMINATION, DELIBERATELY

  A process can die AFTER its request has reached the socket. Death therefore proves only that the
  owner will issue nothing further -- not that nothing is in flight. Ending an ACTIVE attempt on a
  `:DOWN` would be precisely the insufficient evidence the spec rejects, so this module offers no
  way to do it, and `PublisherPool` monitors only the PROVISIONAL phase, where death does prove
  the request was never issued.

  The cost is real and is stated rather than hidden: an owner that dies mid-request leaves its
  reservation charged and its attempt started, and no retry for that publication is admitted.

  ## WHAT THIS STILL DOES NOT BOUND

  RESTART OVERLAP is CLOSED, and this section previously said otherwise. It described a
  replacement `PublisherPool` starting with its full grant while requests admitted under the
  previous accounting were still in flight -- but the lane no longer restarts that way. The
  accountant is now STABLE and the transport REPLACEABLE under `LaneSupervisor`'s `:rest_for_one`,
  accountant first, so a replacement transport inherits the credits the previous generation
  consumed. `fence_generation/2` ends the dead generation's attempts and keeps their charges.

  OWNER DEATH is the part that remains open, and it is a DIFFERENT gap rather than the remainder
  of that one. Fencing fires on the death of a transport GENERATION, not of an owner, so an owner
  that dies while its transport stays healthy leaves a reservation charged with no attempt against
  it and no retry admissible for that publication. That is deliberate -- owner death is not
  evidence the record went unpublished, per "owner death is not termination" above -- but the
  retention is real. Bounding it needs evidence that the specific REQUEST terminated, which is
  task 3.5's correlation work and not a supervision change.

  CONCURRENCY is no longer part of it. The restart invariant was previously proven only against a
  serial publisher, which is not a proof under concurrency -- one caller could have exactly one
  request outstanding, so "old and replacement requests together cannot exceed the grant" was a
  claim about a single request. `ServiceRadar.Edge.PublishPipeline` now drives several workers
  through one window, and both criteria are exercised with four requests on the wire when the
  generation dies and with a retry offered by a genuinely separate process.

  ## WHOSE OBLIGATION THIS IS

  TASK 3.3's, and stating it as anyone else's was wrong. 3.3 requires the hard
  frame/byte/PubAck-deadline window; 3.4 owns exact-byte and retained-memory binding; 3.5 owns
  outcome-specific PubAck validation and prefix advancement. Correlation from 3.5 may help
  RECOVERY, but it does not move the hard-window obligation out of 3.3.

  ## Transition policy, stated once

      admit a new PUBLICATION, within bounds     -> {:ok, window, reservation}
      admit it again while an attempt is live    -> {:error, :attempt_in_flight}
      admit it again after the attempt ENDED     -> {:ok, window, reservation}  (retry: re-arms,
                                                    no new credits, NEW attempt token)
      a different record on the same slot        -> a DIFFERENT publication, admitted on its own
                                                    credits (the spec REQUIRES it to be published)
      activate a provisional attempt             -> {:ok, window}  (handoff confirmed: the START)
      attempt_failed on the ACTIVE attempt,
        BY ITS OWNER                             -> {:ok, window}  (credits KEPT)
      attempt_failed / settle / rearm by any
        process that is NOT the owner            -> {:error, :not_outstanding}
      admit with a non-pid owner                 -> {:error, :owner}
      revoke_pending a provisional attempt       -> {:ok, window}  (credits KEPT)
      abandon an admission never received       -> {:ok, window}  (credits released, no outcome)
      admit beyond the frame grant               -> {:error, :frame_credits_exhausted}
      admit beyond the byte grant                -> {:error, :byte_credits_exhausted}
      settle with a settling outcome             -> {:ok, window}
      settle with `:retryable_rejection`         -> {:error, :not_settled}
      settle an unknown internal outcome         -> {:error, :unknown_outcome}
      settle anything not outstanding            -> {:error, :not_outstanding}

  PRECEDENCE: the outcome is checked FIRST, so an unknown outcome on a sequence that is also not
  outstanding reports `:unknown_outcome`, not `:not_outstanding`. The last row holds only for a
  known settling outcome.

  `settle/4` does NOT distinguish "never admitted" from "already settled", and does not pretend
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
  defstruct [:frame_credits, :byte_credits, :outstanding, :bytes_outstanding]

  @typedoc """
  A reservation key: the PUBLICATION -- the authenticated slot AND the record identity. See
  `key/5` for why it is neither the slot nor the sequence alone.
  """
  @type key :: {{binary(), binary(), binary(), pos_integer()}, term()}

  @typedoc """
  A handle to ONE ATTEMPT: the publication key plus the token minted when that attempt was
  admitted. Settling and re-arming require it, so an acknowledgement arriving after its attempt was
  superseded or settled cannot act on whatever holds the key now.

  A reservation between attempts stores `nil` in place of a token -- it holds credits but has no
  live attempt, so no handle to it exists. That is why `reservation/2` returns `:error` for one.
  """
  @type reservation :: {key(), pos_integer()}

  @typedoc """
  One generation of transport: the reference the accountant mints when a transport runtime starts.

  A reference rather than a counter, for the reason `mint_token/0` is: a counter restarted with
  the process that owned it, so a stale generation compared EQUAL to a fresh one and fencing the
  old one would have fenced the new one's attempts.
  """
  @type generation :: reference()

  @typedoc """
  An attempt: its phase, its epoch token, the process that will issue it, and the transport
  generation it is issued on.

  All four are needed to decide who may end it. The token fences a superseded attempt, the owner
  fences a non-owner, and the generation is what lets a transport restart resolve the attempts it
  killed WITHOUT touching the ones a replacement transport has since started.
  """
  @type attempt :: {:pending | :active, pos_integer(), pid(), generation()}

  @opaque t :: %__MODULE__{
            frame_credits: non_neg_integer(),
            byte_credits: non_neg_integer(),
            # publication key => {bytes, deadline, nil | attempt()}
            outstanding: %{
              optional(key()) => {non_neg_integer(), integer(), nil | attempt()}
            },
            bytes_outstanding: non_neg_integer()
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
           bytes_outstanding: 0
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
  @spec admit(t(), key(), non_neg_integer(), integer(), pid(), generation()) ::
          {:ok, t(), reservation()} | {:error, atom()}
  def admit(%__MODULE__{} = w, key, bytes, deadline_at, owner, generation) do
    cond do
      not valid_key?(key) ->
        {:error, :publication}

      not is_integer(bytes) or bytes < 0 ->
        {:error, :bytes}

      not is_integer(deadline_at) ->
        {:error, :deadline}

      # The OWNER is the process that will issue the request. Recorded at admission because it is
      # the only thing that can later prove the request TERMINATED -- see "fencing a started
      # attempt" in the moduledoc.
      not is_pid(owner) ->
        {:error, :owner}

      # The GENERATION of transport this attempt will be issued on. A restart replaces the
      # transport WITHOUT replacing this ledger, so when the old generation is later confirmed
      # dead, `fence_generation/2` needs to know which attempts went with it.
      not is_reference(generation) ->
        {:error, :generation}

      true ->
        reserve(w, key, bytes, deadline_at, owner, generation)
    end
  end

  # A reservation holds CREDITS. An ATTEMPT is what is in flight against them. Separating the two
  # is what stops concurrent identical retries from sharing one charge: the credits are charged
  # once, but only one attempt may be outstanding at a time.
  defp reserve(w, key, bytes, deadline_at, owner, generation) do
    case Map.fetch(w.outstanding, key) do
      {:ok, {_bytes, _deadline, attempt}} when attempt !== nil ->
        # An attempt is ALREADY in flight for this publication. Starting a second one would put
        # two requests on the wire under a single charge; when the first is acknowledged the
        # credit is freed while the second is still live, and the next admission takes the window
        # past its grant. The caller must let the current attempt end first.
        {:error, :attempt_in_flight}

      {:ok, {reserved_bytes, _deadline, nil}} ->
        # Reserved, with no attempt in flight: the republish path after a failed attempt. No new
        # credits -- the bytes are already committed -- a moved deadline, and a NEW attempt token
        # so a late acknowledgement from the previous attempt cannot settle this one.
        token = mint_token()

        {:ok,
         %{
           w
           | outstanding:
               Map.put(
                 w.outstanding,
                 key,
                 {reserved_bytes, deadline_at, {:pending, token, owner, generation}}
               )
         }, {key, token}}

      :error ->
        admit_new(w, key, bytes, deadline_at, owner, generation)
    end
  end

  @doc """
  Releases a reservation whose admitting caller never RECEIVED it.

  Deliberately a separate, named entry point rather than a settlement: nothing was published and
  no disposition applies. The narrow authority matters, so it is worth stating what it is NOT --
  caller death does not authorise this. A caller can die after the request reached the socket, or
  exit normally after `attempt_failed/3` deliberately kept the credit; releasing on death would
  permit a second publish while the first is still broker-ambiguous.

  What DOES authorise it is a handoff that never completed: an admission whose reservation the
  caller never received, so no publication can have been attempted against it. `PublisherPool`
  owns that determination.

  Takes a RESERVATION, not a bare key: the token binds the release to the exact attempt that was
  never handed over, so a revocation arriving after that attempt was superseded cannot release
  whatever holds the key now. A key-only version could not express that, and so could not enforce
  its own contract.

  Refuses a CONFIRMED attempt for the same reason. Its caller holds it and may already be
  publishing; releasing the credit then would let one grant cover two publications.
  """
  @spec abandon(t(), reservation()) :: {:ok, t()} | {:error, atom()}
  def abandon(%__MODULE__{} = w, {key, token}) do
    case Map.fetch(w.outstanding, key) do
      # PROVISIONAL ONLY. An active attempt is one its caller holds and may already be
      # publishing; releasing it would free the credit while that request is on the wire, so one
      # grant would cover two publications. Accepting either phase here made the narrow authority
      # this function documents unenforceable.
      {:ok, {bytes, _deadline, {:pending, ^token, _owner, _gen}}} ->
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
  Activates a provisional attempt, once its caller has taken delivery of the reservation.

  Until this runs the attempt exists only to hold the slot: it is invisible to `expired/2` and
  refused by `settle/4`, `rearm/4` and `attempt_failed/3`. That is the point. A provisional token
  reported as expired was enough for an observer to end the attempt, admit a retry, and put two
  requests on the wire under a single charge -- while the caller that was handed the first token
  had not even received it yet.
  """
  @spec activate(t(), reservation()) :: {:ok, t()} | {:error, atom()}
  def activate(%__MODULE__{} = w, {key, token}) do
    case Map.fetch(w.outstanding, key) do
      {:ok, {bytes, deadline, {:pending, ^token, owner, gen}}} ->
        {:ok,
         %{
           w
           | outstanding:
               Map.put(w.outstanding, key, {bytes, deadline, {:active, token, owner, gen}})
         }}

      _ ->
        {:error, :not_outstanding}
    end
  end

  @doc """
  Returns a PROVISIONAL attempt to the no-attempt state, keeping the reservation and its credits.

  Distinct from `attempt_failed/3`, which requires a confirmed attempt, and from `abandon/2`,
  which releases. This is the retry half of revocation: the caller never took delivery, and the
  admission it never received had added no credits -- it re-armed a reservation that is still
  unresolved and still owed a republish. Releasing there handed back a broker-ambiguous frame.

  Named for its authority: only a handoff that did not complete can use it.
  """
  @spec revoke_pending(t(), reservation()) :: {:ok, t()} | {:error, atom()}
  def revoke_pending(%__MODULE__{} = w, {key, token}) do
    case Map.fetch(w.outstanding, key) do
      {:ok, {bytes, deadline, {:pending, ^token, _owner, _gen}}} ->
        {:ok, %{w | outstanding: Map.put(w.outstanding, key, {bytes, deadline, nil})}}

      _ ->
        {:error, :not_outstanding}
    end
  end

  @doc """
  Ends the in-flight attempt WITHOUT releasing the reservation.

  The transport outcome was not terminal -- a timeout, a capacity refusal, a dropped connection --
  so the record is still owed a republish on the same slot and its credits stay charged. What ends
  is the ATTEMPT, which is what makes the next `admit/5` a legal retry rather than
  `:attempt_in_flight`.

  Token-checked: an attempt that has already been superseded cannot end the current one.
  """
  @spec attempt_failed(t(), reservation(), pid()) :: {:ok, t()} | {:error, atom()}
  def attempt_failed(%__MODULE__{} = w, {key, token}, owner) do
    case Map.fetch(w.outstanding, key) do
      # ACTIVE only, and the OWNER only. A provisional attempt belongs to a handoff that has not
      # completed: ending it would free the slot for a retry while the original caller is still
      # about to receive its reservation, putting two attempts on the wire under one charge.
      # Requiring the owner is what makes this TERMINATION rather than a guess.
      {:ok, {bytes, deadline, {:active, ^token, ^owner, _gen}}} ->
        {:ok, %{w | outstanding: Map.put(w.outstanding, key, {bytes, deadline, nil})}}

      _ ->
        {:error, :not_outstanding}
    end
  end

  @doc """
  Ends every attempt issued on a DEAD transport generation, keeping every reservation charged.

  ## The invariant this exists for

  A lane restart replaces the transport but NOT this ledger. Without that split, a replacement
  `PublisherPool` started with an empty window and therefore its full grant, while requests
  admitted under the previous accounting were still in flight on the previous transport -- so the
  old and new requests together could exceed the lane grant. That is task 3.3's restart-overlap
  criterion.

  ## What it does and, more importantly, what it does NOT

  It ends ATTEMPTS. It does NOT release RESERVATIONS, and the distinction is the whole point:
  generation death proves the request can no longer be completed on that transport, which is
  enough to say the attempt is over. It proves NOTHING about whether the record was published --
  the connection may have died after the bytes reached the broker and before any PubAck.

  So the reservation stays charged and its publication may be retried WITHOUT consuming another
  credit. Only a validated resolving PubAck releases credits, through `settle/4`. Releasing here
  would hand back a broker-ambiguous frame and let the lane publish past its grant, which is the
  same defect in a new place.

  Affected reservations therefore become IDLE-BUT-CHARGED: no attempt, credits held, retryable.

  ## WHEN it may be called

  ONLY once the named generation's transport AND its request workers are confirmed dead. Called
  while any of them could still be running, it would end an attempt that may still publish and
  admit a retry alongside it -- two requests under one charge, which is exactly what the owner
  fence in `attempt_failed/3` refuses for the same reason. The accountant owns that determination
  via monitors; this function trusts it and cannot check it.

  Attempts on OTHER generations are untouched, including a replacement generation's, which is why
  the generation is recorded per attempt rather than tracked as a single "current" value.

  Returns the window and how many attempts were ended, so a caller can log a fence that did
  nothing differently from one that ended twenty.
  """
  @spec fence_generation(t(), generation()) :: {:ok, t(), non_neg_integer()}
  def fence_generation(%__MODULE__{} = w, generation) when is_reference(generation) do
    {outstanding, fenced} =
      Enum.reduce(w.outstanding, {%{}, 0}, fn
        {key, {bytes, deadline, {_phase, _token, _owner, ^generation}}}, {acc, n} ->
          # PENDING attempts on the dead generation are fenced too. A pending attempt's caller
          # has not taken delivery, so it has issued nothing and never will -- its transport is
          # gone. Leaving it pending would hold the slot against a retry forever, since only its
          # own caller could revoke it and that caller is about to receive an error instead.
          {Map.put(acc, key, {bytes, deadline, nil}), n + 1}

        {key, entry}, {acc, n} ->
          {Map.put(acc, key, entry), n}
      end)

    {:ok, %{w | outstanding: outstanding}, fenced}
  end

  @doc """
  The generations that currently have at least one attempt against them.

  Lets the accountant assert the bound the spec puts on generation metadata: at most one accepting
  and one draining generation, so this is expected to hold at most two entries.
  """
  @spec live_generations(t()) :: [generation()]
  def live_generations(%__MODULE__{} = w) do
    w.outstanding
    |> Enum.flat_map(fn
      {_key, {_bytes, _deadline, {_phase, _token, _owner, gen}}} -> [gen]
      {_key, {_bytes, _deadline, nil}} -> []
    end)
    |> Enum.uniq()
  end

  # Attempt tokens are drawn from the VM's unique-integer source, NOT a per-window counter. A
  # counter restarted at 1 with the window, so after a lane restart a stale reservation compared
  # EQUAL to a fresh one and settling the stale one released the fresh one's credits. A reservation
  # cannot outlive the node, so node-unique is enough.
  defp mint_token, do: System.unique_integer([:monotonic, :positive])

  defp admit_new(w, key, bytes, deadline_at, owner, generation) do
    cond do
      map_size(w.outstanding) + 1 > w.frame_credits ->
        {:error, :frame_credits_exhausted}

      w.bytes_outstanding + bytes > w.byte_credits ->
        {:error, :byte_credits_exhausted}

      true ->
        token = mint_token()

        {:ok,
         %{
           w
           | outstanding:
               Map.put(
                 w.outstanding,
                 key,
                 {bytes, deadline_at, {:pending, token, owner, generation}}
               ),
             bytes_outstanding: w.bytes_outstanding + bytes
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
      # Only an IN-FLIGHT attempt has a handle. A reservation whose attempt has ended holds its
      # credits but has nothing to settle or re-arm; the next `admit/5` mints its next attempt.
      {:ok, {_bytes, _deadline, {:active, token, _owner, _gen}}} -> {:ok, {key, token}}
      _ -> :error
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
  RECORD IDENTITY, from the outcome-specific
  primary/audit/quarantine/security-quarantine/reject-audit DESTINATION.

  A reservation now carries the record identity (it is half the key) and an attempt token, so a
  settlement can no longer be applied to the wrong publication or to a superseded attempt. What is
  STILL missing is the DESTINATION: nothing here knows which stream an outcome required an ack
  from, and the ack's `seq` is the JETSTREAM STREAM sequence, not the edge lane sequence, so the
  two cannot be compared directly. Verifying that the ack came from the destination the outcome
  names remains the caller's obligation, owed by task 3.5.

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
  @spec settle(t(), reservation(), atom(), pid()) :: {:ok, t()} | {:error, atom()}
  def settle(%__MODULE__{} = w, reservation, outcome, owner) do
    cond do
      outcome == @retryable_outcome ->
        {:error, :not_settled}

      not Map.has_key?(@settling_outcomes, outcome) ->
        {:error, :unknown_outcome}

      true ->
        release(w, reservation, owner)
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

  defp release(w, {key, token}, owner) do
    case Map.fetch(w.outstanding, key) do
      # The token must match, the attempt must be confirmed, AND the settling process must be the
      # attempt's owner. Without the token a late acknowledgement from an already-settled attempt
      # released a LATER reservation that had reused the key; without the phase, a provisional
      # attempt could be settled by anyone who learned its token before its caller did; without
      # the owner, any process holding the reservation tuple could release a request that is
      # still on the wire.
      {:ok, {bytes, _deadline, {:active, ^token, ^owner, _gen}}} ->
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

  `admit/5` also re-arms when it admits the next attempt for a reservation, which is the path the publisher
  takes. This remains for a caller that has verified sameness by other means and wants to move a
  deadline without re-presenting the record.

  Refuses a slot that is not outstanding: there is no frame to re-arm, and silently admitting
  one here would bypass both bounds.
  """
  @spec rearm(t(), reservation(), integer(), pid()) :: {:ok, t()} | {:error, atom()}
  def rearm(%__MODULE__{} = w, {key, token}, deadline_at, owner) do
    if is_integer(deadline_at) do
      case Map.fetch(w.outstanding, key) do
        # Token-checked for the same reason release/2 is: an observer can read an expired
        # reservation, watch it settle, and then move the deadline of whatever reserved the key
        # next.
        {:ok, {bytes, _old, {:active, ^token, ^owner, gen}}} ->
          {:ok,
           %{
             w
             | outstanding:
                 Map.put(w.outstanding, key, {bytes, deadline_at, {:active, token, owner, gen}})
           }}

        _ ->
          {:error, :not_outstanding}
      end
    else
      {:error, :deadline}
    end
  end

  @doc """
  The RESERVATIONS whose in-flight attempt has passed its PubAck deadline, oldest first.

  A reservation between attempts is not reported: it is owed a republish, not an acknowledgement.

  REPORTS ONLY. The frames stay outstanding and stay charged, because the publisher republishes
  the same bytes on the same slot and the publication is still in flight.
  """
  @spec expired(t(), integer()) :: [reservation()]
  def expired(%__MODULE__{} = w, now) when is_integer(now) do
    # ACTIVE attempts only. Reporting a provisional one handed its token to anyone watching for
    # expiry -- enough to end it, admit a retry, and put two attempts on the wire under one charge
    # before the original caller had even received its reservation.
    w.outstanding
    |> Enum.filter(fn {_key, {_bytes, deadline, attempt}} ->
      match?({:active, _, _, _}, attempt) and deadline <= now
    end)
    |> Enum.sort_by(fn {key, {_bytes, deadline, _attempt}} -> {deadline, key} end)
    |> Enum.map(fn {key, {_bytes, _deadline, {:active, token, _o, _g}}} -> {key, token} end)
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

  @doc """
  Whether a PUBLICATION currently holds a reservation.

  True whether or not an attempt is in flight for it: the question is about the credits, which are
  charged from admission until settlement or abandonment.
  """
  @spec outstanding?(t(), key()) :: boolean()
  def outstanding?(%__MODULE__{} = w, key), do: Map.has_key?(w.outstanding, key)
end
