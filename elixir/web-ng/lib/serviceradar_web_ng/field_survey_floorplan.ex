defmodule ServiceRadarWebNG.FieldSurveyFloorplan do
  @moduledoc """
  Helpers for the small 2D FieldSurvey floorplan projection.

  Large RoomPlan and point-cloud artifacts stay in object storage. The derived
  2D linework is compact enough to cache in Postgres metadata for dashboard and
  review rendering.
  """

  @allowed_kinds MapSet.new(["wall", "door", "window"])
  @max_cached_segments 240
  @orthogonal_snap_tolerance_rad 0.24
  @min_snap_segment_length_m 0.35

  @type segment :: %{
          kind: String.t(),
          start_x: float(),
          start_z: float(),
          end_x: float(),
          end_z: float()
        }

  @spec enrich_metadata(String.t(), binary(), map()) :: map()
  def enrich_metadata("floorplan_geojson", payload, metadata) when is_binary(payload) and is_map(metadata) do
    segments = payload |> decode_segments() |> rectify_segments() |> Enum.take(@max_cached_segments)

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

  @spec rectify_segments([segment()]) :: [segment()]
  def rectify_segments(segments) when is_list(segments) do
    axis = dominant_axis_angle(segments)

    Enum.map(segments, fn segment ->
      rectify_segment(segment, axis)
    end)
  end

  def rectify_segments(_segments), do: []

  @spec segments_from_metadata(map() | nil) :: [segment()]
  def segments_from_metadata(metadata) when is_map(metadata) do
    metadata
    |> map_value("floorplan_segments")
    |> case do
      segments when is_list(segments) ->
        segments
        |> Enum.map(&stored_segment/1)
        |> Enum.reject(&is_nil/1)
        |> rectify_segments()
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

  defp dominant_axis_angle(segments) do
    weighted =
      segments
      |> Enum.filter(&(&1.kind == "wall"))
      |> Enum.map(fn segment -> {segment_angle(segment), segment_length(segment)} end)
      |> Enum.filter(fn {_angle, length} -> length >= @min_snap_segment_length_m end)

    case weighted do
      [] ->
        0.0

      [_ | _] ->
        {x_sum, z_sum} =
          Enum.reduce(weighted, {0.0, 0.0}, fn {angle, length}, {x_acc, z_acc} ->
            {x_acc + :math.cos(angle * 4.0) * length, z_acc + :math.sin(angle * 4.0) * length}
          end)

        if abs(x_sum) + abs(z_sum) < 0.001 do
          0.0
        else
          normalize_angle(:math.atan2(z_sum, x_sum) / 4.0)
        end
    end
  end

  defp rectify_segment(segment, axis) do
    length = segment_length(segment)

    if length < @min_snap_segment_length_m do
      segment
    else
      angle = segment_angle(segment)
      {target, delta} = nearest_orthogonal_axis(angle, axis)

      if delta <= @orthogonal_snap_tolerance_rad do
        midpoint_x = (segment.start_x + segment.end_x) / 2.0
        midpoint_z = (segment.start_z + segment.end_z) / 2.0
        half_x = :math.cos(target) * length / 2.0
        half_z = :math.sin(target) * length / 2.0

        %{
          segment
          | start_x: midpoint_x - half_x,
            start_z: midpoint_z - half_z,
            end_x: midpoint_x + half_x,
            end_z: midpoint_z + half_z
        }
      else
        segment
      end
    end
  end

  defp nearest_orthogonal_axis(angle, axis) do
    -4..4
    |> Enum.map(fn step ->
      target = axis + step * :math.pi() / 2.0
      {target, abs(normalize_angle(angle - target))}
    end)
    |> Enum.min_by(fn {_target, delta} -> delta end)
  end

  defp segment_angle(segment), do: :math.atan2(segment.end_z - segment.start_z, segment.end_x - segment.start_x)

  defp segment_length(segment) do
    :math.sqrt(:math.pow(segment.end_x - segment.start_x, 2) + :math.pow(segment.end_z - segment.start_z, 2))
  end

  defp normalize_angle(angle) do
    cond do
      angle > :math.pi() -> normalize_angle(angle - 2.0 * :math.pi())
      angle <= -:math.pi() -> normalize_angle(angle + 2.0 * :math.pi())
      true -> angle
    end
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
