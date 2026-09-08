defmodule ServiceRadar.Edge.RecordValidate do
  @moduledoc """
  Complete structural admission of raw `EdgeRecordV1` bytes.

  The curated decoder enforces the received-byte ceiling and recursive wire
  hygiene before decoding. This boundary then checks payload binding, contract,
  producer, capability/record relations, costs, recovery routing, identity time
  and semantic digest. Capability checks are structural and pre-signature:
  acceptance is not authentication or authorization. Domain-specific payload
  validation and live ingress attachment remain separate responsibilities.

  Only raw bytes enter this API. There is no public decoded helper claiming to
  see byte limits or unknown fields that a decoder might already have discarded.
  """

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.PlanValidate
  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.SemanticDigest
  alias ServiceRadar.Edge.SemanticValidate
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias ServiceRadar.Edge.WireDecode

  @contract_fields [
    :contract_id,
    :contract_version,
    :contract_bundle_sha256,
    :registry_epoch,
    :registry_snapshot_sha256,
    :effective_grant_sha256
  ]
  @producer_fields [
    :origin_kind,
    :origin_principal_id,
    :producer_instance_id,
    :producer_assignment_id,
    :run_id,
    :run_shard,
    :authority_epoch,
    :scope_id,
    :scope_sha256,
    :package_sha256,
    :package_id
  ]
  @source_producer_fields [
    :origin_kind,
    :origin_principal_id,
    :producer_instance_id,
    :producer_assignment_id,
    :run_id,
    :run_shard,
    :authority_epoch
  ]
  @lane_fields [:network_scope_id, :traffic_class, :route_profile]
  @max_record_bytes 512 * 1024
  @max_uuid_millis div(9_223_372_036_854_775_807, 1_000_000)

  @spec validate_bytes(term()) :: {:ok, EdgeRecordV1.t()} | {:error, term()}
  def validate_bytes(bytes) do
    case WireDecode.decode_record(bytes) do
      {:ok, record} ->
        with :ok <- validate_decoded(record), do: {:ok, record}

      {:error, reason} ->
        {:error, {:wire, reason}}
    end
  end

  defp validate_decoded(r) do
    with :ok <- SemanticValidate.validate_record(r),
         :ok <- check(PlanValidate.uuidv7?(r.event_id), :identity),
         :ok <- Compression.admit_record(r),
         :ok <- contract(r.output_contract),
         :ok <- producer(r.producer_context),
         :ok <- check(PlanValidate.canonical_uuid?(r.network_scope_id), :network_scope),
         :ok <- production(r),
         :ok <- check(r.cost_model_version > 0, :cost_model),
         :ok <- source(r),
         :ok <- recovery_lane(r),
         :ok <- identity_time(r),
         :ok <- check(byte_size(r.semantic_envelope_sha256) == 32, :digest_length),
         :ok <- check(SemanticDigest.compute(r) == r.semantic_envelope_sha256, :semantic_digest) do
      check(byte_size(EdgeRecordV1.encode(r)) <= @max_record_bytes, :record_too_large)
    end
  end

  defp contract(nil), do: {:error, :contract}

  defp contract(c) do
    check(
      c.contract_id != "" and String.valid?(c.contract_id) and c.contract_version > 0 and
        c.registry_epoch > 0 and byte_size(c.contract_bundle_sha256) == 32 and
        byte_size(c.registry_snapshot_sha256) == 32 and byte_size(c.effective_grant_sha256) == 32,
      :contract
    )
  end

  defp producer(nil), do: {:error, :producer_context}

  defp producer(p) do
    with :ok <- check(p.producer_instance_id != "", :producer_context),
         :ok <-
           check(
             PublicationIdentity.valid_authenticated_principal?(p.origin_principal_id),
             :principal
           ) do
      check(
        Enum.all?(
          [p.producer_assignment_id, p.run_id, p.scope_id],
          &PlanValidate.canonical_uuid?/1
        ) and
          byte_size(p.scope_sha256) == 32 and not is_nil(p.authority_epoch) and
          p.package_id != "" and String.valid?(p.package_id) and byte_size(p.package_sha256) == 32,
        :producer_context
      )
    end
  end

  defp production(r) do
    with :ok <-
           CapabilitySigning.validate(
             r.production_capability,
             :production
           ) do
      {:production, claims} = r.production_capability.claims

      check(
        same_fields?(claims, r.output_contract, @contract_fields) and
          same_fields?(claims, r, @lane_fields) and
          same_fields?(claims, r.producer_context, @producer_fields) and
          claims.cost_model_version == r.cost_model_version and
          r.projected_row_count <= claims.max_projected_row_count and
          r.projected_write_bytes <= claims.max_projected_write_bytes,
        :production_grant
      )
    end
  end

  defp source(%{source_authorization: nil}), do: :ok

  defp source(r) do
    sa = r.source_authorization

    with :ok <- CapabilitySigning.validate(sa.capability, :source) do
      {:source, claims} = sa.capability.claims

      check(
        same_fields?(claims, sa, [:kind, :context_id, :scope_id, :scope_sha256]) and
          PlanValidate.canonical_uuid?(sa.context_id) and
          PlanValidate.canonical_uuid?(sa.scope_id) and byte_size(sa.scope_sha256) == 32 and
          same_fields?(claims, r, @lane_fields) and
          same_fields?(claims, r.producer_context, @source_producer_fields),
        :source_authorization
      )
    end
  end

  defp recovery_lane(r) do
    payload? = r.payload_family == :EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1
    route? = r.route_profile == :EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1

    authority? =
      not is_nil(r.source_authorization) and
        r.source_authorization.kind == :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL

    check(payload? == route? and payload? == authority?, :recovery_lane)
  end

  defp identity_time(r) do
    <<millis::48, _::80>> = r.event_id

    if millis > @max_uuid_millis do
      {:error, :identity_time}
    else
      nanos = millis * 1_000_000
      pc = r.production_capability

      check(
        within?(nanos, pc.not_before_unix_nano, pc.expires_at_unix_nano) and
          source_time?(nanos, r.source_authorization),
        :identity_time
      )
    end
  end

  defp source_time?(_nanos, nil), do: true

  defp source_time?(nanos, sa) do
    cap = sa.capability
    {:source, claims} = cap.claims

    within?(nanos, cap.not_before_unix_nano, cap.expires_at_unix_nano) and
      within?(nanos, claims.collection_not_before_unix_nano, claims.collection_expires_unix_nano)
  end

  defp within?(value, first, last), do: value >= first and value <= last

  defp same_fields?(left, right, fields) do
    Enum.all?(fields, &(Map.fetch!(left, &1) == Map.fetch!(right, &1)))
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
