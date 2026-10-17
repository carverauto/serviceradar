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

  def validate(%{"protocol" => 1, "query" => query} = params) do
    with :ok <- BitmapExpression.request_budget(query),
         :ok <- receipt_budget(params),
         {:ok, watch} <- TileKey.watch(params),
         true <- length(watch.keys) == map_size(watch.tiles) do
      {:ok, watch}
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

  def build(scope, params, sequence) do
    deadline = System.monotonic_time(:millisecond) + 1_000

    with {:ok, watch} <- validate(params),
         {:ok, {_fence, result}} <-
           BitmapQueries.with_query(scope, params["query"], &project(&1, watch, sequence), deadline: deadline) do
      {:ok, Map.put(result, :deadline, deadline)}
    end
  end

  @doc "Recheck geometry, canonical mapping and current authority inside the original request budget."
  def confirm_delivery(scope, result) do
    BitmapQueries.confirm_delivery(
      scope,
      result.authority,
      result.deadline,
      result.prefix_sources,
      fn -> current_projection(result) end
    )
  end

  defp current_projection(result) do
    with {:ok, %{ordinals: %{mapping: mapping}} = current} <- WorldCache.world(),
         true <- current.manifest.generation == result.generation and mapping == result.mapping,
         {:ok, snapshot} <- BitmapIndex.snapshot(),
         true <- Ecto.UUID.load!(snapshot.dictionary_epoch) == result.metadata.dictionary_epoch,
         true <- Ecto.UUID.load!(snapshot.index_epoch) == result.metadata.index_epoch do
      :ok
    else
      false -> {:error, :source_changed}
      {:ok, _unmapped_world} -> {:error, :membership_not_ready}
      error -> error
    end
  end

  defp project(context, watch, sequence) do
    with {:ok, %{ordinals: %{mapping: mapping, info: info}} = current} <- WorldCache.world(),
         true <- current.manifest.layout_version == watch.layout_version,
         true <- info.dictionary_epoch == context.dictionary_epoch,
         {:ok, tiles} <- project_tiles(current, mapping, context, watch),
         {:ok, latest} <- WorldCache.world(),
         true <- latest.world == current.world and latest.ordinals == current.ordinals do
      metadata = metadata(context, current, watch, sequence)

      with {:ok, frame} <- BitmapFrame.encode(metadata, tiles) do
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
           generation: current.manifest.generation
         }}
      end
    else
      false -> {:error, :source_changed}
      {:ok, _unmapped_world} -> {:error, :membership_not_ready}
      error -> error
    end
  end

  defp project_tiles(current, mapping, context, watch) do
    watch.keys
    |> Enum.sort_by(&TileKey.id/1)
    |> Enum.reduce_while({:ok, [], 0}, fn key, {:ok, tiles, selector_bytes} ->
      with {:ok, _budget} <- BitmapQueries.remaining(context),
           {:ok, tile} <- WorldCache.fetch(key),
           true <- tile.generation == current.manifest.generation and tile.revision == watch.tiles[TileKey.id(key)],
           {:ok, selectors, bytes} <-
             selectors(current.world, mapping, tile, context, @max_selector_bytes - selector_bytes),
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
             ) do
        row = %{
          z: key.z,
          x: key.x,
          y: key.y,
          revision: tile.revision,
          mask: mask,
          causal: causal,
          availability: availability,
          counts: counts
        }

        {:cont, {:ok, [row | tiles], selector_bytes + bytes}}
      else
        false -> {:halt, {:error, :source_changed}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, tiles, _selector_bytes} -> {:ok, Enum.reverse(tiles)}
      error -> error
    end
  end

  defp selectors(world, mapping, tile, context, remaining_bytes) do
    tile.glyphs
    |> Enum.reduce_while({:ok, [], 0}, fn glyph, {:ok, rows, bytes} ->
      with {:ok, row} <- selector(world, mapping, tile.selection, glyph, context, remaining_bytes - bytes),
           size = if(elem(row, 0) == :aggregate, do: byte_size(elem(row, 1)), else: 4),
           true <- bytes + size <= remaining_bytes do
        {:cont, {:ok, [row | rows], bytes + size}}
      else
        false -> {:halt, {:error, :membership_budget}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows, bytes} -> {:ok, Enum.reverse(rows), bytes}
      error -> error
    end
  end

  defp selector(world, mapping, _selection, %{kind: :device, id: id}, _context, _remaining) do
    case TopologyAtlas.device_ordinals(world, mapping, [id]) do
      {:ok, [ordinal]} -> {:ok, {:leaf, ordinal}}
      {:error, :not_ready} -> {:error, :source_changed}
      other -> other
    end
  end

  defp selector(world, mapping, selection, %{kind: :aggregate, id: id}, context, remaining) when remaining > 0 do
    with {:ok, aggregate} <- TopologyAtlas.aggregate_selection(world, selection, id),
         {:ok, budget} <- BitmapQueries.remaining(context) do
      case TopologyAtlas.aggregate_ordinals(world, mapping, aggregate, remaining, budget) do
        {:ok, bytes} -> {:ok, {:aggregate, bytes}}
        {:error, :not_ready} -> {:error, :source_changed}
        other -> other
      end
    end
  end

  defp selector(_world, _mapping, _selection, %{kind: :aggregate}, _context, _remaining), do: {:error, :membership_budget}

  # Boundary portals have no independently authorized population in release one.
  defp selector(_world, _mapping, _selection, _glyph, _context, _remaining), do: {:ok, {:leaf, 0}}

  defp metadata(context, current, watch, sequence) do
    view =
      {watch.layout_version, current.manifest.generation, Enum.sort(watch.tiles), context.query_digest, context.authority}

    %{
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
