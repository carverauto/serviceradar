defmodule ServiceRadarWebNG.Topology.BitmapView do
  @moduledoc "Projects one authorized query revision into exact admitted geometry rows."

  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Topology.BitmapExpression
  alias ServiceRadarWebNG.Topology.BitmapFrame
  alias ServiceRadarWebNG.Topology.BitmapIndex
  alias ServiceRadarWebNG.Topology.BitmapQueries
  alias ServiceRadarWebNG.Topology.Native
  alias ServiceRadarWebNG.Topology.TileKey
  alias ServiceRadarWebNG.Topology.WorldCache

  @max_selector_bytes 8_388_608
  @max_receipt_bytes 65_536
  @max_relation_candidates 262_144

  def validate(%{"protocol" => protocol, "query" => query} = params) when protocol in [1, 2] do
    with :ok <- BitmapExpression.request_budget(query),
         :ok <- receipt_budget(params),
         {:ok, watch} <- TileKey.watch(params),
         true <- length(watch.keys) == map_size(watch.tiles) do
      {:ok, Map.merge(watch, %{protocol: protocol, boundary_endpoints: params["boundary_endpoints"] == true})}
    else
      false -> {:error, :invalid_tile_receipt}
      error -> error
    end
  end

  def validate(_params), do: {:error, :unsupported_membership_protocol}

  defp receipt_budget(params) do
    receipts = Map.delete(params, "query")

    if :erlang.external_size(receipts) <= @max_receipt_bytes do
      case Jason.encode(receipts) do
        {:ok, bytes} when byte_size(bytes) <= @max_receipt_bytes -> :ok
        {:ok, _bytes} -> {:error, :query_budget}
        {:error, _reason} -> {:error, :invalid_query}
      end
    else
      {:error, :query_budget}
    end
  end

  def build(scope, params, sequence, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    with {:ok, watch} <- validate(params),
         {:ok, {_fence, result}} <-
           BitmapQueries.with_query(scope, params["query"], &project(&1, watch, sequence), deadline: deadline) do
      {:ok, result}
    end
  end

  defp current_projection(result) do
    with {:ok, %{ordinals: %{mapping: mapping}} = current} <- WorldCache.world(),
         :ok <- require_generation(current, result, mapping),
         {:ok, snapshot} <- BitmapIndex.snapshot() do
      require_index_epochs(snapshot, result)
    else
      {:ok, _unmapped_world} -> {:error, :membership_not_ready}
      error -> error
    end
  end

  defp require_generation(current, result, mapping) do
    if current.manifest.generation == result.generation and mapping == result.mapping do
      :ok
    else
      {:error, :source_changed}
    end
  end

  defp require_index_epochs(snapshot, result) do
    dictionary = Ecto.UUID.load!(snapshot.dictionary_epoch)
    index = Ecto.UUID.load!(snapshot.index_epoch)

    if dictionary == result.metadata.dictionary_epoch and index == result.metadata.index_epoch do
      :ok
    else
      {:error, :membership_not_ready}
    end
  end

  defp project(context, watch, sequence) do
    with {:ok, %{ordinals: %{mapping: mapping, info: info}} = current} <- WorldCache.world(),
         :ok <- require_layout(current, watch),
         :ok <- require_dictionary_epoch(info, context),
         {:ok, tiles} <- project_tiles(current, mapping, context, watch),
         {:ok, latest} <- WorldCache.world(),
         :ok <- require_same_world(latest, current) do
      metadata = metadata(context, current, watch, sequence)

      identity = %{
        layout_version: current.manifest.layout_version,
        generation: current.manifest.generation,
        world_epoch: info.dictionary_epoch,
        assignment: info.assignment,
        dictionary_epoch: context.dictionary_epoch,
        index_epoch: context.index_epoch,
        index_revision: context.revision,
        authority: context.authority
      }

      with {:ok, frame} <- BitmapFrame.encode(metadata, tiles),
           :ok <-
             current_projection(%{
               metadata: metadata,
               mapping: mapping,
               generation: current.manifest.generation
             }) do
        binding =
          metadata
          |> Map.take([:dictionary_epoch, :query_digest, :authority_fingerprint, :view_digest])
          |> Map.put(
            :projection,
            Map.put(Map.take(info, [:mapped, :total]), :completed_at, current.ordinals.completed_at)
          )
          |> Map.put(:progress, context.progress)

        {:ok,
         %{
           binding: binding,
           metadata: metadata,
           frame: frame,
           authority: context.authority,
           prefix_sources: context.prefix_sources,
           mapping: mapping,
           generation: current.manifest.generation,
           identity: identity
         }}
      end
    else
      false -> {:error, :source_changed}
      {:ok, _unmapped_world} -> {:error, :membership_not_ready}
      error -> error
    end
  end

  defp require_layout(current, watch) do
    if current.manifest.layout_version == watch.layout_version do
      :ok
    else
      {:error, :source_changed}
    end
  end

  defp require_dictionary_epoch(info, context) do
    if info.dictionary_epoch == context.dictionary_epoch do
      :ok
    else
      {:error, :membership_not_ready}
    end
  end

  defp require_same_world(latest, current) do
    if latest.world == current.world and latest.ordinals == current.ordinals do
      :ok
    else
      {:error, :source_changed}
    end
  end

  defp project_tiles(current, mapping, context, watch) do
    watch.keys
    |> Enum.sort_by(&TileKey.id/1)
    |> Enum.reduce_while({:ok, [], 0, 0}, fn key, {:ok, tiles, selector_bytes, candidates} ->
      with {:ok, _budget} <- BitmapQueries.remaining(context),
           {:ok, tile} <- busy_as(WorldCache.fetch(key), :tile_cache_busy),
           true <- tile.generation == current.manifest.generation and tile.revision == watch.tiles[TileKey.id(key)],
           {:ok, selectors, bytes} <-
             selectors(
               current.world,
               mapping,
               tile,
               context,
               @max_selector_bytes - selector_bytes,
               watch.boundary_endpoints
             ),
           {:ok, budget} <- BitmapQueries.remaining(context),
           {:ok, {mask, causal, availability, counts}} <-
             Native.bitmap_query_row_overlay(
               context.ref,
               context.authority,
               context.dictionary_epoch,
               context.index_epoch,
               :device,
               selectors,
               budget
             ),
           {:ok, edge_counts, candidates} <-
             relation_counts(current.world, mapping, tile, context, watch.protocol, candidates) do
        row = %{
          z: key.z,
          x: key.x,
          y: key.y,
          revision: tile.revision,
          mask: mask,
          causal: causal,
          availability: availability,
          counts: counts,
          edge_counts: edge_counts
        }

        {:cont, {:ok, [row | tiles], selector_bytes + bytes, candidates}}
      else
        false -> {:halt, {:error, :source_changed}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, tiles, _selector_bytes, _candidates} -> {:ok, Enum.reverse(tiles)}
      error -> error
    end
  end

  defp relation_counts(_world, _mapping, _tile, _context, 1, candidates), do: {:ok, nil, candidates}

  defp relation_counts(world, mapping, tile, context, 2, candidates) do
    counts = :binary.copy(<<0::little-32>>, length(tile.flow_edges))

    with {:ok, counts, candidates} <-
           relation_pages(world, mapping, tile.selection, context, nil, counts, candidates),
         true <- valid_relation_counts?(counts, tile.flow_edges) do
      {:ok, counts, candidates}
    else
      false -> {:error, :source_changed}
      error -> error
    end
  end

  defp relation_pages(_world, _mapping, _selection, _context, _cursor, <<>>, candidates), do: {:ok, <<>>, candidates}

  defp relation_pages(world, mapping, selection, context, cursor, counts, candidates)
       when candidates <= @max_relation_candidates - 4096 do
    with {:ok, _budget} <- BitmapQueries.remaining(context),
         {:ok, page} <-
           busy_as(TopologyAtlas.tile_relation_ordinals(world, mapping, selection, cursor), :relation_ordinals_busy),
         {:ok, budget} <- BitmapQueries.remaining(context),
         {:ok, counts} <-
           Native.bitmap_query_relation_counts(
             context.ref,
             context.authority,
             context.dictionary_epoch,
             context.index_epoch,
             page.pairs,
             counts,
             budget
           ) do
      candidates = candidates + page.candidates

      case page.next_cursor do
        nil -> {:ok, counts, candidates}
        next when next != cursor -> relation_pages(world, mapping, selection, context, next, counts, candidates)
        _ -> {:error, :source_changed}
      end
    end
  end

  defp relation_pages(_world, _mapping, _selection, _context, _cursor, _counts, _candidates),
    do: {:error, :membership_budget}

  defp valid_relation_counts?(<<>>, []), do: true

  defp valid_relation_counts?(<<count::little-32, rest::binary>>, [edge | edges]),
    do: count <= edge.count and valid_relation_counts?(rest, edges)

  defp valid_relation_counts?(_counts, _edges), do: false

  defp selectors(world, mapping, tile, context, remaining_bytes, boundary_endpoints?) do
    with {:ok, ordinals} <- tile_ordinals(world, mapping, tile.selection) do
      tile.glyphs
      |> Enum.reduce_while({:ok, [], 0, ordinals}, fn glyph, {:ok, rows, bytes, ordinals} ->
        with {:ok, row, ordinals} <-
               selector(world, mapping, tile.selection, glyph, ordinals, context, remaining_bytes - bytes),
             row = if(glyph.kind == :boundary and not boundary_endpoints?, do: {:leaf, 0}, else: row),
             size = if(elem(row, 0) == :aggregate, do: byte_size(elem(row, 1)), else: 4),
             true <- bytes + size <= remaining_bytes do
          {:cont, {:ok, [row | rows], bytes + size, ordinals}}
        else
          false -> {:halt, {:error, :membership_budget}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, rows, bytes, []} -> {:ok, Enum.reverse(rows), bytes}
        error -> error
      end
    end
  end

  # One bounded native call returns row-aligned leaf/remote endpoint identities.
  # Shared or unmapped portals return zero; they cannot borrow membership from
  # a different device that happens to cross the same boundary point.
  defp tile_ordinals(world, mapping, selection) do
    case busy_as(TopologyAtlas.tile_device_ordinals(world, mapping, selection), :device_ordinals_busy) do
      {:ok, ordinals} -> {:ok, ordinals}
      {:error, :not_ready} -> {:error, :source_changed}
      other -> other
    end
  end

  defp selector(_world, _mapping, _selection, %{kind: kind}, [ordinal | ordinals], _context, _remaining)
       when kind in [:device, :boundary], do: {:ok, {:leaf, ordinal}, ordinals}

  defp selector(world, mapping, selection, %{kind: :aggregate} = glyph, [_ordinal | ordinals], context, remaining) do
    with {:ok, row} <- aggregate_selector(world, mapping, selection, glyph, context, remaining),
         do: {:ok, row, ordinals}
  end

  defp aggregate_selector(world, mapping, selection, %{kind: :aggregate, id: id}, context, remaining)
       when remaining > 0 do
    with {:ok, aggregate} <-
           busy_as(TopologyAtlas.aggregate_selection(world, selection, id), :aggregate_selection_busy),
         {:ok, budget} <- BitmapQueries.remaining(context) do
      exported = TopologyAtlas.aggregate_ordinals(world, mapping, aggregate, remaining, budget)

      case busy_as(exported, :aggregate_ordinals_busy) do
        {:ok, bytes} -> {:ok, {:aggregate, bytes}}
        {:error, :not_ready} -> {:error, :source_changed}
        other -> other
      end
    end
  end

  defp aggregate_selector(_world, _mapping, _selection, _glyph, _context, _remaining), do: {:error, :membership_budget}

  # Each projection step that can refuse work names itself, so query_busy
  # diagnostics separate tile-cache, selection and ordinal-reader contention.
  defp busy_as({:error, :busy}, source), do: {:error, source}
  defp busy_as(result, _source), do: result

  defp metadata(context, current, watch, sequence) do
    view =
      {watch.layout_version, current.manifest.generation, Enum.sort(watch.tiles), context.query_digest, context.authority,
       watch.boundary_endpoints}

    view = if watch.protocol == 1, do: view, else: {view, watch.protocol}

    %{
      protocol: watch.protocol,
      sequence: sequence,
      total: context.total,
      dictionary_epoch: Ecto.UUID.load!(context.dictionary_epoch),
      index_epoch: Ecto.UUID.load!(context.index_epoch),
      query_digest: Base.encode16(context.query_digest, case: :lower),
      authority_fingerprint: Base.encode16(context.authority, case: :lower),
      view_digest: digest(:erlang.term_to_binary(view, [:deterministic])),
      source_revision: digest(context.source_revision),
      index_revision: Integer.to_string(context.revision),
      prefix_sources: context.prefix_sources
    }
  end

  defp digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
