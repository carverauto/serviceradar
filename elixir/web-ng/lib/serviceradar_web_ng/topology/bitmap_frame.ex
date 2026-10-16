defmodule ServiceRadarWebNG.Topology.BitmapFrame do
  @moduledoc """
  Version 1 binary replacement of membership for an admitted tile view.

  Rows retain geometry order. The native query returns four bounded binary
  columns: matching flag, causal state, availability state, and little-endian
  uint32 matched count. No device IDs or portable bitmap sets cross this wire.
  """

  @max_frame 262_144
  @fields ~w(dictionary_epoch index_epoch query_digest authority_fingerprint view_digest source_revision index_revision)a

  @doc "Encodes a complete view or reset, preserving native column binaries."
  def encode(metadata, tiles \\ []) do
    kind = Map.get(metadata, :kind, :baseline)
    fields = Enum.map(@fields, &Map.get(metadata, &1))
    sequence = Map.get(metadata, :sequence)
    total = Map.get(metadata, :total, if(kind == :reset, do: 0))

    with true <- kind in [:baseline, :reset],
         true <- Enum.all?(fields, &valid_text?/1),
         true <- is_integer(total) and total in 0..4_294_967_295,
         true <- is_integer(sequence) and sequence in 0..18_446_744_073_709_551_615,
         {:ok, payload} <- payload(kind, tiles) do
      tail = [Enum.map(fields, &text/1), payload]
      size = 24 + IO.iodata_length(tail)

      header =
        <<"SRMO", 1, if(kind == :baseline, do: 0, else: 1), 0::little-16, size::little-32, sequence::little-64,
          total::little-32>>

      if size <= @max_frame, do: {:ok, IO.iodata_to_binary([header, tail])}, else: {:error, :frame_budget}
    else
      _ -> {:error, :invalid_membership_frame}
    end
  end

  defp payload(:reset, []), do: {:ok, <<>>}

  defp payload(:baseline, tiles) when is_list(tiles) and length(tiles) <= 64 do
    if Enum.all?(tiles, &valid_tile?/1) and unique_tiles?(tiles) do
      encoded =
        Enum.map(tiles, fn tile ->
          [
            <<tile.z, tile.x::little-32, tile.y::little-32>>,
            text(tile.revision),
            <<byte_size(tile.mask)::little-16>>,
            tile.mask,
            tile.causal,
            tile.availability,
            tile.counts
          ]
        end)

      {:ok, [<<length(tiles)>>, encoded]}
    else
      {:error, :invalid_tiles}
    end
  end

  defp payload(_, _), do: {:error, :invalid_tiles}

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
