defmodule ServiceRadarWebNG.FieldSurveyFloorplanTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.FieldSurveyFloorplan

  test "rectify_segments snaps near-orthogonal RoomPlan walls without changing diagonal geometry" do
    segments = [
      %{kind: "wall", start_x: 0.0, start_z: 0.0, end_x: 5.0, end_z: 0.28, height: 2.4},
      %{kind: "wall", start_x: 5.0, start_z: 0.0, end_x: 4.78, end_z: 3.0, height: 2.4},
      %{kind: "wall", start_x: 0.0, start_z: 0.0, end_x: 2.0, end_z: 1.2, height: 2.4}
    ]

    [horizontal, vertical, diagonal] = FieldSurveyFloorplan.rectify_segments(segments)

    assert_in_delta orthogonal_delta_deg(horizontal, vertical), 90.0, 0.001
    assert_in_delta diagonal.end_z - diagonal.start_z, 1.2, 0.001
  end

  test "segments_from_metadata returns rectified cached floorplan segments" do
    metadata = %{
      "floorplan_segments" => [
        %{"kind" => "wall", "start_x" => 0.0, "start_z" => 0.0, "end_x" => 4.0, "end_z" => 0.2},
        %{"kind" => "wall", "start_x" => 4.0, "start_z" => 0.0, "end_x" => 3.88, "end_z" => 3.0}
      ]
    }

    [horizontal, vertical] = FieldSurveyFloorplan.segments_from_metadata(metadata)

    assert_in_delta orthogonal_delta_deg(horizontal, vertical), 90.0, 0.001
  end

  defp orthogonal_delta_deg(left, right) do
    left_angle = segment_angle(left)
    right_angle = segment_angle(right)
    delta = abs(left_angle - right_angle)
    delta = min(delta, :math.pi() - delta)

    delta * 180.0 / :math.pi()
  end

  defp segment_angle(segment), do: :math.atan2(segment.end_z - segment.start_z, segment.end_x - segment.start_x)
end
