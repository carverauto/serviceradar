defmodule ServiceRadarWebNG.FieldSurveyFloorplan do
  @moduledoc """
  Helpers for the small 2D FieldSurvey floorplan projection.

  Large RoomPlan and point-cloud artifacts stay in object storage. The derived
  2D linework is compact enough to cache in Postgres metadata for dashboard and
  review rendering.
  """

  @allowed_kinds MapSet.new(["wall", "door", "window"])
  @max_cached_segments 240

  @type segment :: %{
          kind: String.t(),
          start_x: float(),
          start_z: float(),
          end_x: float(),
          end_z: float()
        }

  @spec enrich_metadata(String.t(), binary(), map()) :: map()
  def enrich_metadata("floorplan_geojson", payload, metadata) when is_binary(payload) and is_map(metadata) do
    segments = payload |> decode_segments() |> Enum.take(@max_cached_segments)

    if segments == [] do
      metadata
    else
      Map.merge(metadata, %{
        "floorplan_segment_count" => length(segments),
        "floorplan_segments" => Enum.map(segments, &stringify_segment/1)
      })
    end
  end

  def enrich_metadata(_artifact_type, _payload, metadata) when is_map(metadata), do: metadata
  def enrich_metadata(_artifact_type, _payload, _metadata), do: %{}

  @spec decode_segments(binary()) :: [segment()]
  def decode_segments(payload) when is_binary(payload) do
    with {:ok, %{"type" => "FeatureCollection", "features" => features}} <- Jason.decode(payload),
         true <- is_list(features) do
      features
      |> Enum.flat_map(&feature_segment/1)
      |> Enum.take(@max_cached_segments)
    else
      _ -> []
    end
  end

  def decode_segments(_payload), do: []

  @spec segments_from_metadata(map() | nil) :: [segment()]
  def segments_from_metadata(metadata) when is_map(metadata) do
    metadata
    |> map_value("floorplan_segments")
    |> case do
      segments when is_list(segments) ->
        segments
        |> Enum.map(&stored_segment/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(@max_cached_segments)

      _ ->
        []
    end
  end

  def segments_from_metadata(_metadata), do: []

  defp feature_segment(%{
         "geometry" => %{"type" => "LineString", "coordinates" => [start_coord, end_coord | _]},
         "properties" => properties
       }) do
    with {:ok, start_x, start_z} <- coordinate(start_coord),
         {:ok, end_x, end_z} <- coordinate(end_coord) do
      [
        %{
          kind: kind(map_value(properties || %{}, "kind")),
          start_x: start_x,
          start_z: start_z,
          end_x: end_x,
          end_z: end_z,
          height: number_or_nil(map_value(properties || %{}, "height_m"))
        }
      ]
    else
      _ -> []
    end
  end

  defp feature_segment(_feature), do: []

  defp stored_segment(segment) when is_map(segment) do
    with {:ok, start_x} <- number_value(segment, "start_x"),
         {:ok, start_z} <- number_value(segment, "start_z"),
         {:ok, end_x} <- number_value(segment, "end_x"),
         {:ok, end_z} <- number_value(segment, "end_z") do
      %{
        kind: kind(map_value(segment, "kind")),
        start_x: start_x,
        start_z: start_z,
        end_x: end_x,
        end_z: end_z,
        height: number_or_nil(map_value(segment, "height"))
      }
    else
      _ -> nil
    end
  end

  defp stored_segment(_segment), do: nil

  defp stringify_segment(segment) do
    %{
      "kind" => segment.kind,
      "start_x" => segment.start_x,
      "start_z" => segment.start_z,
      "end_x" => segment.end_x,
      "end_z" => segment.end_z,
      "height" => Map.get(segment, :height)
    }
  end

  defp coordinate([x, z | _]) when is_number(x) and is_number(z), do: {:ok, x * 1.0, z * 1.0}
  defp coordinate(_coordinate), do: :error

  defp number_value(map, key) do
    case map_value(map, key) do
      value when is_number(value) -> {:ok, value * 1.0}
      _ -> :error
    end
  end

  defp number_or_nil(value) when is_number(value), do: value * 1.0
  defp number_or_nil(_value), do: nil

  defp kind(kind) when is_binary(kind) do
    if MapSet.member?(@allowed_kinds, kind), do: kind, else: "wall"
  end

  defp kind(_kind), do: "wall"

  defp map_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, atom_key(key))
  defp map_value(_map, _key), do: nil

  defp atom_key("end_x"), do: :end_x
  defp atom_key("end_z"), do: :end_z
  defp atom_key("floorplan_segments"), do: :floorplan_segments
  defp atom_key("height"), do: :height
  defp atom_key("height_m"), do: :height_m
  defp atom_key("kind"), do: :kind
  defp atom_key("start_x"), do: :start_x
  defp atom_key("start_z"), do: :start_z
  defp atom_key(_key), do: nil
end
