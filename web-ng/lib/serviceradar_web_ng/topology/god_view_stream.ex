defmodule ServiceRadarWebNG.Topology.GodViewStream do
  @moduledoc """
  Builds phase-1 God-View snapshot payloads.

  The binary payload currently encodes a compact fixed header used by the
  frontend hook. It can be replaced by Arrow IPC while keeping the same
  feature-flagged endpoint shape.
  """

  alias ServiceRadarWebNG.Topology.GodViewSnapshot
  alias ServiceRadarWebNG.Topology.Native

  @spec latest_snapshot() ::
          {:ok, %{snapshot: GodViewSnapshot.snapshot(), payload: binary()}} | {:error, term()}
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
    node_index = snapshot.nodes |> Enum.with_index() |> Map.new(fn {n, idx} -> {n.id, idx} end)

    nodes =
      Enum.map(snapshot.nodes, fn node ->
        {Map.get(node, :x, 0), Map.get(node, :y, 0), Map.get(node, :state, 3)}
      end)

    edges =
      Enum.map(snapshot.edges, fn edge ->
        {Map.fetch!(node_index, edge.source), Map.fetch!(node_index, edge.target)}
      end)

    Native.encode_snapshot(
      snapshot.schema_version,
      snapshot.revision,
      nodes,
      edges,
      byte_size(root),
      byte_size(affected),
      byte_size(healthy),
      byte_size(unknown)
    )
  end

  defp sample_nodes do
    [
      %{id: "core-1", label: "Core Router", kind: "router", x: 80, y: 180, state: 0},
      %{id: "dist-1", label: "Distribution Switch", kind: "switch", x: 300, y: 180, state: 1},
      %{id: "srv-1", label: "Application Server", kind: "server", x: 520, y: 180, state: 1}
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
