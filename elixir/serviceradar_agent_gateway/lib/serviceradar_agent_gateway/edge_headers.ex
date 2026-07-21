defmodule ServiceRadarAgentGateway.EdgeHeaders do
  @moduledoc """
  Builds the canonical NATS broker headers the gateway stamps on every published
  edge frame (unify-sweep-results-proto tasks 1.5, 3.4). Because the gateway
  publishes the INNER payload bytes verbatim (no domain decode/re-encode), the
  consumer needs the immutable semantic envelope out-of-band: these headers carry
  the semantic digest (the DB idempotency key), the payload kind/schema, the
  trusted identity, execution/authorization/range identity, spool coordinates,
  and the cost terms.

  The immutable semantic-envelope digest (`Sr-Edge-Semantic-Digest`) is stamped
  separately from the JetStream de-dup id (`Nats-Msg-Id`) and physical placement
  (`Nats-Expected-Stream`), per task 1.5. Binary ids are base64url; digests are
  lowercase hex; counts/enums are decimal strings.
  """

  alias Serviceradar.Edge.V1.EdgeResultAuthorizationKind
  alias Serviceradar.Edge.V1.EdgeResultFrame
  alias Serviceradar.Edge.V1.EdgeResultPayloadKind
  alias Serviceradar.Edge.V1.EdgeResultTrafficClass
  alias ServiceRadarAgentGateway.EdgeDigest

  @doc """
  The full header list for a frame: the JetStream de-dup id and expected stream
  plus the canonical `Sr-Edge-*` envelope headers.
  """
  @spec build(map(), EdgeResultFrame.t(), String.t()) :: [{String.t(), String.t()}]
  def build(identity, %EdgeResultFrame{} = f, expected_stream) do
    digest = EdgeDigest.semantic_digest(f)

    [
      {"Nats-Msg-Id", EdgeDigest.msg_id(identity, f)},
      {"Nats-Expected-Stream", expected_stream},
      {"Sr-Edge-Semantic-Digest", Base.encode16(digest, case: :lower)},
      {"Sr-Edge-Payload-Kind", enum(EdgeResultPayloadKind, f.payload_kind)},
      {"Sr-Edge-Schema-Version", int(f.schema_version)},
      {"Sr-Edge-Event-Id", b64(f.event_id)},
      {"Sr-Edge-Spool-Id", b64(f.spool_id)},
      {"Sr-Edge-Sequence", int(f.sequence)},
      {"Sr-Edge-Execution-Id", b64(f.execution_id)},
      {"Sr-Edge-Execution-Shard", int(f.execution_shard)},
      {"Sr-Edge-Assignment-Epoch", int(f.assignment_epoch)},
      {"Sr-Edge-Network-Scope-Id", b64(f.network_scope_id)},
      {"Sr-Edge-Traffic-Class", enum(EdgeResultTrafficClass, f.traffic_class)},
      {"Sr-Edge-Target-Range-Id", b64(f.target_range_id)},
      {"Sr-Edge-Authorization-Kind", enum(EdgeResultAuthorizationKind, f.authorization_kind)},
      {"Sr-Edge-Payload-Sha256", hex(f.payload_sha256)},
      {"Sr-Edge-Projected-Row-Count", int(f.projected_row_count)},
      {"Sr-Edge-Cost-Model-Version", int(f.cost_model_version)}
    ]
  end

  defp b64(nil), do: ""
  defp b64(b) when is_binary(b), do: Base.url_encode64(b, padding: false)

  defp hex(nil), do: ""
  defp hex(b) when is_binary(b), do: Base.encode16(b, case: :lower)

  defp int(nil), do: "0"
  defp int(n) when is_integer(n), do: Integer.to_string(n)

  defp enum(_mod, nil), do: "0"
  defp enum(_mod, v) when is_integer(v), do: Integer.to_string(v)
  defp enum(mod, v) when is_atom(v), do: Integer.to_string(mod.value(v))
end
