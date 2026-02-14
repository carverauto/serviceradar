defmodule ServiceRadarWebNG.Topology.GodViewStream do
  @moduledoc """
  Builds phase-1 God-View snapshot payloads.

  The binary payload currently encodes a compact fixed header used by the
  frontend hook. It can be replaced by Arrow IPC while keeping the same
  feature-flagged endpoint shape.
  """

  alias ServiceRadarWebNG.Topology.GodViewSnapshot

  @magic "SRGV"

  @spec latest_snapshot() :: {:ok, %{snapshot: GodViewSnapshot.snapshot(), payload: binary()}} | {:error, term()}
  def latest_snapshot do
    revision = System.system_time(:millisecond)

    snapshot = %{
      schema_version: GodViewSnapshot.schema_version(),
      revision: revision,
      generated_at: DateTime.utc_now(),
      nodes: sample_nodes(),
      edges: sample_edges(),
      causal_bitmaps: sample_bitmaps()
    }

    with :ok <- GodViewSnapshot.validate(snapshot) do
      {:ok, %{snapshot: snapshot, payload: encode_payload(snapshot)}}
    end
  end

  defp encode_payload(snapshot) do
    root = Map.get(snapshot.causal_bitmaps, :root_cause, <<>>)
    affected = Map.get(snapshot.causal_bitmaps, :affected, <<>>)
    healthy = Map.get(snapshot.causal_bitmaps, :healthy, <<>>)
    unknown = Map.get(snapshot.causal_bitmaps, :unknown, <<>>)

    <<@magic::binary-size(4), snapshot.schema_version::unsigned-32, snapshot.revision::unsigned-64,
      length(snapshot.nodes)::unsigned-32, length(snapshot.edges)::unsigned-32,
      byte_size(root)::unsigned-32, byte_size(affected)::unsigned-32, byte_size(healthy)::unsigned-32,
      byte_size(unknown)::unsigned-32>>
  end

  defp sample_nodes do
    [
      %{id: "core-1", label: "Core Router", kind: "router"},
      %{id: "dist-1", label: "Distribution Switch", kind: "switch"},
      %{id: "srv-1", label: "Application Server", kind: "server"}
    ]
  end

  defp sample_edges do
    [
      %{source: "core-1", target: "dist-1", kind: "physical"},
      %{source: "dist-1", target: "srv-1", kind: "physical"}
    ]
  end

  defp sample_bitmaps do
    %{
      root_cause: <<0b10000000>>,
      affected: <<0b01100000>>,
      healthy: <<0b00011111>>,
      unknown: <<0>>
    }
  end
end
