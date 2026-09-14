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
       authenticated certificate principal, and its network scope is one the trust snapshot binds
       to that principal (`EdgeRecordTrust.with_network_scopes/2`). The production grant names the
       same principal and scope (step 2), so a scope needs both the local binding and the signed
       grant. A principal with no binding is withheld; a scope outside its binding is rejected.
    4. ROUTE/CLASS -- the record's route profile and traffic class are the lane's.
    5. SOURCE SHAPE -- a present source authorization's collection window lies inside its signed
       envelope, and its plan/range digests are well-formed, required for scheduler scan kinds.
       Source authorization is verified WHEN THE RECORD CARRIES ONE; nothing here requires a
       generic telemetry, event or inventory record to present a scanner collection capability.
    6. SIGNATURES -- production and (if present) source capabilities verify under keys the trust
       snapshot authorizes for exactly that role. A key id the snapshot does not hold is withheld
       as unavailable; a known key outside that role is rejected. The worst status wins: a
       compromise-revoked key on either makes the frame a SECURITY QUARANTINE, before fence or
       window classification.
    7. AUTHORITY -- the producer fence and the production window decide publication. A producer
       with no fence entry, or one ahead of its entry, is withheld: this gateway does not know its
       authority is current. Current authority under a current fence publishes PRIMARY (a valid
       attached delivery grant only
       changes the delivery mode to renewal/rollover). Otherwise only a current delivery grant can
       authorize delivery: an expired grant under a current fence is an ordinary late drain
       (PRIMARY, renewal/rollover mode); a STALE fence is an immutable replay published only for
       AUDIT, stamped `LATE_FENCED_DELIVERY` with the delivery proof, and fenced from
       authoritative projection.

  ## Refusal classes

  `{:error, class, reason, event_id}`: `:permanent` resolves the sequence as a rejection;
  `:retryable` withholds it (the condition can clear -- a renewal, a learned fence or key, a clock
  that catches up); `:paused` means this release cannot evaluate the record. `event_id` is empty only
  for a refusal made before the record decoded.
  """

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.RecordValidate
  alias ServiceRadar.Edge.SemanticValidate
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadarAgentGateway.EdgeRecordTrust

  @agent_origin :EDGE_ORIGIN_KIND_AGENT
  @scan_kinds [:EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP, :EDGE_SOURCE_AUTHORIZATION_KIND_SWEEP_PROFILE]
  @permanent_wire_reasons [:too_large, :poison]

  @type publication :: :primary | :audit | :security_quarantine
  @type decision :: %{
          record: struct(),
          publication: publication(),
          delivery_mode: pos_integer(),
          delivery_proof: binary() | nil,
          grant: :none | :renewal | :rollover
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
    with :ok <- frame_digest(frame),
         :ok <- delivery_binding(frame),
         {:ok, record} <- validate_record(frame.record_bytes),
         :ok <- with_event(delivery_event_binding(frame, record), record),
         :ok <- with_event(origin_identity(record, identity), record),
         :ok <- with_event(network_scope(record, identity), record),
         :ok <- with_event(route_class(record, lane), record),
         :ok <- with_event(source_shape(record), record),
         {:ok, status} <- with_event(record_key_status(record, snapshot), record) do
      record
      |> decide(frame, status, snapshot, now_unix_nano)
      |> with_event(record)
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
        {:ok, record}

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

  defp network_scope(record, identity) do
    case Map.get(identity, :network_scope_ids) do
      nil -> {:error, :retryable, :scope_unbound, ""}
      scopes -> check(MapSet.member?(scopes, record.network_scope_id), :permanent, :scope_conflict)
    end
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

  # --- 6. signatures ---------------------------------------------------------------------------

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

      {:error, :key_unavailable} ->
        {:error, :retryable, {purpose, :key_unavailable}, ""}

      {:error, reason} ->
        {:error, :permanent, {purpose, reason}, ""}
    end
  end

  defp worst(:historically_revoked, _), do: :historically_revoked
  defp worst(_, :historically_revoked), do: :historically_revoked
  defp worst(status, _), do: status

  # --- 7. authority ----------------------------------------------------------------------------

  # A compromise-revoked production or source key is a security downgrade that needs no delivery
  # grant and precedes fence and window classification.
  defp decide(record, _frame, :historically_revoked, _snapshot, _now) do
    {:ok, decision(record, :security_quarantine, PublicationIdentity.mode_fresh(), nil, :none)}
  end

  defp decide(record, frame, :valid, snapshot, now) do
    context = record.producer_context
    cap = record.production_capability
    tolerance = snapshot.clock_tolerance_nano
    fence_key = {record.network_scope_id, context.producer_assignment_id, context.run_shard}
    fence = EdgeRecordTrust.fence_relation(snapshot, fence_key, context.authority_epoch)
    dc = frame.delivery_capability

    cond do
      fence in [:future, :unavailable] ->
        {:error, :retryable, :fence_not_ready, ""}

      # A future-dated grant is never usable early, even with a current delivery grant.
      now < cap.not_before_unix_nano - tolerance ->
        {:error, :retryable, :authority_not_yet_valid, ""}

      current_authority?(fence, cap, now, tolerance) ->
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

  defp decision(record, publication, mode, proof, grant) do
    %{record: record, publication: publication, delivery_mode: mode, delivery_proof: proof, grant: grant}
  end

  # Refusals after the record decoded carry its event id, so the agent can bind the disposition
  # to the event it sent for that sequence.
  defp with_event({:error, class, reason, ""}, record), do: {:error, class, reason, record.event_id}
  defp with_event(result, _record), do: result

  defp check(true, _class, _reason), do: :ok
  defp check(false, class, reason), do: {:error, class, reason, ""}
end
