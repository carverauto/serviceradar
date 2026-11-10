defmodule ServiceRadarNVR.PublicationRecovery do
  @moduledoc false

  alias ServiceRadarNVR.Capacity
  alias ServiceRadarNVR.Disk
  alias ServiceRadarNVR.Publication
  alias ServiceRadarRecording.Storage

  def page(cursor, limit) when is_integer(limit) and limit in 1..16 do
    with {:ok, storage, limits} <- Capacity.recovery_storage(),
         {:ok, after_id} <- cursor_position(cursor, storage.id),
         {:ok, inventory} <- Disk.inventory(storage) do
      remaining = inventory.block_ids |> Enum.sort() |> Enum.drop_while(&(&1 <= after_id))
      {selected, rest} = Enum.split(remaining, limit)
      entries = Enum.map(selected, &Publication.recovery_entry(storage, &1, limits))
      next = if rest == [], do: nil, else: %{storage_id: storage.id, after_block_id: List.last(selected)}

      with :ok <- Storage.verify(storage) do
        {:ok, %{storage_id: storage.id, entries: entries, next_cursor: next}}
      end
    end
  end

  def page(_cursor, _limit), do: {:error, :invalid_publication_page_limit}

  defp cursor_position(nil, _storage_id), do: {:ok, ""}

  defp cursor_position(%{storage_id: storage_id, after_block_id: block_id}, storage_id) when is_binary(block_id) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, block_id),
      do: {:ok, block_id},
      else: {:error, :invalid_publication_cursor}
  end

  defp cursor_position(%{storage_id: storage_id}, current_id) when storage_id != current_id,
    do: {:error, :publication_cursor_storage_mismatch}

  defp cursor_position(_cursor, _storage_id), do: {:error, :invalid_publication_cursor}
end
