defmodule ServiceRadarWebNG.Topology.BitmapFrame do
  @moduledoc """
  Versioned binary replacement of membership for an admitted tile view.

  Rows retain geometry order. The native query returns four bounded binary
  columns: matching flag, causal state, availability state, and little-endian
  uint32 matched count. No device IDs or portable bitmap sets cross this wire.
  Every replacement also carries the captured named Prefix Tag source versions
  for that sequence. Those versions are freshness, not watch identity.
  A boundary row may carry one exact remote endpoint match, while its geometry
  count remains zero. Ambiguous or unmapped boundaries carry no membership.
  Version 2 adds exact matching relation counts in the admitted edge order;
  these do not assign device membership to ambiguous boundary glyphs.
  """

  @max_frame 262_144
  @max_sources 32
  @max_u64 18_446_744_073_709_551_615
  @fields ~w(dictionary_epoch index_epoch query_digest authority_fingerprint view_digest source_revision index_revision)a

  @doc "Encodes a complete view or reset, preserving native column binaries."
  def encode(metadata, tiles \\ []) do
    kind = Map.get(metadata, :kind, :baseline)
    protocol = Map.get(metadata, :protocol, 1)
    fields = Enum.map(@fields, &Map.get(metadata, &1))
    sequence = Map.get(metadata, :sequence)
    total = Map.get(metadata, :total, if(kind == :reset, do: 0))

    with true <- kind in [:baseline, :reset] and protocol in [1, 2],
         true <- Enum.all?(fields, &valid_text?/1),
         true <- is_integer(total) and total in 0..4_294_967_295,
         true <- is_integer(sequence) and sequence in 0..@max_u64,
         {:ok, sources} <- prefix_sources(metadata),
         {:ok, payload} <- payload(kind, tiles, protocol) do
      tail = [Enum.map(fields, &text/1), sources, payload]
      size = 24 + IO.iodata_length(tail)

      header =
        <<"SRMO", protocol, if(kind == :baseline, do: 0, else: 1), 0::little-16, size::little-32, sequence::little-64,
          total::little-32>>

      if size <= @max_frame, do: {:ok, IO.iodata_to_binary([header, tail])}, else: {:error, :frame_budget}
    else
      _ -> {:error, :invalid_membership_frame}
    end
  end

  defp prefix_sources(metadata) do
    case Map.get(metadata, :prefix_sources, %{}) do
      sources when is_map(sources) and map_size(sources) <= @max_sources ->
        encoded =
          sources
          |> Enum.sort()
          |> Enum.map(fn
            {source, version} when is_integer(version) and version in 0..@max_u64 ->
              if valid_text?(source), do: [text(source), <<version::little-64>>], else: :error

            _ ->
              :error
          end)

        if :error in encoded, do: :error, else: {:ok, [<<map_size(sources)>>, encoded]}

      _ ->
        :error
    end
  end

  defp payload(:reset, [], _protocol), do: {:ok, <<>>}

  defp payload(:baseline, tiles, protocol) when is_list(tiles) and length(tiles) <= 64 do
    if Enum.all?(tiles, &(valid_tile?(&1) and valid_edges?(&1, protocol))) and unique_tiles?(tiles) do
      encoded =
        Enum.map(tiles, fn tile ->
          [
            <<tile.z, tile.x::little-32, tile.y::little-32>>,
            text(tile.revision),
            <<byte_size(tile.mask)::little-16>>,
            tile.mask,
            tile.causal,
            tile.availability,
            tile.counts,
            edge_columns(tile, protocol)
          ]
        end)

      {:ok, [<<length(tiles)>>, encoded]}
    else
      {:error, :invalid_tiles}
    end
  end

  defp payload(_, _, _), do: {:error, :invalid_tiles}

  defp valid_edges?(_tile, 1), do: true

  defp valid_edges?(%{edge_counts: counts}, 2) when is_binary(counts),
    do: rem(byte_size(counts), 4) == 0 and byte_size(counts) <= 512 * 4

  defp valid_edges?(_tile, _protocol), do: false

  defp edge_columns(_tile, 1), do: <<>>
  defp edge_columns(tile, 2), do: [<<div(byte_size(tile.edge_counts), 4)::little-16>>, tile.edge_counts]

  defp valid_tile?(%{
         z: z,
         x: x,
         y: y,
         revision: revision,
         mask: mask,
         causal: causal,
         availability: availability,
         counts: counts
       })
       when is_integer(z) and z in 0..24 and is_binary(mask) and is_binary(causal) and is_binary(availability) and
              is_binary(counts) do
    limit = Integer.pow(2, z)
    rows = byte_size(mask)

    is_integer(x) and is_integer(y) and x in 0..(limit - 1) and y in 0..(limit - 1) and valid_text?(revision) and
      rows <= 128 and
      byte_size(causal) == rows and byte_size(availability) == rows and byte_size(counts) == rows * 4 and
      valid_rows?(mask, causal, availability, counts)
  end

  defp valid_tile?(_), do: false

  defp valid_rows?(<<>>, <<>>, <<>>, <<>>), do: true

  defp valid_rows?(
         <<mask, masks::binary>>,
         <<causal, causals::binary>>,
         <<availability, availabilities::binary>>,
         <<count::little-32, counts::binary>>
       ) do
    mask in 0..1 and causal in 0..3 and availability in 0..2 and mask == if(count > 0, do: 1, else: 0) and
      valid_rows?(masks, causals, availabilities, counts)
  end

  defp unique_tiles?(tiles), do: length(Enum.uniq_by(tiles, &{&1.z, &1.x, &1.y})) == length(tiles)

  defp valid_text?(value),
    do: is_binary(value) and byte_size(value) in 1..128 and String.valid?(value) and not String.contains?(value, <<0>>)

  defp text(value), do: <<byte_size(value)::little-16, value::binary>>
end
