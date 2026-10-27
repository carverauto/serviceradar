defmodule ServiceRadarWebNG.CameraArchiveWindow do
  @moduledoc "Explicit finite player windows within one canonically verified recording block."

  alias ServiceRadarWebNG.CameraArchivePlaylist

  @duration_limit 300_000_000_000

  def select(%{archive_status: "available", descriptor: descriptor} = metadata, index)
      when is_integer(index) and index >= 0 do
    windows = descriptor["fragments"] |> Enum.reduce([], &place_fragment/2) |> Enum.reverse()

    case Enum.at(windows, index) do
      nil ->
        {:error, :invalid_recording_window}

      window ->
        with {:ok, _playlist} <- CameraArchivePlaylist.render(metadata, window.first, window.count) do
          {:ok, Map.merge(window, %{index: index, total: length(windows)})}
        end
    end
  end

  def select(%{archive_status: "available"}, _), do: {:error, :invalid_recording_window}
  def select(_, _), do: {:error, :archive_unavailable}

  defp place_fragment(fragment, [window | rest]) when window.count < 64 do
    if window.duration_ns + fragment["duration_ns"] <= @duration_limit do
      [%{window | count: window.count + 1, duration_ns: window.duration_ns + fragment["duration_ns"]} | rest]
    else
      [new_window(fragment), window | rest]
    end
  end

  defp place_fragment(fragment, windows), do: [new_window(fragment) | windows]

  defp new_window(fragment), do: %{first: fragment["sequence"], count: 1, duration_ns: fragment["duration_ns"]}
end
