defmodule ServiceRadarAgentGateway.EdgeDigest do
  @moduledoc """
  Immutable database-semantic digest and JetStream `Nats-Msg-Id` derivation for
  the edge result relay (unify-sweep-results-proto tasks 3.3, 1.5), the Elixir
  peer of the Go reference core `go/pkg/edge/gwpublish`. It MUST stay
  byte-identical to that core (pinned by golden values in the tests) so the DB
  idempotency key and the JetStream de-dup id agree across languages.

  `semantic_digest/1` covers only the domain-identity envelope and EXCLUDES spool
  id, sequence, compression, sizes, and the renewable collection/delivery
  capabilities, so it is stable across retries, replays, and physical placement.
  `msg_id/2` derives the `Nats-Msg-Id` from the gateway's trusted identity plus
  the frame's spool id/sequence and that digest.
  """

  alias Serviceradar.Edge.V1.EdgeResultAuthorizationKind
  alias Serviceradar.Edge.V1.EdgeResultFrame
  alias Serviceradar.Edge.V1.EdgeResultPayloadKind
  alias Serviceradar.Edge.V1.EdgeResultTrafficClass

  @typedoc "Gateway-verified identity, NOT read from the frame."
  @type identity :: %{network_scope_id: binary(), agent_id: binary()}

  @doc """
  The immutable database-semantic digest of a frame (32-byte SHA-256).
  """
  @spec semantic_digest(EdgeResultFrame.t()) :: binary()
  def semantic_digest(%EdgeResultFrame{} = f) do
    iodata = [
      bytes(f.event_id),
      u64(enum_int(EdgeResultPayloadKind, f.payload_kind)),
      u64(f.schema_version || 0),
      bytes(f.payload_sha256),
      bytes(f.execution_id),
      u64(f.execution_shard || 0),
      u64(f.assignment_epoch || 0),
      u64(enum_int(EdgeResultAuthorizationKind, f.authorization_kind)),
      bytes(f.authorization_context_id),
      bytes(f.target_range_id),
      bytes(f.target_range_sha256),
      bytes(f.network_scope_id),
      u64(enum_int(EdgeResultTrafficClass, f.traffic_class)),
      u64(f.cost_model_version || 0),
      u64(f.projected_row_count || 0),
      u64(f.projected_write_bytes || 0)
    ]

    :crypto.hash(:sha256, iodata)
  end

  @doc """
  The `Nats-Msg-Id` (lowercase hex) for JetStream de-duplication, derived from the
  trusted identity, the frame's spool id + sequence, and the semantic digest.
  """
  @spec msg_id(identity(), EdgeResultFrame.t()) :: String.t()
  def msg_id(%{network_scope_id: scope, agent_id: agent}, %EdgeResultFrame{} = f) do
    iodata = [
      bytes(scope),
      bytes(agent),
      bytes(f.spool_id),
      <<f.sequence || 0::big-64>>,
      bytes(semantic_digest(f))
    ]

    :sha256 |> :crypto.hash(iodata) |> Base.encode16(case: :lower)
  end

  # --- canonical encoding (matches the Go writeBytes/writeU64 helpers) ---

  defp bytes(nil), do: <<0::big-64>>
  defp bytes(b) when is_binary(b), do: [<<byte_size(b)::big-64>>, b]

  defp u64(v) when is_integer(v), do: <<v::big-64>>

  defp enum_int(_mod, nil), do: 0
  defp enum_int(_mod, v) when is_integer(v), do: v
  defp enum_int(mod, v) when is_atom(v), do: mod.value(v)
end
