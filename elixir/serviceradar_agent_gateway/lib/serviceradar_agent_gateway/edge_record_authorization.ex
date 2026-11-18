defmodule ServiceRadarAgentGateway.EdgeRecordAuthorization do
  @moduledoc """
  The gateway's LOCAL authorization decision for one `EdgeDeliveryFrameV1`
  (unify-sweep-results-proto task 3.2). It is the Elixir peer of Go's
  `edgerecord.ValidateFrameSigned`, composed with the authenticated mTLS edge identity and the
  opened lane, and it performs no core, ERTS or database lookup: every input is the frame, the
  lane, the identity resolved once at `lane_open`
  (`ServiceRadarAgentGateway.ComponentIdentityResolver.resolve_edge_identity/3`), and the installed
  trust snapshot (`ServiceRadarAgentGateway.EdgeRecordTrust`).

  ## Order

    1. WRAPPER -- `record_sha256` matches the exact bytes; a present delivery capability is a
       well-formed DELIVERY capability bound to this frame's `record_sha256`, `spool_id` and
       `sequence`.
    2. RECORD -- complete structural admission (`ServiceRadar.Edge.RecordValidate`): payload
       binding, contract, producer context, the production grant bound field-by-field to the
       record (exact contract bundle, registry snapshot and EFFECTIVE GRANT digests, scope,
       route/class, producer, cost ceiling), any source authorization bound to its signed claims,
       the recovery lane, identity time and the semantic digest. A present delivery capability
       must name this record's `event_id`.
    3. IDENTITY -- the record's attested origin is an AGENT whose principal is exactly the
       authenticated certificate principal.
    4. ROUTE/CLASS -- the record's route profile and traffic class are the lane's.
    5. SOURCE SHAPE -- a present source authorization's collection window lies inside its signed
       envelope, and its plan/range digests are well-formed, required for scheduler scan kinds.
       Source authorization is verified WHEN THE RECORD CARRIES ONE; nothing here requires a
       generic telemetry, event or inventory record to present a scanner collection capability.
    6. REGISTRY EPOCH -- a record stamped with an installation-static registry epoch, or with an
       epoch the snapshot's contract registry shows as retired, is rejected permanently
       (`ServiceRadarAgentGateway.EdgeContractRegistry.epoch_refusal/2`). This runs before any
       issuer key is looked up, so an unknown or rotated key id cannot turn either rejection into
       a withhold that would cap the lane for good. Everything else the registry decides runs
       after authorization (`EdgeContractRegistry.admit/3`).
    7. SIGNATURES -- production and (if present) source capabilities verify under keys the trust
       snapshot authorizes for exactly that role. A key id the snapshot does not hold, or holds
       without that role, is withheld as unavailable: a snapshot loaded at boot cannot tell a key
       or role issued since from one never issued. The worst status wins: a compromise-revoked key
       on either makes the frame a SECURITY QUARANTINE, before fence or window classification.
    8. NETWORK SCOPE -- the record's network scope is one the trust snapshot binds to its principal
       (`EdgeRecordTrust.with_network_scopes/2`). The production grant names the same principal and
       scope (step 2), so a scope needs both the local binding and the signed grant. It is checked
       only after the signatures verify, so an unsigned scope claim is refused on its signature. A
       principal with no binding, and a signed scope its binding lacks, are withheld: the binding
       may predate the assignment.
    9. AUTHORITY -- the producer fence and the production window decide publication. A producer
       ahead of its fence entry is withheld: this gateway does not know its authority is current.
       A missing fence also withholds ordinary and renewal delivery; only a current exact
       operation-bound rollover grant may drain that historical record to AUDIT, with no primary
       projection. Current authority under a current fence publishes PRIMARY (a valid
       attached delivery grant only
       changes the delivery mode to renewal/rollover). Otherwise only a current delivery grant can
       authorize delivery: an expired grant under a current fence is an ordinary late drain
       (PRIMARY, renewal/rollover mode); a STALE fence is an immutable replay published only for
       AUDIT, stamped `LATE_FENCED_DELIVERY` with the delivery proof, and fenced from
       authoritative projection.

  ## Late admission (openspec add-edge-production-time-admission, Decisions 6 and 7)

  On a LIVE session whose lane open advertised `late_admission_protocol_version` 1 or later, a
  record that cannot be delivered live resolves permanently as `:late_admission_required`, which
  the ingest server sends as rejection code `LATE_ADMISSION_REQUIRED`, so the agent relocates it to
  its late generation (or a foreign-origin hold): an origin principal other than the authenticated
  agent (instead of `:identity_conflict`), a network scope no longer bound to the agent (instead of
  `:scope_unbound` / `:scope_not_bound`), a stale fence with no delivery grant (instead of
  `:fence_stale`) and a missing fence with no grant or a renewal grant (instead of the withhold).
  The grant-backed audit drains and a fence not learned yet are unchanged, and an older agent's
  session keeps every disposition above. A late-admission grant is never accepted on a live
  session.

  On a LATE session, `authorize_late_frame/5` is the peer of Go's `ValidateLateFrameSigned`: the
  wrapper, record, route/class, source shape and signatures as above, but no registry-epoch
  rejection, scope binding or fence check -- core judged those from its authority history. A
  compromise-revoked key, an origin principal other than the authenticated agent, and a terminal
  authority interval in the trust snapshot go to security quarantine before any grant. Otherwise
  only core's late-admission grant publishes, with the grant's publication (PRIMARY or AUDIT) and
  reason, stamped `LATE_ADMISSION` with its delivery proof. A frame without a valid late grant is
  withheld, never rejected for it alone.

  ## Refusal classes

  `{:error, class, reason, event_id}`: `:permanent` resolves the sequence as a rejection;
  `:retryable` withholds it (the condition can clear -- a renewal, a learned fence, key or scope
  binding, a clock that catches up); `:paused` means this release cannot evaluate the record.
  `event_id` is empty only for a refusal made before the record decoded.
  """

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.RecordValidate
  alias ServiceRadar.Edge.RecoveryValidate
  alias ServiceRadar.Edge.SemanticValidate
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadarAgentGateway.EdgeContractRegistry
  alias ServiceRadarAgentGateway.EdgeRecordTrust

  @agent_origin :EDGE_ORIGIN_KIND_AGENT
  # The late-admission protocol version from which a live session's undeliverable records
  # resolve as `:late_admission_required` (Go: `edgerecord.LateAdmissionProtocolVersion`).
  @late_admission_protocol_version 1
  @relocatable [:identity_conflict, :scope_unbound, :scope_not_bound, :fence_stale, :fence_missing]
  # Core's AUDIT reasons; `PublicationIdentity.delivery_proof_digest/2` has already refused any
  # other pairing before a decision is read.
  @late_audit_reasons %{
    EDGE_LATE_DECISION_REASON_FENCED_AT_PRODUCTION: :fenced_at_production,
    EDGE_LATE_DECISION_REASON_HISTORY_UNKNOWN: :history_unknown,
    EDGE_LATE_DECISION_REASON_COMPROMISE_ENDED: :compromise_ended,
    EDGE_LATE_DECISION_REASON_BEYOND_LATE_WINDOW: :beyond_late_window,
    EDGE_LATE_DECISION_REASON_CONTRACT_RETIRED: :contract_retired,
    EDGE_LATE_DECISION_REASON_LEDGER_PRUNED: :ledger_pruned
  }
  @scan_kinds [:EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP, :EDGE_SOURCE_AUTHORIZATION_KIND_SWEEP_PROFILE]
  @permanent_wire_reasons [:too_large, :poison]

  @type publication :: :primary | :audit | :security_quarantine
  @type decision :: %{
          record: struct(),
          publication: publication(),
          delivery_mode: pos_integer(),
          delivery_proof: binary() | nil,
          grant: :none | :renewal | :rollover | :late_admission,
          late_reason: atom() | nil
        }
  @type refusal :: {:error, :permanent | :retryable | :paused, term(), binary()}

  @doc """
  Decides one frame. `lane` carries the opened lane's `:spool_id`, `:route_profile` and
  `:traffic_class`; `identity` is the resolved edge identity carrying the `:network_scope_ids`
  `snapshot` binds to it (`EdgeRecordTrust.with_network_scopes/2`), and an identity without them is
  unbound; `now_unix_nano` is the trusted evaluation instant.
  """
  @spec authorize_frame(struct(), map(), map(), EdgeRecordTrust.snapshot(), integer()) ::
          {:ok, decision()} | refusal()
  def authorize_frame(frame, lane, identity, snapshot, now_unix_nano) do
    relocates? = Map.get(lane, :late_admission_protocol_version, 0) >= @late_admission_protocol_version

    with :ok <- frame_digest(frame),
         :ok <- delivery_binding(frame),
         {:ok, record} <- validate_record(frame.record_bytes),
         :ok <- with_event(delivery_event_binding(frame, record), record),
         :ok <- record |> origin_identity(identity) |> relocate(relocates?) |> with_event(record),
         :ok <- with_event(route_class(record, lane), record),
         :ok <- with_event(source_shape(record), record),
         :ok <- with_event(registry_epoch(record, snapshot), record),
         {:ok, status} <- with_event(record_key_status(record, snapshot), record),
         :ok <- record |> network_scope(identity) |> relocate(relocates?) |> with_event(record) do
      record
      |> decide(frame, status, snapshot, now_unix_nano, relocates?)
      |> with_event(record)
    end
  end

  @doc """
  Decides one frame on a LATE session (the peer of Go's `edgerecord.ValidateLateFrameSigned`).
  Same arguments and result shape as `authorize_frame/5`; see "Late admission" above.
  """
  @spec authorize_late_frame(struct(), map(), map(), EdgeRecordTrust.snapshot(), integer()) ::
          {:ok, decision()} | refusal()
  def authorize_late_frame(frame, lane, identity, snapshot, now_unix_nano) do
    with :ok <- frame_digest(frame),
         {:ok, record} <- validate_record(frame.record_bytes),
         :ok <- with_event(route_class(record, lane), record),
         :ok <- with_event(source_shape(record), record),
         {:ok, status} <- with_event(record_key_status(record, snapshot), record) do
      record
      |> late_decision(frame, identity, status, snapshot, now_unix_nano)
      |> with_event(record)
    end
  end

  @doc """
  Verifies the record a delivery-grant renewal names (unify-sweep-results-proto M2.0g) before core
  is asked to grant it: the exact bytes admit structurally, the record's attested origin is the
  authenticated agent, its production and any source authorization verify under keys the trust
  snapshot holds as valid, and its network scope is one the snapshot binds to the agent.

  Authority expiry and the fence are deliberately NOT checked: a lapsed production grant is what
  the renewal is for, and the fence decides the publication when the record is delivered. A
  record signed by a compromise-revoked key needs no grant (it is security-quarantined at delivery)
  and is refused one.

  Returns `{:ok, record}` or the same refusal shape as `authorize_frame/5`.
  """
  @spec grant_subject(binary(), map(), EdgeRecordTrust.snapshot()) :: {:ok, struct()} | refusal()
  def grant_subject(record_bytes, identity, snapshot) when is_binary(record_bytes) do
    with {:ok, record} <- validate_record(record_bytes),
         :ok <- with_event(origin_identity(record, identity), record),
         {:ok, status} <- with_event(record_key_status(record, snapshot), record),
         :ok <- with_event(check(status == :valid, :permanent, :key_historically_revoked), record),
         :ok <- with_event(network_scope(record, identity), record) do
      {:ok, record}
    end
  end

  @doc """
  The record a late-admission grant may be asked for (`IssueEdgeLateAdmissionGrants`): as
  `grant_subject/3`, except that the record's network scope need not be bound to the agent now.
  A late record names authority that may have lapsed or been deleted since it was produced; core
  judges that scope, epoch and binding against its authority history.
  """
  def late_grant_subject(record_bytes, identity, snapshot) when is_binary(record_bytes) do
    with {:ok, record} <- validate_record(record_bytes),
         :ok <- with_event(origin_identity(record, identity), record),
         {:ok, status} <- with_event(record_key_status(record, snapshot), record),
         :ok <- with_event(check(status == :valid, :permanent, :key_historically_revoked), record) do
      {:ok, record}
    end
  end

  # --- 1. wrapper ------------------------------------------------------------------------------

  defp frame_digest(%{record_bytes: bytes, record_sha256: sha}) when is_binary(bytes) and is_binary(sha) do
    if byte_size(sha) == 32 and :crypto.hash(:sha256, bytes) == sha,
      do: :ok,
      else: {:error, :permanent, :record_sha256_mismatch, ""}
  end

  defp frame_digest(_frame), do: {:error, :permanent, :record_sha256_mismatch, ""}

  defp delivery_binding(%{delivery_capability: nil}), do: :ok

  defp delivery_binding(%{delivery_capability: dc} = frame) do
    with :ok <- CapabilitySigning.validate(dc, :delivery),
         {:delivery, claims} = dc.claims,
         true <-
           claims.record_sha256 == frame.record_sha256 and claims.spool_id == frame.spool_id and
             claims.sequence == frame.sequence,
         {:ok, mode} <- transition_mode(claims),
         {:ok, _proof} <- PublicationIdentity.delivery_proof_digest(dc, mode) do
      :ok
    else
      false -> {:error, :permanent, {:delivery_capability, :binding}, ""}
      {:error, reason} -> {:error, :permanent, {:delivery_capability, reason}, ""}
    end
  end

  defp transition_mode(%{transition: {:renewal, _}}), do: {:ok, PublicationIdentity.mode_renewal()}
  defp transition_mode(%{transition: {:rollover, _}}), do: {:ok, PublicationIdentity.mode_rollover()}
  defp transition_mode(_claims), do: {:error, :transition}

  # --- 2. record -------------------------------------------------------------------------------

  defp validate_record(bytes) do
    case RecordValidate.validate_bytes(bytes) do
      {:ok, record} ->
        with :ok <- recovery_body(record, bytes), do: {:ok, record}

      {:error, {:wire, reason}} when reason in @permanent_wire_reasons ->
        {:error, :permanent, {:wire, reason}, ""}

      {:error, {:wire, reason}} ->
        {:error, :paused, {:wire, reason}, ""}

      {:error, failure} ->
        case SemanticValidate.disposition({:error, failure}, :delivery) do
          {:pause, _} -> {:error, :paused, failure, decoded_event_id(bytes)}
          _ -> {:error, :permanent, failure, decoded_event_id(bytes)}
        end
    end
  end

  # Generic framing is deliberately payload-agnostic. Recovery is a typed
  # ingress, so its body and signed scope must pass the shared owner as well.
  defp recovery_body(record, raw) do
    recovery? =
      record.route_profile == :EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1 or
        record.payload_family == :EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1 or
        record.output_contract.contract_id == "serviceradar.edge.recovery_control" or
        match?(%{kind: :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL}, record.source_authorization)

    if recovery?, do: validate_recovery_body(record, raw), else: :ok
  end

  defp validate_recovery_body(record, raw) do
    with :ok <-
           (record.output_contract.contract_id == "serviceradar.edge.recovery_control" and
              record.output_contract.contract_version == 1)
           |> check(
             :permanent,
             {:recovery_control, :contract_dispatch}
           )
           |> with_event(record),
         {:ok, %{bytes: body}} <- RecoveryValidate.recovery_control_body(record, record.output_contract),
         true <- byte_size(raw) <= byte_size(body) + 16_384 do
      :ok
    else
      false ->
        {:error, :permanent, {:recovery_control, :record_overhead}, record.event_id}

      {:error, _, _, _} = error ->
        error

      {:error, reason} when reason in [:not_ready, :systemic] ->
        {:error, :paused, {:recovery_control, reason}, record.event_id}

      {:error, reason} ->
        {:error, :permanent, {:recovery_control, reason}, record.event_id}
    end
  end

  # The record DECODED and then failed admission, so the refusal is bound to its event id: only a
  # rejection made before decode may leave it empty.
  defp decoded_event_id(bytes) do
    case WireDecode.decode_record(bytes) do
      {:ok, %{event_id: event_id}} when is_binary(event_id) -> event_id
      _ -> ""
    end
  end

  defp delivery_event_binding(%{delivery_capability: nil}, _record), do: :ok

  defp delivery_event_binding(%{delivery_capability: %{claims: {:delivery, claims}}}, record) do
    check(claims.event_id == record.event_id, :permanent, {:delivery_capability, :event_id})
  end

  # --- 3. identity -----------------------------------------------------------------------------

  defp origin_identity(%{producer_context: context}, identity) do
    check(
      context.origin_kind == @agent_origin and context.origin_principal_id == Map.get(identity, :component_id),
      :permanent,
      :identity_conflict
    )
  end

  # --- 4. route/class --------------------------------------------------------------------------

  defp route_class(record, lane) do
    check(
      record.route_profile == lane.route_profile and record.traffic_class == lane.traffic_class,
      :permanent,
      :route_class_conflict
    )
  end

  # --- 5. source shape -------------------------------------------------------------------------

  defp source_shape(%{source_authorization: nil}), do: :ok

  defp source_shape(%{source_authorization: %{capability: cap} = sa}) do
    {:source, claims} = cap.claims

    with :ok <-
           check(
             claims.collection_expires_unix_nano > claims.collection_not_before_unix_nano and
               claims.collection_not_before_unix_nano >= cap.not_before_unix_nano and
               claims.collection_expires_unix_nano <= cap.expires_at_unix_nano,
             :permanent,
             :source_window
           ) do
      range_digests? = digest_or_empty?(claims.execution_plan_sha256) and digest_or_empty?(claims.target_range_sha256)

      scan_range? =
        sa.kind not in @scan_kinds or
          (byte_size(claims.execution_plan_sha256) == 32 and byte_size(claims.target_range_sha256) == 32)

      check(range_digests? and scan_range?, :permanent, :range_conflict)
    end
  end

  defp digest_or_empty?(value), do: byte_size(value) in [0, 32]

  # --- 6. registry epoch -----------------------------------------------------------------------

  defp registry_epoch(record, snapshot) do
    case EdgeContractRegistry.epoch_refusal(record.output_contract, snapshot.registry) do
      :ok -> :ok
      {:reject, reason} -> {:error, :permanent, reason, ""}
    end
  end

  # --- 7. signatures ---------------------------------------------------------------------------

  defp record_key_status(record, snapshot) do
    with {:ok, production} <- verify(record.production_capability, :production, snapshot),
         {:ok, source} <- source_key_status(record.source_authorization, snapshot) do
      {:ok, worst(production, source)}
    end
  end

  # `:valid` is neutral under `worst/2`, so a record without a source authorization keeps its
  # production key's status.
  defp source_key_status(nil, _snapshot), do: {:ok, :valid}
  defp source_key_status(sa, snapshot), do: verify(sa.capability, :source, snapshot)

  defp verify(cap, purpose, snapshot) do
    case EdgeRecordTrust.resolve_key(snapshot, cap.issuer_id, cap.issuer_key_id, purpose) do
      {:ok, public_key, status} ->
        if CapabilitySigning.verify(cap, purpose, public_key),
          do: {:ok, status},
          else: {:error, :permanent, {purpose, :signature}, ""}

      {:error, reason} ->
        {:error, :retryable, {purpose, reason}, ""}
    end
  end

  defp worst(:historically_revoked, _), do: :historically_revoked
  defp worst(_, :historically_revoked), do: :historically_revoked
  defp worst(status, _), do: status

  # --- 8. network scope ------------------------------------------------------------------------

  defp network_scope(record, identity) do
    case Map.get(identity, :network_scope_ids) do
      nil -> {:error, :retryable, :scope_unbound, ""}
      scopes -> check(MapSet.member?(scopes, record.network_scope_id), :retryable, :scope_not_bound)
    end
  end

  # --- 9. authority ----------------------------------------------------------------------------

  # A compromise-revoked production or source key is a security downgrade that needs no delivery
  # grant and precedes fence and window classification.
  defp decide(record, _frame, :historically_revoked, _snapshot, _now, _relocates?) do
    {:ok, decision(record, :security_quarantine, PublicationIdentity.mode_fresh(), nil, :none)}
  end

  defp decide(record, frame, :valid, snapshot, now, relocates?) do
    context = record.producer_context
    cap = record.production_capability
    tolerance = snapshot.clock_tolerance_nano
    fence_key = {record.network_scope_id, context.producer_assignment_id, context.run_shard}
    fence = EdgeRecordTrust.fence_relation(snapshot, fence_key, context.authority_epoch)
    dc = frame.delivery_capability

    cond do
      fence == :future ->
        {:error, :retryable, :fence_not_ready, ""}

      # A future-dated grant is never usable early, even with a current delivery grant.
      now < cap.not_before_unix_nano - tolerance ->
        {:error, :retryable, :authority_not_yet_valid, ""}

      fence == :unavailable ->
        record |> missing_fence_delivery(dc, snapshot, now) |> relocate(relocates?) |> unrelocated()

      true ->
        record |> decide_known_fence(dc, fence, snapshot, now) |> relocate(relocates?)
    end
  end

  # Deleted assignments leave no current fence. Only operation-bound recovery
  # authority can drain that historical record, and it cannot project current state.
  defp missing_fence_delivery(record, %{claims: {:delivery, %{transition: {:rollover, _}}}} = dc, snapshot, now),
    do: late_delivery(record, dc, snapshot, now, :audit)

  # Tagged `:fence_missing` so a capable session can relocate it; an older one sees today's
  # `:fence_not_ready` (`unrelocated/1`), the same reason as a fence not learned yet.
  defp missing_fence_delivery(_record, _dc, _snapshot, _now), do: {:error, :retryable, :fence_missing, ""}

  defp decide_known_fence(record, dc, fence, snapshot, now) do
    cond do
      current_authority?(fence, record.production_capability, now, snapshot.clock_tolerance_nano) ->
        attached_grant(record, dc, snapshot, now)

      is_nil(dc) and fence == :stale ->
        {:error, :permanent, :fence_stale, ""}

      is_nil(dc) ->
        {:error, :retryable, :authority_expired, ""}

      fence == :stale ->
        late_delivery(record, dc, snapshot, now, :audit)

      true ->
        late_delivery(record, dc, snapshot, now, :primary)
    end
  end

  defp attached_grant(record, nil, _snapshot, _now) do
    {:ok, decision(record, :primary, PublicationIdentity.mode_fresh(), nil, :none)}
  end

  defp attached_grant(record, dc, snapshot, now), do: late_delivery(record, dc, snapshot, now, :primary)

  defp late_delivery(record, dc, snapshot, now, publication) do
    with {:ok, grant} <- verify_delivery_grant(dc, snapshot, now) do
      mode = delivery_mode(publication, grant)

      case PublicationIdentity.delivery_proof_digest(dc, mode) do
        {:ok, proof} -> {:ok, decision(record, publication, mode, proof, grant)}
        {:error, reason} -> {:error, :permanent, {:delivery_capability, reason}, ""}
      end
    end
  end

  # A record that cannot be delivered live: on a session at late-admission version 1 or later it
  # resolves permanently so the agent relocates it to late storage; otherwise today's outcome stands.
  defp relocate({:error, _class, reason, event_id}, true) when reason in @relocatable,
    do: {:error, :permanent, :late_admission_required, event_id}

  defp relocate(result, _relocates?), do: result

  defp unrelocated({:error, class, :fence_missing, event_id}), do: {:error, class, :fence_not_ready, event_id}
  defp unrelocated(result), do: result

  # --- late session ----------------------------------------------------------------------------

  # The three security classes come first, before any grant (Go: ValidateLateFrameSigned). A
  # quarantined record carries no grant, so it is published FRESH with no proof, as on a live
  # session.
  defp late_decision(record, frame, identity, status, snapshot, now) do
    context = record.producer_context
    fence_key = {record.network_scope_id, context.producer_assignment_id, context.run_shard}

    quarantine? =
      status == :historically_revoked or origin_identity(record, identity) != :ok or
        EdgeRecordTrust.terminal_interval?(snapshot, fence_key, context.authority_epoch || 0)

    cond do
      quarantine? ->
        {:ok, decision(record, :security_quarantine, PublicationIdentity.mode_fresh(), nil, :none)}

      is_nil(frame.delivery_capability) ->
        {:error, :retryable, :late_admission_grant_required, ""}

      true ->
        late_grant(record, frame, snapshot, now)
    end
  end

  # Core's decision publishes only when it is a current late-admission grant, signed under a valid
  # delivery key, bound to this exact frame and naming this record's production time and epoch.
  # Any other grant is withheld: a fresh grant clears it, and the record is never rejected for it.
  defp late_grant(record, frame, snapshot, now) do
    dc = frame.delivery_capability
    mode = PublicationIdentity.mode_late_admission()

    with :ok <- late_grant_check(CapabilitySigning.validate(dc, :delivery), :capability),
         {:delivery, claims} = dc.claims,
         :ok <- late_grant_check(bound_to_frame?(claims, frame, record), :binding),
         {:late_admission, late} <- late_transition(claims),
         :ok <- late_grant_key(dc, snapshot),
         :ok <-
           late_grant_check(
             current_at?(now, dc.not_before_unix_nano, dc.expires_at_unix_nano, snapshot.clock_tolerance_nano),
             :authority_expired
           ),
         :ok <-
           late_grant_check(
             late.produced_at_unix_nano == produced_at(record) and
               late.authority_epoch == (record.producer_context.authority_epoch || 0),
             :mismatch
           ),
         {:ok, proof} <- late_grant_proof(PublicationIdentity.delivery_proof_digest(dc, mode)) do
      {publication, reason} = late_publication(late)
      {:ok, decision(record, publication, mode, proof, :late_admission, reason)}
    end
  end

  defp bound_to_frame?(claims, frame, record) do
    claims.record_sha256 == frame.record_sha256 and claims.spool_id == frame.spool_id and
      claims.sequence == frame.sequence and claims.event_id == record.event_id
  end

  defp late_transition(%{transition: {:late_admission, late}}) when is_struct(late), do: {:late_admission, late}
  defp late_transition(_claims), do: late_grant_refusal(:transition)

  defp late_grant_key(dc, snapshot) do
    case verify(dc, :delivery, snapshot) do
      {:ok, :valid} -> :ok
      {:ok, _status} -> late_grant_refusal(:key_historically_revoked)
      {:error, _class, {:delivery, reason}, _} -> late_grant_refusal(reason)
    end
  end

  defp late_grant_proof({:ok, proof}), do: {:ok, proof}
  defp late_grant_proof({:error, reason}), do: late_grant_refusal(reason)

  defp late_grant_check(:ok, _reason), do: :ok
  defp late_grant_check(true, _reason), do: :ok
  defp late_grant_check(_failed, reason), do: late_grant_refusal(reason)

  defp late_grant_refusal(reason), do: {:error, :retryable, {:late_admission_grant, reason}, ""}

  defp late_publication(%{publication: :EDGE_LATE_PUBLICATION_PRIMARY}), do: {:primary, :admitted}

  defp late_publication(%{publication: :EDGE_LATE_PUBLICATION_AUDIT, reason: reason}),
    do: {:audit, Map.fetch!(@late_audit_reasons, reason)}

  # The UUIDv7 time of the event id, which the record's signed production window already binds.
  defp produced_at(%{event_id: <<millis::48, _::80>>}), do: millis * 1_000_000

  defp delivery_mode(:audit, _grant), do: PublicationIdentity.mode_late_fenced()
  defp delivery_mode(:primary, :rollover), do: PublicationIdentity.mode_rollover()
  defp delivery_mode(:primary, :renewal), do: PublicationIdentity.mode_renewal()

  # A delivery grant authorizes a CURRENT drain, so its key must be currently valid and its
  # envelope current; a renewal's inner window must also sit inside the envelope and contain now.
  # Expiry and a since-revoked delivery key are retryable: a fresh grant clears them.
  defp verify_delivery_grant(dc, snapshot, now) do
    tolerance = snapshot.clock_tolerance_nano

    with {:ok, status} <- verify(dc, :delivery, snapshot),
         :ok <- check(status == :valid, :retryable, {:delivery, :key_historically_revoked}),
         :ok <-
           check(
             current_at?(now, dc.not_before_unix_nano, dc.expires_at_unix_nano, tolerance),
             :retryable,
             {:delivery, :authority_expired}
           ) do
      case dc.claims do
        {:delivery, %{transition: {:renewal, renewal}}} ->
          renewal_grant(dc, renewal, now, tolerance)

        {:delivery, %{transition: {:rollover, _}}} ->
          {:ok, :rollover}
      end
    end
  end

  defp renewal_grant(dc, renewal, now, tolerance) do
    inside? =
      renewal.renewed_not_before_unix_nano >= dc.not_before_unix_nano and
        renewal.renewed_expires_unix_nano <= dc.expires_at_unix_nano and
        current_at?(now, renewal.renewed_not_before_unix_nano, renewal.renewed_expires_unix_nano, tolerance)

    with :ok <- check(inside?, :retryable, {:delivery, :renewal_window}), do: {:ok, :renewal}
  end

  defp current_at?(now, not_before, expires, tolerance), do: now >= not_before - tolerance and now <= expires + tolerance

  defp current_authority?(fence, cap, now, tolerance),
    do: fence == :current and current_at?(now, cap.not_before_unix_nano, cap.expires_at_unix_nano, tolerance)

  defp decision(record, publication, mode, proof, grant, late_reason \\ nil) do
    %{
      record: record,
      publication: publication,
      delivery_mode: mode,
      delivery_proof: proof,
      grant: grant,
      late_reason: late_reason
    }
  end

  # Refusals after the record decoded carry its event id, so the agent can bind the disposition
  # to the event it sent for that sequence.
  defp with_event({:error, class, reason, ""}, record), do: {:error, class, reason, record.event_id}
  defp with_event(result, _record), do: result

  defp check(true, _class, _reason), do: :ok
  defp check(false, class, reason), do: {:error, class, reason, ""}
end
