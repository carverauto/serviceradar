defmodule ServiceRadarRecording.Initialization do
  @moduledoc """
  Derive the supported single-track AVC format from initialization bytes.

  Live packaging and restarted readers use the same declaration. The digest
  binds it to the retained bytes; this does not establish publication authority
  or replace fragment integrity and independent decoder checks.
  """

  alias Membrane.MP4.Container

  def parse(payload) when is_binary(payload) and byte_size(payload) <= 1_048_576 do
    with {:ok, boxes, <<>>} <- Container.parse(payload),
         %{fields: %{timescale: timescale}} when timescale in 1..1_000_000_000 <-
           box(boxes, [:moov, :trak, :mdia, :mdhd]),
         %{fields: %{entry_count: 1}, children: [avc1: %{children: children}]} <-
           box(boxes, [:moov, :trak, :mdia, :minf, :stbl, :stsd]),
         %{content: <<1, 66, compatibility, level, _rest::binary>>} <- box(children, [:avcC]) do
      {:ok,
       %{
         sha256: :sha256 |> :crypto.hash(payload) |> Base.encode16(case: :lower),
         timescale: timescale,
         codecs: %{avc1: %{profile: 66, compatibility: compatibility, level: level}}
       }}
    else
      _ -> {:error, :invalid_initialization}
    end
  rescue
    # The dependency raises for some malformed boxes instead of returning an error.
    _ -> {:error, :invalid_initialization}
  end

  def parse(_payload), do: {:error, :invalid_initialization}

  defp box(boxes, [name]) do
    case Keyword.get_values(boxes, name) do
      [box] -> box
      _ -> nil
    end
  end

  defp box(boxes, [name | rest]) do
    with %{children: children} <- box(boxes, [name]), do: box(children, rest)
  end
end
