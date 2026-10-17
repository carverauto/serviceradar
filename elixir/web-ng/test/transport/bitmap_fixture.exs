defmodule ServiceRadarWebNG.BitmapTransport.Fixture do
  @moduledoc false
  alias ServiceRadarWebNG.Topology.BitmapFrame

  def frames(distribution, samples) do
    tiles = for x <- 0..63, do: tile(x, distribution)
    total = Enum.sum(for tile <- tiles, <<count::little-32 <- tile.counts>>, do: count)

    for sequence <- 1..samples, into: %{} do
      metadata = %{
        dictionary_epoch: "synthetic-dictionary",
        index_epoch: "synthetic-index",
        query_digest: "synthetic-query",
        authority_fingerprint: "synthetic-authority",
        view_digest: "synthetic-view",
        source_revision: "1",
        index_revision: "1",
        sequence: sequence,
        total: total
      }

      {:ok, frame} = BitmapFrame.encode(metadata, tiles)
      {sequence, frame}
    end
  end

  defp tile(x, distribution) do
    counts = for row <- 0..127, do: count(distribution, x, row)

    %{
      z: 6,
      x: x,
      y: 0,
      revision: "synthetic-compression-receipt-#{x}",
      mask: :erlang.list_to_binary(Enum.map(counts, &if(&1 > 0, do: 1, else: 0))),
      causal: :binary.copy(<<3>>, 128),
      availability: :erlang.list_to_binary(Enum.map(counts, &rem(&1, 3))),
      counts: IO.iodata_to_binary(Enum.map(counts, &<<&1::little-32>>))
    }
  end

  defp count(:uniform, _, _), do: 1
  defp count(:mixed, x, row), do: :erlang.phash2({x, row}, 65_536)
end
