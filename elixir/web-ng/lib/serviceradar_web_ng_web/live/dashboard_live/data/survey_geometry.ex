# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule ServiceRadarWebNGWeb.DashboardLive.Data.SurveyGeometry do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      defp normalize_dashboard_survey(raw_cells, raw_segments) do
        angle = dashboard_rotation_angle(raw_cells, raw_segments)

        {rotated_cells, rotated_segments, bounds, final_angle} =
          case dashboard_rotated_projection(raw_cells, raw_segments, angle) do
            {cells, segments, %{aspect_ratio: aspect_ratio} = bounds} when aspect_ratio < 1.0 ->
              if raw_cells == [] and raw_segments == [] do
                {cells, segments, bounds, angle}
              else
                {flipped_cells, flipped_segments, flipped_bounds} =
                  dashboard_rotated_projection(raw_cells, raw_segments, angle + :math.pi() / 2.0)

                {flipped_cells, flipped_segments, flipped_bounds, angle + :math.pi() / 2.0}
              end

            {cells, segments, bounds} ->
              {cells, segments, bounds, angle}
          end

        raster_cells =
          rotated_cells
          |> Enum.map(&project_dashboard_cell(&1, bounds))
          |> Enum.sort_by(& &1.confidence, :desc)
          |> Enum.take(900)

        floorplan_segments =
          rotated_segments
          |> Enum.map(&project_dashboard_segment(&1, bounds))
          |> Enum.reject(&zero_dashboard_segment?/1)
          |> Enum.take(180)

        {raster_cells, floorplan_segments, bounds, final_angle, Map.get(bounds, :aspect_ratio, 1.78)}
      end

      defp add_dashboard_ap_markers({raster_cells, floorplan_segments, bounds, angle, aspect_ratio}, raw_ap_markers) do
        ap_markers =
          raw_ap_markers
          |> Enum.map(&score_dashboard_ap_marker/1)
          |> Enum.filter(&dashboard_ap_marker_candidate?/1)
          |> Enum.sort_by(
            fn marker ->
              {marker.confidence || 0.0, marker.sample_count || 0, marker.strongest_rssi || -120}
            end,
            :desc
          )
          |> cluster_dashboard_ap_markers()
          |> Enum.map(&rotate_dashboard_point(&1, angle))
          |> Enum.map(&project_dashboard_ap_marker(&1, bounds))
          |> Enum.reject(&is_nil/1)
          |> Enum.take(3)

        {raster_cells, floorplan_segments, ap_markers, aspect_ratio}
      end

      defp dashboard_rotated_projection(raw_cells, raw_segments, angle) do
        rotated_cells = Enum.map(raw_cells, &rotate_dashboard_point(&1, angle))
        rotated_segments = Enum.map(raw_segments, &rotate_dashboard_segment(&1, angle))
        bounds = dashboard_projection_bounds(rotated_cells, rotated_segments)

        {rotated_cells, rotated_segments, bounds}
      end

      defp dashboard_rotation_angle(_raw_cells, [_ | _] = raw_segments) do
        primary_segments =
          case Enum.filter(raw_segments, &(&1.kind == "wall")) do
            [] -> raw_segments
            walls -> walls
          end

        primary_segments
        |> Enum.max_by(&dashboard_segment_length/1, fn -> nil end)
        |> case do
          %{start_x: start_x, start_z: start_z, end_x: end_x, end_z: end_z} ->
            :math.atan2(end_z - start_z, end_x - start_x)

          _ ->
            0.0
        end
        |> normalize_dashboard_angle()
      end

      defp dashboard_rotation_angle([_ | _] = raw_cells, _raw_segments) do
        count = length(raw_cells)
        mean_x = raw_cells |> Enum.map(& &1.x) |> Enum.sum() |> Kernel./(count)
        mean_z = raw_cells |> Enum.map(& &1.z) |> Enum.sum() |> Kernel./(count)

        {cov_xx, cov_zz, cov_xz} =
          Enum.reduce(raw_cells, {0.0, 0.0, 0.0}, fn cell, {xx, zz, xz} ->
            dx = cell.x - mean_x
            dz = cell.z - mean_z
            {xx + dx * dx, zz + dz * dz, xz + dx * dz}
          end)

        normalize_dashboard_angle(0.5 * :math.atan2(2.0 * cov_xz, cov_xx - cov_zz))
      end

      defp dashboard_rotation_angle(_raw_cells, _raw_segments), do: 0.0

      defp normalize_dashboard_angle(angle) do
        cond do
          angle > :math.pi() / 2.0 -> angle - :math.pi()
          angle < -:math.pi() / 2.0 -> angle + :math.pi()
          true -> angle
        end
      end

      defp rotate_dashboard_point(%{x: x, z: z} = point, angle) do
        cos = :math.cos(-angle)
        sin = :math.sin(-angle)

        point
        |> Map.put(:x_rot, x * cos - z * sin)
        |> Map.put(:z_rot, x * sin + z * cos)
      end

      defp rotate_dashboard_segment(segment, angle) do
        start = rotate_dashboard_point(%{x: segment.start_x, z: segment.start_z}, angle)
        finish = rotate_dashboard_point(%{x: segment.end_x, z: segment.end_z}, angle)

        segment
        |> Map.put(:start_x_rot, start.x_rot)
        |> Map.put(:start_z_rot, start.z_rot)
        |> Map.put(:end_x_rot, finish.x_rot)
        |> Map.put(:end_z_rot, finish.z_rot)
      end

      defp dashboard_projection_bounds(rotated_cells, rotated_segments) do
        points =
          Enum.map(rotated_cells, &%{x: &1.x_rot, z: &1.z_rot}) ++
            Enum.flat_map(rotated_segments, fn segment ->
              [
                %{x: segment.start_x_rot, z: segment.start_z_rot},
                %{x: segment.end_x_rot, z: segment.end_z_rot}
              ]
            end)

        xs = Enum.map(points, & &1.x)
        zs = Enum.map(points, & &1.z)

        case {Enum.min(xs, fn -> nil end), Enum.max(xs, fn -> nil end), Enum.min(zs, fn -> nil end),
              Enum.max(zs, fn -> nil end)} do
          {nil, _, _, _} ->
            %{min_x: -1.0, max_x: 1.0, min_z: -1.0, max_z: 1.0, aspect_ratio: 1.0}

          {min_x, max_x, min_z, max_z} ->
            x_pad = max((max_x - min_x) * 0.08, 0.6)
            z_pad = max((max_z - min_z) * 0.08, 0.6)
            min_x = min_x - x_pad
            max_x = max_x + x_pad
            min_z = min_z - z_pad
            max_z = max_z + z_pad
            width = max(max_x - min_x, 0.01)
            height = max(max_z - min_z, 0.01)

            %{
              min_x: min_x,
              max_x: max_x,
              min_z: min_z,
              max_z: max_z,
              aspect_ratio: clamp(width / height, 0.72, 3.2)
            }
        end
      end

      defp project_dashboard_cell(cell, bounds) do
        width = max(bounds.max_x - bounds.min_x, 0.01)
        height = max(bounds.max_z - bounds.min_z, 0.01)
        meters_per_pct = max(width, height) / 100.0

        cell
        |> Map.put(:x_pct, clamp((cell.x_rot - bounds.min_x) / width * 100.0, 0.0, 100.0))
        |> Map.put(:z_pct, 100.0 - clamp((cell.z_rot - bounds.min_z) / height * 100.0, 0.0, 100.0))
        |> Map.put(:radius_pct, clamp(cell.radius_m / max(meters_per_pct, 0.01), 1.6, 7.0))
      end

      defp project_dashboard_segment(segment, bounds) do
        width = max(bounds.max_x - bounds.min_x, 0.01)
        height = max(bounds.max_z - bounds.min_z, 0.01)

        segment
        |> Map.put(:start_x_pct, clamp((segment.start_x_rot - bounds.min_x) / width * 100.0, 0.0, 100.0))
        |> Map.put(:start_z_pct, 100.0 - clamp((segment.start_z_rot - bounds.min_z) / height * 100.0, 0.0, 100.0))
        |> Map.put(:end_x_pct, clamp((segment.end_x_rot - bounds.min_x) / width * 100.0, 0.0, 100.0))
        |> Map.put(:end_z_pct, 100.0 - clamp((segment.end_z_rot - bounds.min_z) / height * 100.0, 0.0, 100.0))
      end

      defp project_dashboard_ap_marker(marker, bounds) do
        width = max(bounds.max_x - bounds.min_x, 0.01)
        height = max(bounds.max_z - bounds.min_z, 0.01)
        x_pct = clamp((marker.x_rot - bounds.min_x) / width * 100.0, 0.0, 100.0)
        z_pct = 100.0 - clamp((marker.z_rot - bounds.min_z) / height * 100.0, 0.0, 100.0)

        marker
        |> Map.put(:x_pct, x_pct)
        |> Map.put(:z_pct, z_pct)
      end

      defp dashboard_segment_length(%{start_x: start_x, start_z: start_z, end_x: end_x, end_z: end_z}) do
        :math.sqrt(:math.pow(end_x - start_x, 2) + :math.pow(end_z - start_z, 2))
      end
    end
  end
end
