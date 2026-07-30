defmodule ServiceRadar.Edge.ClaimsFraming do
  @moduledoc """
  Elixir peer of `go/pkg/edge/edgerecord/claims_framing.go`. Frames the nested
  messages that participate in a signing/digest preimage field-by-field, so no
  protobuf-elixir whole-message encode -- which diverges from protobuf-go on oneof
  member ordering and default elision -- appears in any preimage at any depth.

  Shared by `ServiceRadar.Edge.SemanticDigest` (the capability sub-frame and the
  output_contract frame) and `ServiceRadar.Edge.CapabilitySigning` (the signed
  claims), so both bind the claims identically. The framing primitives MUST match
  the Go `digestWriter`: 8-byte big-endian ints, 8-byte length-prefixed bytes/str,
  1-byte presence, and a u64 oneof discriminant equal to the set member's proto
  field number.
  """

  alias Serviceradar.Edge.V1.EdgeCapabilityPurpose
  alias Serviceradar.Edge.V1.EdgeOriginKind
  alias Serviceradar.Edge.V1.EdgeRecordRouteProfile
  alias Serviceradar.Edge.V1.EdgeRecordTrafficClass
  alias Serviceradar.Edge.V1.EdgeSourceAuthorizationKind

  @doc "Frames EdgeOutputContractRef: presence + 6 fields inline (digestWriter.outputContract)."
  @spec output_contract(map() | nil) :: iodata()
  def output_contract(nil), do: present(false)

  def output_contract(c) do
    [
      present(true),
      bytes(c.contract_id || ""),
      u64(c.contract_version || 0),
      bytes(c.contract_bundle_sha256),
      u64(c.registry_epoch || 0),
      bytes(c.registry_snapshot_sha256),
      bytes(c.effective_grant_sha256)
    ]
  end

  @doc """
  Frames the capability `claims` oneof: a u64 discriminant equal to the set member's PROTO
  FIELD NUMBER -- 7 production, 8 source, 9 delivery, 11 collection, 12 assignment_execution,
  or 0 for none -- followed by the selected claim framed field-by-field. Mirror of
  digestWriter.claimsFramed.

  The discriminant is the FIELD NUMBER, not the clause's position here: `collection` took 11
  because `signature` already held 10, and `assignment_execution` took 12. A variant with no
  clause falls through to 0 AND signs purpose 0, which no verifier accepts -- adding a
  variant means adding BOTH its clause here and its value in `CapabilitySigning`.
  """
  @spec claims_framed(term()) :: iodata()
  def claims_framed({:production, m}), do: [u64(7), production_claims(m)]
  def claims_framed({:source, m}), do: [u64(8), source_claims(m)]
  def claims_framed({:delivery, m}), do: [u64(9), delivery_claims(m)]
  def claims_framed({:collection, m}), do: [u64(11), collection_claims(m)]
  def claims_framed({:assignment_execution, m}), do: [u64(12), execution_grant_claims(m)]
  def claims_framed(_), do: u64(0)

  # EdgeCollectionClaimsV1 (fields 1-11, in field order). The scheduler's ATTESTATION of a
  # compiled carrier. `compiled_assignment_body_sha256` is the load-bearing member: it commits
  # every compiled fact, so this claim attests config generation, result format, check set and
  # validity window TRANSITIVELY. It is the BODY digest and not the artifact address, because
  # the artifact address covers this capability -- signing it would require the signature to
  # cover itself.
  defp collection_claims(m) do
    [
      u64(enum(EdgeCapabilityPurpose, m.purpose)),
      bytes(m.network_scope_id),
      bytes(m.authenticated_agent_id),
      bytes(m.execution_plan_id),
      bytes(m.target_range_id),
      u64(m.execution_shard || 0),
      u64(m.assignment_epoch || 0),
      bytes(m.compiled_assignment_body_sha256),
      u64(enum(EdgeRecordTrafficClass, m.traffic_class)),
      bytes(m.producer_assignment_id),
      bytes(m.execution_id)
    ]
  end

  # EdgeAssignmentExecutionClaimsV1 (fields 1-19, in field order). A HOST's permission to
  # execute ONE compiled carrier. The nested source identity is framed with an explicit
  # presence marker followed by its members. The marker is NOT what separates absent from
  # present-with-zeros -- the fixed member list already makes those frame differently. It is
  # kept for convention and because the committed preimage vector includes it.
  defp execution_grant_claims(m) do
    [
      u64(enum(EdgeCapabilityPurpose, m.purpose)),
      bytes(m.network_scope_id),
      bytes(m.authenticated_agent_id),
      bytes(m.producer_assignment_id),
      bytes(m.execution_id),
      bytes(m.run_id),
      u64(m.run_shard || 0),
      u64(m.authority_epoch || 0),
      bytes(m.production_scope_id),
      bytes(m.scope_sha256),
      bytes(m.contract_bundle_sha256),
      bytes(m.execution_plan_sha256),
      bytes(m.target_range_sha256),
      u64(enum(EdgeRecordTrafficClass, m.traffic_class)),
      i64(m.collection_not_before_unix_nano || 0),
      i64(m.collection_expires_unix_nano || 0),
      source_identity(m.source_identity),
      # Fields 18-19: the EXACT carrier this grant permits. Framed AFTER the nested identity,
      # matching Go's order -- the grammar is field order, and the nested member sits at 17.
      bytes(m.compiled_assignment_id),
      bytes(m.compiled_assignment_sha256)
    ]
  end

  defp source_identity(nil), do: present(false)

  defp source_identity(id) do
    [
      present(true),
      u64(enum(EdgeSourceAuthorizationKind, id.kind)),
      bytes(id.context_id),
      bytes(id.source_scope_id),
      bytes(id.source_scope_sha256)
    ]
  end

  # EdgeProductionClaimsV1 (field number 7; fields 1-23, in field order).
  defp production_claims(m) do
    [
      bytes(m.contract_id || ""),
      u64(m.contract_version || 0),
      bytes(m.contract_bundle_sha256),
      u64(m.registry_epoch || 0),
      bytes(m.network_scope_id),
      bytes(m.producer_assignment_id),
      u64(enum(EdgeRecordTrafficClass, m.traffic_class)),
      u64(enum(EdgeRecordRouteProfile, m.route_profile)),
      u64(enum(EdgeOriginKind, m.origin_kind)),
      bytes(m.origin_principal_id),
      bytes(m.producer_instance_id),
      bytes(m.run_id),
      u64(m.run_shard || 0),
      u64(m.authority_epoch || 0),
      bytes(m.scope_id),
      bytes(m.scope_sha256),
      bytes(m.package_sha256),
      bytes(m.registry_snapshot_sha256),
      bytes(m.effective_grant_sha256),
      u64(m.max_projected_row_count || 0),
      u64(m.max_projected_write_bytes || 0),
      u64(m.cost_model_version || 0),
      bytes(m.package_id || "")
    ]
  end

  # EdgeSourceClaimsV1 (fields 1-18, in field order).
  defp source_claims(m) do
    [
      u64(enum(EdgeSourceAuthorizationKind, m.kind)),
      bytes(m.context_id),
      bytes(m.scope_id),
      bytes(m.scope_sha256),
      bytes(m.network_scope_id),
      i64(m.collection_not_before_unix_nano || 0),
      i64(m.collection_expires_unix_nano || 0),
      bytes(m.origin_principal_id),
      bytes(m.producer_instance_id),
      bytes(m.producer_assignment_id),
      bytes(m.run_id),
      u64(m.run_shard || 0),
      u64(m.authority_epoch || 0),
      u64(enum(EdgeRecordTrafficClass, m.traffic_class)),
      u64(enum(EdgeRecordRouteProfile, m.route_profile)),
      bytes(m.execution_plan_sha256),
      bytes(m.target_range_sha256),
      u64(enum(EdgeOriginKind, m.origin_kind))
    ]
  end

  # EdgeDeliveryClaimsV1 (fields 1-4 + the transition oneof). The transition oneof
  # is field-framed because EdgeDeliveryClaimsV1 DOES carry a oneof -- a whole-
  # message encode would not be cross-language stable.
  defp delivery_claims(m) do
    [
      bytes(m.event_id),
      bytes(m.record_sha256),
      bytes(m.spool_id),
      u64(m.sequence || 0),
      transition(m.transition)
    ]
  end

  defp transition({:renewal, r}) do
    [u64(5), i64(r.renewed_not_before_unix_nano || 0), i64(r.renewed_expires_unix_nano || 0)]
  end

  defp transition({:rollover, r}) do
    [u64(6), bytes(r.recovery_id), bytes(r.prior_spool_id), u64(r.prior_sequence || 0)]
  end

  defp transition(_), do: u64(0)

  # --- framing primitives (must match the Go digestWriter) ---

  # CHECKED widths: an out-of-range integer would silently truncate under a fixed-width bitstring
  # (a preimage alias), so the width is guarded -- out-of-range fails loudly rather than aliasing.
  @u64_max 0xFFFF_FFFF_FFFF_FFFF
  @i64_min -0x8000_0000_0000_0000
  @i64_max 0x7FFF_FFFF_FFFF_FFFF
  defp u64(v) when is_integer(v) and v >= 0 and v <= @u64_max, do: <<v::big-64>>
  defp i64(v) when is_integer(v) and v >= @i64_min and v <= @i64_max, do: <<v::big-signed-64>>
  defp bytes(nil), do: <<0::big-64>>
  defp bytes(b) when is_binary(b), do: [<<byte_size(b)::big-64>>, b]
  defp present(true), do: <<1>>
  defp present(false), do: <<0>>

  defp enum(_mod, nil), do: 0
  defp enum(_mod, v) when is_integer(v), do: v
  defp enum(mod, v) when is_atom(v), do: mod.value(v)
end
