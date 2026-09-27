defmodule ServiceRadarWebNG.Topology.WorldOverlayReader do
  @moduledoc "Two-stage tile telemetry reads that release native worlds before waiting for telemetry SQL."

  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Topology.TileControl
  alias ServiceRadarWebNG.Topology.TileKey
  alias ServiceRadarWebNG.Topology.WorldCache
  alias ServiceRadarWebNG.Topology.WorldFlow
  alias ServiceRadarWebNG.Topology.WorldHealth

  @doc "Returns only plain bounded data; the caller must end this task before starting read_rates/2."
  def prepare(key, expected, revision, continuation, cache, health_owner) do
    with {:ok, tile} <- WorldCache.fetch(key, :background, cache),
         true <- tile.revision == revision,
         {:ok, %{world: world, health: health, manifest: manifest, progress: progress}} <-
           WorldHealth.snapshot(health_owner),
         true <- TileControl.fence(manifest) == expected and tile.generation == expected.generation,
         %{selection: selection, flow_edges: edges} when is_list(edges) and length(edges) <= 256 <- tile,
         {:ok, health} <- TopologyAtlas.tile_health(world, health, selection),
         cursor = if(continuation && continuation.revision == tile.revision, do: continuation.cursor),
         {:ok, page} <- TopologyAtlas.tile_relations(world, selection, cursor, 256),
         :ok <- validate_page(edges, page),
         {:ok, current} <- WorldCache.manifest(cache),
         true <- TileControl.fence(current) == expected do
      prepared = %{
        key: key,
        fence: expected,
        revision: tile.revision,
        edges: edges,
        page: page,
        health: health |> Map.put(:source, source_progress(progress)) |> Map.put(:sampled_at, DateTime.utc_now())
      }

      if :erlang.external_size(prepared) <= 8_388_608,
        do: {:ok, prepared},
        else: {:error, :overlay_budget_exceeded}
    else
      false -> {:error, :source_changed}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_tile_receipt}
    end
  end

  @doc "Reads backend-routed telemetry without retaining a native world or selection resource."
  def read_rates(prepared, settings) do
    request = WorldFlow.request(prepared.page.relations, DateTime.utc_now(), settings)

    with {:ok, rows} <- rates(request) do
      payload = %{
        layout_version: prepared.fence.layout_version,
        generation: prepared.fence.generation,
        tile_id: TileKey.id(prepared.key),
        revision: prepared.revision,
        health: prepared.health,
        flow: WorldFlow.summarize(prepared.edges, prepared.page, rows, request),
        sampled_at: request.until
      }

      with {:ok, encoded} <- Jason.encode(payload),
           true <- byte_size(encoded) <= 262_144 do
        {:ok, %{payload: payload, continuation: %{revision: prepared.revision, cursor: prepared.page.next_cursor}}}
      else
        false -> {:error, :overlay_budget_exceeded}
        {:error, _} = error -> error
      end
    end
  end

  defp rates(%{pairs: []}), do: {:ok, []}

  defp rates(request) do
    SRQLRunner.interface_rates(request.pairs, request.since, request.until,
      fresh_after: request.fresh_after,
      timeout: request.timeout_ms
    )
  end

  defp source_progress(progress) do
    Map.take(progress, [:source_status, :observed, :total, :last_read_at, :reconciled_since, :pending, :reconciling])
  end

  defp validate_page(edges, page) do
    ids = MapSet.new(Enum.map(edges, & &1.id))
    counts = Map.new(edges, &{&1.id, &1.count})
    selected = Enum.frequencies_by(page.relations, & &1.rendered_edge_id)

    valid =
      length(page.relations) <= 256 and page.candidates <= 4096 and
        Enum.all?(edges, &(is_binary(&1.id) and is_integer(&1.count) and &1.count > 0)) and
        MapSet.size(ids) == length(edges) and
        Enum.sum(Enum.map(edges, & &1.count)) == page.total_rendered_relations and
        length(Enum.uniq_by(page.relations, & &1.relation_id)) == length(page.relations) and
        Enum.all?(selected, fn {id, count} -> MapSet.member?(ids, id) and count <= counts[id] end) and
        Enum.all?(page.relations, &(counts[&1.rendered_edge_id] == &1.bundle_members))

    if valid, do: :ok, else: {:error, :invalid_tile_receipt}
  end
end
