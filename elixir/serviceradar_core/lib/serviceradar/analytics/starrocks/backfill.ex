defmodule ServiceRadar.Analytics.StarRocks.Backfill do
  @moduledoc """
  Bounded newest-first shadow backfill with overlap deduplication.

  Historical identity mapping uses `Identity.record_id/2`. Checkpoints are
  watermarks, not permission to resume a paused live recovery blindly.
  """

  alias ServiceRadar.Analytics.StarRocks.Identity

  @type dataset :: Identity.dataset()

  @spec identities(dataset(), [map()]) :: [String.t()]
  def identities(dataset, rows) when is_list(rows) do
    rows
    |> Enum.map(&Identity.record_id(dataset, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec dedup_overlap([map()], MapSet.t(), dataset()) ::
          {kept :: [map()], skipped :: non_neg_integer()}
  def dedup_overlap(rows, already_loaded, dataset)
      when is_list(rows) and is_struct(already_loaded, MapSet) do
    {kept, skipped} =
      Enum.reduce(rows, {[], 0}, fn row, {acc, skip} ->
        id = Identity.record_id(dataset, row)

        if MapSet.member?(already_loaded, id) do
          {acc, skip + 1}
        else
          {[row | acc], skip}
        end
      end)

    {Enum.reverse(kept), skipped}
  end

  @spec bounded_batch([map()], pos_integer()) :: {batch :: [map()], rest :: [map()]}
  def bounded_batch(rows, max_rows)
      when is_list(rows) and is_integer(max_rows) and max_rows > 0 do
    Enum.split(rows, max_rows)
  end

  @spec next_checkpoint(map(), DateTime.t()) :: map()
  def next_checkpoint(checkpoint, oldest_loaded_at)
      when is_map(checkpoint) and is_struct(oldest_loaded_at, DateTime) do
    Map.merge(checkpoint, %{
      "watermark" => DateTime.to_iso8601(oldest_loaded_at),
      "direction" => "newest_first"
    })
  end
end
