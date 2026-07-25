defmodule ServiceRadar.Edge.PublicationIdentity do
  @moduledoc """
  Elixir peer of `go/pkg/edge/edgerecord/publication_identity.go` (#4710 Appendix A
  grammars 6-8): the transport headers a gateway derives when publishing a record to
  JetStream. These are PROJECT-OWNED, field-framed codecs (NOT a protobuf message): each
  transcript leads with a string domain tag then a u64 version, then length-framed / fixed-width
  fields, byte-identical to the Go peer. `Nats-Msg-Id` / `Sr-Edge-Delivery-Id` are
  base64url(no-pad) of the SHA-256 of the transcript; `Sr-Edge-Transport-Provenance` is
  base64url(no-pad) of the framed envelope itself (not a digest), bounded to 512 header bytes.

  `spool_id` is the persistent UUIDv7 for one delivery lane, so there is no separate `lane_id`.
  An edge slot is a map with `:network_scope_id`, `:authenticated_agent_id`, `:spool_id`,
  `:sequence`; a service slot has `:network_scope_id`, `:authenticated_service_id`,
  `:publication_lane_id`, `:publication_sequence`. `authenticated_agent_id` is the authenticated
  principal and MUST equal `producer_context.origin_principal_id`.

  The encoders VALIDATE their inputs and fail closed with `{:error, reason}`;
  `decode_transport_provenance/1` is the strict decoder EventWriter uses (rejecting
  non-canonical base64, unknown version/kind/mode, bad length prefixes, trailing bytes);
  `extract_header_set/1` is the raw multimap boundary that rejects duplicate/case-variant
  headers; `validate_header_set/2` recomputes and cross-checks the whole header set against the
  record- and credential-derived trust context (scope, origin kind, publisher class, principal).
  There is NO separate `Sr-Edge-Route-Map-Version` header -- route_map_version travels only in
  the provenance envelope.
  """

  alias ServiceRadar.Edge.CapabilitySigning
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1

  @msgid_version 1
  @delivery_id_version 1
  @transport_provenance_version 1
  @max_transport_provenance_header 512
  @max_principal_bytes 128
  @proof_digest_len 32
  @u64_max 0xFFFF_FFFF_FFFF_FFFF
  @i64_min -0x8000_0000_0000_0000
  @i64_max 0x7FFF_FFFF_FFFF_FFFF

  @msgid_domain "serviceradar.edge.msgid"
  @msgid_service_domain "serviceradar.edge.msgid.service"
  @delivery_id_domain "serviceradar.edge.delivery-id"
  @delivery_id_service_domain "serviceradar.edge.delivery-id.service"
  @transport_provenance_domain "serviceradar.edge.transport-provenance"

  # Required publication-identity header names (lowercase for case-insensitive matching). There is
  # NO Sr-Edge-Route-Map-Version header -- route_map_version travels only in the provenance envelope.
  @header_nats_msg_id "nats-msg-id"
  @header_delivery_id "sr-edge-delivery-id"
  @header_provenance "sr-edge-transport-provenance"

  # Slot-kind discriminant (0 is never emitted; a received 0 is rejected fail-closed).
  @slot_edge 1
  @slot_service 2

  # Gateway-attested delivery mode (replaces the old source_kind).
  @mode_fresh 1
  @mode_renewal 2
  @mode_rollover 3
  @mode_late_fenced 4
  @modes [@mode_fresh, @mode_renewal, @mode_rollover, @mode_late_fenced]

  @doc "Delivery-mode constants for callers building provenance inputs."
  def mode_fresh, do: @mode_fresh
  def mode_renewal, do: @mode_renewal
  def mode_rollover, do: @mode_rollover
  def mode_late_fenced, do: @mode_late_fenced

  @doc """
  Enforces the frozen authenticated-principal encoding: exact case-sensitive ASCII bytes,
  charset `[A-Za-z0-9_-]`, length 1..128. The same value feeds Msg-Id, Delivery-Id, and
  provenance and MUST equal `producer_context.origin_principal_id`.
  """
  @spec valid_authenticated_principal?(binary()) :: boolean()
  def valid_authenticated_principal?(id)
      when is_binary(id) and byte_size(id) >= 1 and byte_size(id) <= @max_principal_bytes do
    for_result = for(<<c <- id>>, do: c)

    Enum.all?(for_result, fn c ->
      c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c == ?_ or c == ?-
    end)
  end

  def valid_authenticated_principal?(_), do: false

  # --- slot validation (fail closed) ---

  defp validate_edge_slot(slot) when is_map(slot) do
    cond do
      not valid_authenticated_principal?(Map.get(slot, :authenticated_agent_id)) ->
        {:error, :principal}

      not canonical_uuid?(Map.get(slot, :network_scope_id)) ->
        {:error, :network_scope}

      not uuid_v7?(Map.get(slot, :spool_id)) ->
        {:error, :spool_id}

      not u64_seq?(Map.get(slot, :sequence)) ->
        {:error, :sequence}

      true ->
        :ok
    end
  end

  defp validate_edge_slot(_), do: {:error, :slot}

  defp validate_service_slot(slot) when is_map(slot) do
    cond do
      not valid_authenticated_principal?(Map.get(slot, :authenticated_service_id)) ->
        {:error, :principal}

      not canonical_uuid?(Map.get(slot, :network_scope_id)) ->
        {:error, :network_scope}

      not uuid_v7?(Map.get(slot, :publication_lane_id)) ->
        {:error, :publication_lane_id}

      not u64_seq?(Map.get(slot, :publication_sequence)) ->
        {:error, :publication_sequence}

      true ->
        :ok
    end
  end

  defp validate_service_slot(_), do: {:error, :slot}

  # network_scope_id is a canonical UUID (any version 1..8); spool_id / publication_lane_id are
  # UUIDv7. Validate UUID SEMANTICS (16 bytes + RFC variant bits, version nibble), not merely
  # shape, mirroring the Go ValidateCanonicalUUID / ValidateUUIDv7 helpers.
  defp canonical_uuid?(<<_::binary-6, ver::8, _::8, var::8, _::binary-7>>),
    do: Bitwise.bsr(ver, 4) in 1..8 and Bitwise.band(var, 0xC0) == 0x80

  defp canonical_uuid?(_), do: false

  defp uuid_v7?(<<_::binary-6, ver::8, _::8, var::8, _::binary-7>>),
    do: Bitwise.band(ver, 0xF0) == 0x70 and Bitwise.band(var, 0xC0) == 0x80

  defp uuid_v7?(_), do: false
  # Sequences start at 1 and are strictly nonzero; also caps at u64 (the <<v::big-64>> guard).
  defp u64_seq?(v), do: is_integer(v) and v >= 1 and v <= @u64_max
  defp i64?(v), do: is_integer(v) and v >= @i64_min and v <= @i64_max
  defp digest?(b), do: is_binary(b) and byte_size(b) == @proof_digest_len

  defp require_digest(b), do: if(digest?(b), do: :ok, else: {:error, :digest_len})

  # --- grammar 6: Nats-Msg-Id ---

  @spec nats_msg_id(map(), binary(), binary()) :: {:ok, binary()} | {:error, atom()}
  def nats_msg_id(slot, semantic_envelope_sha256, record_sha256) do
    with {:ok, pre} <- nats_msg_id_preimage(slot, semantic_envelope_sha256, record_sha256) do
      {:ok, b64url(:crypto.hash(:sha256, pre))}
    end
  end

  @spec nats_msg_id_preimage(map(), binary(), binary()) :: {:ok, binary()} | {:error, atom()}
  def nats_msg_id_preimage(slot, semantic_envelope_sha256, record_sha256) do
    with :ok <- validate_edge_slot(slot),
         :ok <- require_digest(semantic_envelope_sha256),
         :ok <- require_digest(record_sha256) do
      {:ok,
       IO.iodata_to_binary([
         str(@msgid_domain),
         u64(@msgid_version),
         bytes(slot.authenticated_agent_id),
         bytes(slot.network_scope_id),
         bytes(slot.spool_id),
         u64(slot.sequence),
         bytes(semantic_envelope_sha256),
         bytes(record_sha256)
       ])}
    end
  end

  @spec service_nats_msg_id(map(), binary(), binary()) :: {:ok, binary()} | {:error, atom()}
  def service_nats_msg_id(slot, semantic_envelope_sha256, record_sha256) do
    with {:ok, pre} <- service_nats_msg_id_preimage(slot, semantic_envelope_sha256, record_sha256) do
      {:ok, b64url(:crypto.hash(:sha256, pre))}
    end
  end

  @spec service_nats_msg_id_preimage(map(), binary(), binary()) ::
          {:ok, binary()} | {:error, atom()}
  def service_nats_msg_id_preimage(slot, semantic_envelope_sha256, record_sha256) do
    with :ok <- validate_service_slot(slot),
         :ok <- require_digest(semantic_envelope_sha256),
         :ok <- require_digest(record_sha256) do
      {:ok,
       IO.iodata_to_binary([
         str(@msgid_service_domain),
         u64(@msgid_version),
         bytes(slot.authenticated_service_id),
         bytes(slot.network_scope_id),
         bytes(slot.publication_lane_id),
         u64(slot.publication_sequence),
         bytes(semantic_envelope_sha256),
         bytes(record_sha256)
       ])}
    end
  end

  # --- grammar 7: Sr-Edge-Delivery-Id ---

  @spec delivery_id(map()) :: {:ok, binary()} | {:error, atom()}
  def delivery_id(slot) do
    with {:ok, pre} <- delivery_id_preimage(slot) do
      {:ok, b64url(:crypto.hash(:sha256, pre))}
    end
  end

  @spec delivery_id_preimage(map()) :: {:ok, binary()} | {:error, atom()}
  def delivery_id_preimage(slot) do
    with :ok <- validate_edge_slot(slot) do
      {:ok,
       IO.iodata_to_binary([
         str(@delivery_id_domain),
         u64(@delivery_id_version),
         bytes(slot.network_scope_id),
         bytes(slot.authenticated_agent_id),
         bytes(slot.spool_id),
         u64(slot.sequence)
       ])}
    end
  end

  @spec service_delivery_id(map()) :: {:ok, binary()} | {:error, atom()}
  def service_delivery_id(slot) do
    with {:ok, pre} <- service_delivery_id_preimage(slot) do
      {:ok, b64url(:crypto.hash(:sha256, pre))}
    end
  end

  @spec service_delivery_id_preimage(map()) :: {:ok, binary()} | {:error, atom()}
  def service_delivery_id_preimage(slot) do
    with :ok <- validate_service_slot(slot) do
      {:ok,
       IO.iodata_to_binary([
         str(@delivery_id_service_domain),
         u64(@delivery_id_version),
         bytes(slot.network_scope_id),
         bytes(slot.authenticated_service_id),
         bytes(slot.publication_lane_id),
         u64(slot.publication_sequence)
       ])}
    end
  end

  # --- grammar 8: Sr-Edge-Transport-Provenance ---

  @doc """
  SHA-256 (32 bytes) over the DELIVERY capability's grammar-2 signing bytes, for a
  RENEWAL/ROLLOVER/LATE_FENCED_DELIVERY provenance proof. The ACTUAL gateway is Elixir, so it must
  never hash an arbitrary binary: the capability is STRUCTURALLY validated (delivery purpose,
  version/issuer/algorithm/window/signature via `CapabilitySigning.validate/2`) AND its transition
  must match the claimed mode (RENEWAL->renewal, ROLLOVER->rollover, LATE_FENCED_DELIVERY->renewal
  OR rollover) BEFORE hashing. Returns `{:ok, digest}` or `{:error, reason}`.
  """
  @spec delivery_proof_digest(EdgeSignedCapabilityV1.t(), non_neg_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def delivery_proof_digest(%EdgeSignedCapabilityV1{} = capability, mode) do
    with :ok <- validate_delivery_capability(capability, mode) do
      {:ok, :crypto.hash(:sha256, CapabilitySigning.signing_bytes(capability))}
    end
  end

  def delivery_proof_digest(_, _), do: {:error, :capability}

  defp validate_delivery_capability(capability, mode) do
    # CapabilitySigning.validate/2 recursively rejects unsigned unknown fields (shared signing
    # validator), so the proof path inherits it; here we add the transition-vs-mode match and the
    # COMPLETE nested-claim structural checks.
    with :ok <- CapabilitySigning.validate(capability, :delivery),
         {:ok, transition} <- delivery_transition(capability) do
      cond do
        mode == @mode_renewal and transition == :renewal -> :ok
        mode == @mode_rollover and transition == :rollover -> :ok
        mode == @mode_late_fenced and transition in [:renewal, :rollover] -> :ok
        mode in @modes -> {:error, :transition}
        true -> {:error, :delivery_mode}
      end
    end
  end

  # Extracts the delivery transition KIND, requiring a PRESENT, NON-NIL member struct (a nil member
  # e.g. `{:renewal, nil}` would crash the field-framing) AND a COMPLETE, well-formed nested claim.
  defp delivery_transition(capability) do
    case capability.claims do
      {:delivery, %{transition: {kind, member}} = claims}
      when kind in [:renewal, :rollover] and is_struct(member) ->
        if valid_delivery_claims?(claims), do: {:ok, kind}, else: {:error, :claims}

      {:delivery, _} ->
        {:error, :transition}

      _ ->
        {:error, :claims}
    end
  end

  # Complete EdgeDeliveryClaimsV1 structural check -- the Elixir peer of Go `validateDeliveryClaims`:
  # bound event_id/spool_id (UUIDv7), record_sha256 (32 bytes), a nonzero sequence, AND a well-formed
  # transition member (renewal window well-ordered with in-range i64 endpoints; rollover recovery_id
  # + prior_spool_id UUIDv7, prior_spool_id != spool_id, prior_sequence >= 1).
  defp valid_delivery_claims?(claims) do
    uuid_v7?(Map.get(claims, :event_id)) and digest?(Map.get(claims, :record_sha256)) and
      uuid_v7?(Map.get(claims, :spool_id)) and u64_seq?(Map.get(claims, :sequence)) and
      valid_transition?(Map.get(claims, :transition), Map.get(claims, :spool_id))
  end

  defp valid_transition?({:renewal, %{} = r}, _spool_id) do
    nb = Map.get(r, :renewed_not_before_unix_nano) || 0
    ex = Map.get(r, :renewed_expires_unix_nano) || 0
    i64?(nb) and i64?(ex) and ex > nb
  end

  defp valid_transition?({:rollover, %{} = ro}, spool_id) do
    prior = Map.get(ro, :prior_spool_id)

    uuid_v7?(Map.get(ro, :recovery_id)) and uuid_v7?(prior) and prior != spool_id and
      u64_seq?(Map.get(ro, :prior_sequence))
  end

  defp valid_transition?(_, _), do: false

  @doc """
  base64url(no-pad)-encodes the framed grammar-8 envelope (NOT a digest). `input` carries
  exactly one of `:edge` / `:service` slot, `:record_sha256`, a `:delivery_mode`
  (1=FRESH / 2=RENEWAL / 3=ROLLOVER / 4=LATE_FENCED_DELIVERY), `:delivery_proof` (nil for FRESH,
  exactly 32 bytes otherwise), and a nonzero `:route_map_version`. Service slots are FRESH-only.
  Returns `{:ok, header}` or `{:error, reason}`.
  """
  @spec transport_provenance(map()) :: {:ok, binary()} | {:error, atom()}
  def transport_provenance(input) do
    with {:ok, framed} <- transport_provenance_preimage(input) do
      header = b64url(framed)

      if byte_size(header) > @max_transport_provenance_header,
        do: {:error, :too_large},
        else: {:ok, header}
    end
  end

  @doc "Raw framed grammar-8 envelope (before base64url); `{:ok, binary}` or `{:error, reason}`."
  @spec transport_provenance_preimage(map()) :: {:ok, binary()} | {:error, atom()}
  def transport_provenance_preimage(input) when is_map(input) do
    edge = Map.get(input, :edge)
    service = Map.get(input, :service)
    mode = Map.get(input, :delivery_mode)
    proof = Map.get(input, :delivery_proof)
    record_sha = Map.get(input, :record_sha256)
    rmv = Map.get(input, :route_map_version, 0)

    cond do
      edge == nil == (service == nil) -> {:error, :slot_arity}
      mode not in @modes -> {:error, :delivery_mode}
      not (is_integer(rmv) and rmv >= 1 and rmv <= @u64_max) -> {:error, :route_map}
      not digest?(record_sha) -> {:error, :record_sha}
      service != nil and mode != @mode_fresh -> {:error, :service_not_fresh}
      mode == @mode_fresh and proof != nil -> {:error, :proof}
      mode != @mode_fresh and not digest?(proof) -> {:error, :proof}
      true -> frame_provenance(edge, service, input, proof)
    end
  end

  def transport_provenance_preimage(_), do: {:error, :input}

  defp frame_provenance(edge, service, input, proof) do
    with {:ok, slot_io} <- slot_iodata(edge, service) do
      proof_io = if proof, do: [present(true), bytes(proof)], else: [present(false)]

      framed =
        IO.iodata_to_binary([
          str(@transport_provenance_domain),
          u64(@transport_provenance_version),
          slot_io,
          bytes(input.record_sha256),
          proof_io,
          u64(input.delivery_mode),
          u64(input.route_map_version)
        ])

      {:ok, framed}
    end
  end

  defp slot_iodata(edge, nil) do
    with :ok <- validate_edge_slot(edge) do
      {:ok,
       [
         u64(@slot_edge),
         bytes(edge.network_scope_id),
         bytes(edge.authenticated_agent_id),
         bytes(edge.spool_id),
         u64(edge.sequence)
       ]}
    end
  end

  defp slot_iodata(nil, service) do
    with :ok <- validate_service_slot(service) do
      {:ok,
       [
         u64(@slot_service),
         bytes(service.network_scope_id),
         bytes(service.authenticated_service_id),
         bytes(service.publication_lane_id),
         u64(service.publication_sequence)
       ]}
    end
  end

  @doc """
  Strictly decodes a base64url(no-pad) transport-provenance header: requires CANONICAL
  base64url (no aliasing), the frozen domain/version, a known slot kind, bounded length
  prefixes, a 0x00/0x01 presence byte, a known delivery_mode, a nonzero route_map_version, the
  FRESH/proof invariant, and EXACT end-of-input. Returns `{:ok, map}` (with `:kind` of
  `:edge`/`:service`, `:slot`, `:record_sha256`, `:delivery_mode`, `:delivery_proof`,
  `:route_map_version`) or `{:error, reason}`.
  """
  @spec decode_transport_provenance(binary()) :: {:ok, map()} | {:error, atom()}
  def decode_transport_provenance(header) when is_binary(header) do
    with :ok <- check_header_size(header),
         {:ok, raw} <- strict_b64_decode(header),
         {:ok, rest0} <- expect_str(raw, @transport_provenance_domain),
         {:ok, ver, rest1} <- take_u64(rest0),
         :ok <- expect(ver == @transport_provenance_version, :unknown_version),
         {:ok, kind, rest2} <- take_u64(rest1),
         {:ok, slot_kind, slot, rest3} <- take_slot(kind, rest2),
         {:ok, record_sha, rest4} <- take_bytes(rest3),
         :ok <- expect(digest?(record_sha), :record_sha_len),
         {:ok, proof, rest5} <- take_proof(rest4),
         {:ok, mode, rest6} <- take_u64(rest5),
         :ok <- expect(mode in @modes, :unknown_mode),
         {:ok, rmv, rest7} <- take_u64(rest6),
         :ok <- expect(rmv != 0, :route_map),
         :ok <- expect(rest7 == <<>>, :trailing),
         :ok <- expect(mode == @mode_fresh == (proof == nil), :proof),
         :ok <- expect(not (slot_kind == :service and mode != @mode_fresh), :service_not_fresh) do
      {:ok,
       %{
         kind: slot_kind,
         slot: slot,
         record_sha256: record_sha,
         delivery_mode: mode,
         delivery_proof: proof,
         route_map_version: rmv
       }}
    end
  end

  def decode_transport_provenance(_), do: {:error, :input}

  defp check_header_size(h) when byte_size(h) > @max_transport_provenance_header,
    do: {:error, :too_large}

  defp check_header_size(_), do: :ok

  # Elixir has no strict base64 mode; re-encode the decoded bytes and require an exact match to
  # reject non-canonical aliases (trailing bits set).
  defp strict_b64_decode(h) do
    case Base.url_decode64(h, padding: false) do
      {:ok, raw} ->
        if b64url(raw) == h, do: {:ok, raw}, else: {:error, :non_canonical_base64}

      :error ->
        {:error, :bad_base64}
    end
  end

  defp expect(true, _), do: :ok
  defp expect(false, reason), do: {:error, reason}

  defp take_u64(<<v::big-64, rest::binary>>), do: {:ok, v, rest}
  defp take_u64(_), do: {:error, :truncated_u64}

  defp take_bytes(<<n::big-64, rest::binary>>) when n <= byte_size(rest) do
    <<field::binary-size(n), rest2::binary>> = rest
    {:ok, field, rest2}
  end

  defp take_bytes(<<_::big-64, _::binary>>), do: {:error, :length_prefix}
  defp take_bytes(_), do: {:error, :truncated_bytes}

  defp expect_str(raw, want) do
    with {:ok, got, rest} <- take_bytes(raw) do
      if got == want, do: {:ok, rest}, else: {:error, :domain}
    end
  end

  defp take_slot(@slot_edge, raw) do
    with {:ok, ns, r1} <- take_bytes(raw),
         {:ok, agent, r2} <- take_bytes(r1),
         {:ok, spool, r3} <- take_bytes(r2),
         {:ok, seq, r4} <- take_u64(r3),
         slot = %{
           network_scope_id: ns,
           authenticated_agent_id: agent,
           spool_id: spool,
           sequence: seq
         },
         :ok <- validate_edge_slot(slot) do
      {:ok, :edge, slot, r4}
    end
  end

  defp take_slot(@slot_service, raw) do
    with {:ok, ns, r1} <- take_bytes(raw),
         {:ok, svc, r2} <- take_bytes(r1),
         {:ok, lane, r3} <- take_bytes(r2),
         {:ok, seq, r4} <- take_u64(r3),
         slot = %{
           network_scope_id: ns,
           authenticated_service_id: svc,
           publication_lane_id: lane,
           publication_sequence: seq
         },
         :ok <- validate_service_slot(slot) do
      {:ok, :service, slot, r4}
    end
  end

  defp take_slot(_, _), do: {:error, :unknown_slot_kind}

  defp take_proof(<<0x00, rest::binary>>), do: {:ok, nil, rest}

  defp take_proof(<<0x01, rest::binary>>) do
    with {:ok, proof, rest2} <- take_bytes(rest),
         :ok <- expect(digest?(proof), :proof_len) do
      {:ok, proof, rest2}
    end
  end

  defp take_proof(_), do: {:error, :presence_byte}

  @doc """
  Raw header-multimap extraction boundary: pulls the three required publication-identity headers
  from a `%{name => value | [values]}` map or a `[{name, value}]` list, matching names
  CASE-INSENSITIVELY and requiring EXACTLY ONE non-empty value each. A missing, empty, or duplicate
  (repeated under one key OR under case-variant keys) header is rejected fail-closed -- the scalar
  validator cannot see duplicates, so this boundary catches them. There is NO
  Sr-Edge-Route-Map-Version header. Returns `{:ok, %{nats_msg_id, delivery_id, provenance}}`.
  """
  @spec extract_header_set(map() | list()) :: {:ok, map()} | {:error, atom()}
  def extract_header_set(headers) when is_map(headers) or is_list(headers) do
    with pairs when is_list(pairs) <- normalize_headers(headers),
         :ok <- ensure_binary_pairs(pairs) do
      by_lower =
        Enum.reduce(pairs, %{}, fn {name, value}, acc ->
          Map.update(acc, String.downcase(name), [value], &(&1 ++ [value]))
        end)

      with {:ok, msg} <- one_header(by_lower, @header_nats_msg_id),
           {:ok, del} <- one_header(by_lower, @header_delivery_id),
           {:ok, prov} <- one_header(by_lower, @header_provenance) do
        {:ok, %{nats_msg_id: msg, delivery_id: del, provenance: prov}}
      end
    end
  end

  def extract_header_set(_), do: {:error, :headers}

  defp normalize_headers(headers) when is_map(headers) do
    Enum.flat_map(headers, fn {name, values} ->
      values = if is_list(values), do: values, else: [values]
      Enum.map(values, fn v -> {name, v} end)
    end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    if Enum.all?(headers, &match?({_, _}, &1)) do
      headers
    else
      {:error, :headers}
    end
  end

  # Header names AND values MUST be binaries: a non-binary name would raise on downcase and a
  # non-binary value (e.g. an integer) must never slip into a "valid" header set.
  defp ensure_binary_pairs(pairs) do
    if Enum.all?(pairs, fn {name, value} -> is_binary(name) and is_binary(value) end),
      do: :ok,
      else: {:error, :headers}
  end

  defp one_header(by_lower, name) do
    case Map.get(by_lower, name, []) do
      [value] when value != "" -> {:ok, value}
      [] -> {:error, :missing_header}
      [""] -> {:error, :empty_header}
      _ -> {:error, :duplicate_header}
    end
  end

  @doc """
  EventWriter's complete header-set validator. Strictly decodes the provenance envelope,
  recomputes Nats-Msg-Id and Sr-Edge-Delivery-Id from the decoded slot and the record's
  authoritative fields, and CROSS-CHECKS byte-for-byte the record hash, the network scope, the
  slot kind vs record `origin_kind` AND the authenticated publisher class, and the provenance
  principal vs the record `origin_principal_id`. `:trusted_publisher_principal` (the
  credential-derived publisher identity) is compared to the record principal ONLY on the
  SERVICE-INGRESS path; for edge records the publisher is the gateway, whose credential identity
  differs from the agent principal by design, so it is ignored. `header_set` is
  `%{nats_msg_id, delivery_id, provenance}` (from `extract_header_set/1`); `ctx` carries
  `:record_network_scope_id`, `:record_origin_kind`, `:record_principal`,
  `:expected_publisher_class` (`:edge`/`:service`), `:trusted_publisher_principal`,
  `:semantic_envelope_sha256`, `:record_sha256`. Any disagreement fails closed.
  """
  @spec validate_header_set(map(), map()) :: :ok | {:error, atom()}
  def validate_header_set(header_set, ctx) when is_map(header_set) and is_map(ctx) do
    record_class = publisher_class_for_origin_kind(Map.get(ctx, :record_origin_kind))
    record_sha = Map.get(ctx, :record_sha256)

    with {:ok, dp} <- decode_transport_provenance(Map.get(header_set, :provenance)),
         :ok <- expect(dp.record_sha256 == record_sha, :record_hash),
         :ok <- expect(record_class != nil, :origin_kind),
         :ok <- expect(Map.get(ctx, :expected_publisher_class) == record_class, :publisher_class),
         {:ok, slot_class, slot_scope, slot_principal, want_msg, want_del} <-
           recompute_ids(dp, Map.get(ctx, :semantic_envelope_sha256), record_sha),
         :ok <- expect(slot_class == record_class, :slot_kind),
         :ok <- expect(slot_scope == Map.get(ctx, :record_network_scope_id), :network_scope),
         :ok <- expect(slot_principal == Map.get(ctx, :record_principal), :principal),
         :ok <-
           check_publisher_principal(
             slot_class,
             slot_principal,
             Map.get(ctx, :trusted_publisher_principal)
           ),
         :ok <- expect(Map.get(header_set, :nats_msg_id) == want_msg, :nats_msg_id) do
      expect(Map.get(header_set, :delivery_id) == want_del, :delivery_id)
    end
  end

  def validate_header_set(_, _), do: {:error, :input}

  # SERVICE-only: the governed service's credential resolves to its authenticated_service_id, which
  # MUST equal the record/provenance principal. NOT applied to edge -- the gateway's per-class NATS
  # credential identity differs from the originating agent principal by design.
  defp check_publisher_principal(:service, slot_principal, trusted),
    do: expect(slot_principal == trusted, :publisher_principal)

  defp check_publisher_principal(:edge, _slot_principal, _trusted), do: :ok

  defp recompute_ids(%{kind: :edge, slot: slot}, sed, record_sha) do
    with {:ok, msg} <- nats_msg_id(slot, sed, record_sha),
         {:ok, del} <- delivery_id(slot) do
      {:ok, :edge, slot.network_scope_id, slot.authenticated_agent_id, msg, del}
    end
  end

  defp recompute_ids(%{kind: :service, slot: slot}, sed, record_sha) do
    with {:ok, msg} <- service_nats_msg_id(slot, sed, record_sha),
         {:ok, del} <- service_delivery_id(slot) do
      {:ok, :service, slot.network_scope_id, slot.authenticated_service_id, msg, del}
    end
  end

  defp publisher_class_for_origin_kind(:EDGE_ORIGIN_KIND_AGENT), do: :edge
  defp publisher_class_for_origin_kind(:EDGE_ORIGIN_KIND_CLUSTER_SERVICE), do: :service
  defp publisher_class_for_origin_kind(_), do: nil

  # --- framing primitives (must match the Go digestWriter) ---

  # The u64 guard rejects negative / out-of-range integers that <<v::big-64>> would otherwise
  # silently alias modulo 2^64 (reviewer blocker at the former line 211).
  defp u64(v) when is_integer(v) and v >= 0 and v <= @u64_max, do: <<v::big-64>>
  defp bytes(nil), do: <<0::big-64>>
  defp bytes(b) when is_binary(b), do: [<<byte_size(b)::big-64>>, b]
  defp str(s), do: bytes(s)
  defp present(true), do: <<1>>
  defp present(false), do: <<0>>
  defp b64url(b), do: Base.url_encode64(b, padding: false)
end
