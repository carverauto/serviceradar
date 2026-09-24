defmodule ServiceRadar.Edge.SemanticDigest do
  @moduledoc """
  Elixir peer of `go/pkg/edge/edgerecord.SemanticEnvelopeDigest`. It recomputes
  the immutable semantic-envelope digest of an `EdgeRecordV1` from the decoded
  message, independently of Go, so gateway/EventWriter and the cross-language
  golden fixtures agree on semantic identity byte-for-byte. The layout MUST match
  the Go `digestWriter` exactly: a version tag, length-framed bytes/strings, 1-byte
  presence markers for optional fields, u64 oneof discriminants, and field-by-field
  framing of nested capability/authorization/contract messages -- NO protobuf
  serialization at any depth (protobuf has no canonical wire form).
  """

  alias ServiceRadar.Edge.ClaimsFraming
  alias Serviceradar.Edge.V1.EdgeRecordCompression
  alias Serviceradar.Edge.V1.EdgeRecordPayloadFamily
  alias Serviceradar.Edge.V1.EdgeRecordRouteProfile
  alias Serviceradar.Edge.V1.EdgeRecordTrafficClass
  alias Serviceradar.Edge.V1.EdgeRecordV1

  @version 3

  @doc "The 32-byte semantic-envelope digest of a decoded EdgeRecordV1."
  @spec compute(EdgeRecordV1.t()) :: binary()
  def compute(%EdgeRecordV1{} = r) do
    p = r.producer_context

    iodata = [
      u64(@version),
      bytes(r.event_id),
      u64(enum(EdgeRecordPayloadFamily, r.payload_family)),
      u64(enum(EdgeRecordCompression, r.compression)),
      u64(r.encoded_size || 0),
      u64(r.uncompressed_size || 0),
      bytes(r.payload_sha256),
      ClaimsFraming.output_contract(r.output_contract),
      present(p != nil),
      producer_context(p),
      u64(enum(EdgeRecordRouteProfile, r.route_profile)),
      u64(enum(EdgeRecordTrafficClass, r.traffic_class)),
      bytes(r.network_scope_id),
      capability(r.production_capability),
      source_auth(r.source_authorization),
      u64(r.projected_row_count || 0),
      u64(r.projected_write_bytes || 0),
      u64(r.cost_model_version || 0)
    ]

    :crypto.hash(:sha256, iodata)
  end

  defp producer_context(nil), do: []

  defp producer_context(p) do
    [
      u64(origin_kind(p.origin_kind)),
      bytes(p.origin_principal_id),
      bytes(p.producer_instance_id),
      bytes(p.producer_assignment_id),
      bytes(p.run_id),
      u64(p.run_shard || 0),
      opt_u64(p.authority_epoch),
      bytes(p.scope_id),
      bytes(p.scope_sha256),
      bytes(p.package_id || ""),
      bytes(p.package_sha256)
    ]
  end

  # EdgeOriginKind integer values are stable (0,1,2); resolve via the module.
  defp origin_kind(v) when is_integer(v), do: v
  defp origin_kind(v) when is_atom(v), do: Serviceradar.Edge.V1.EdgeOriginKind.value(v)

  # Signed capability framed field-by-field in canonical ascending field order,
  # mirroring digestWriter.capability in the Go peer. Whole-message marshal is
  # NOT used because protobuf-go emits the oneof claim after the higher-numbered
  # signature field, diverging from strict ascending encoders like protobuf-elixir.
  defp capability(nil), do: present(false)

  defp capability(c) do
    [
      present(true),
      u64(c.capability_version || 0),
      bytes(c.issuer_id),
      bytes(c.issuer_key_id),
      bytes(c.algorithm || ""),
      i64(c.not_before_unix_nano || 0),
      i64(c.expires_at_unix_nano || 0),
      ClaimsFraming.claims_framed(c.claims),
      bytes(c.signature)
    ]
  end

  defp source_auth(nil), do: present(false)

  defp source_auth(sa) do
    [
      present(true),
      u64(source_kind(sa.kind)),
      capability(sa.capability),
      bytes(sa.context_id),
      bytes(sa.scope_id),
      bytes(sa.scope_sha256)
    ]
  end

  defp source_kind(v) when is_integer(v), do: v
  defp source_kind(nil), do: 0

  defp source_kind(v) when is_atom(v),
    do: Serviceradar.Edge.V1.EdgeSourceAuthorizationKind.value(v)

  # --- framing (must match the Go digestWriter) ---

  defp u64(v) when is_integer(v), do: <<v::big-64>>

  # Go's digestWriter.i64 writes int64 as its two's-complement big-endian u64.
  defp i64(v) when is_integer(v), do: <<v::big-signed-64>>

  defp bytes(nil), do: <<0::big-64>>
  defp bytes(b) when is_binary(b), do: [<<byte_size(b)::big-64>>, b]

  defp present(true), do: <<1>>
  defp present(false), do: <<0>>

  # proto3 optional uint64: presence marker + value (0 when absent).
  defp opt_u64(nil), do: [present(false), u64(0)]
  defp opt_u64(v) when is_integer(v), do: [present(true), u64(v)]

  defp enum(_mod, nil), do: 0
  defp enum(_mod, v) when is_integer(v), do: v
  defp enum(mod, v) when is_atom(v), do: mod.value(v)
end
