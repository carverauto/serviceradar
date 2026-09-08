defmodule ServiceRadarWebNGWeb.DashboardLive.Data.SurveyRaster do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      @sobelow_skip ["SQL.Query"]
      defp latest_survey_raster_summary_from_sql do
        sql = """
        SELECT r.session_id, r.min_x, r.max_x, r.min_z, r.max_z, r.cells, r.metadata, r.generated_at
        FROM platform.survey_coverage_rasters r
        WHERE r.overlay_type = 'wifi_rssi'
          AND r.selector_type = 'all'
          AND r.selector_value = '*'
        ORDER BY EXISTS (
          SELECT 1
          FROM platform.survey_room_artifacts a
          WHERE a.session_id = r.session_id
            AND a.artifact_type = 'floorplan_geojson'
            AND jsonb_typeof(a.metadata->'floorplan_segments') = 'array'
            AND jsonb_array_length(a.metadata->'floorplan_segments') > 0
        ) DESC,
        r.generated_at DESC
        LIMIT 1
        """

        case ServiceRadarWebNG.Repo.query(sql, [], timeout: 5_000) do
          {:ok, %{rows: [[session_id, _min_x, _max_x, _min_z, _max_z, cells, metadata, generated_at]]}} ->
            dashboard_survey_raster_summary(
              %{
                "session_id" => session_id,
                "cells" => cells,
                "metadata" => metadata,
                "generated_at" => generated_at
              },
              nil
            )

          _ ->
            empty_survey_raster_summary()
        end
      rescue
        _ -> empty_survey_raster_summary()
      end

      defp dashboard_survey_raster_summary(candidate, playlist_entry) when is_map(candidate) do
        session_id = map_value(candidate, "session_id")
        cells_payload = map_value(candidate, "cells") || %{}
        raw_cells = map_value(cells_payload, "cells") || []
        metadata = map_value(candidate, "metadata") || %{}
        raw_raster_cells = raw_cells |> Enum.map(&dashboard_raw_raster_cell/1) |> Enum.reject(&is_nil/1)
        raw_floorplan_segments = latest_dashboard_floorplan_segments(session_id)
        raw_ap_markers = latest_dashboard_ap_markers(session_id)

        {raster_cells, floorplan_segments, ap_markers, aspect_ratio} =
          raw_raster_cells
          |> normalize_dashboard_survey(raw_floorplan_segments)
          |> add_dashboard_ap_markers(raw_ap_markers)

        %{
          raster_session_id: session_id,
          raster_generated_at: map_value(candidate, "generated_at"),
          raster_cell_count: length(raw_cells),
          raster_cells: raster_cells,
          raster_surface_data_uri: nil,
          raster_aspect_ratio: aspect_ratio,
          floorplan_segment_count: length(floorplan_segments),
          floorplan_segments: floorplan_segments,
          ap_marker_count: length(ap_markers),
          ap_markers: ap_markers,
          raster_metadata: metadata,
          raster_playlist_entry_id: playlist_entry && playlist_entry.id,
          raster_playlist_label: playlist_entry && playlist_entry.label,
          raster_playlist_diagnostics: []
        }
      end

      defp fresh_raster_candidate?(candidate, max_age_seconds) when is_map(candidate) and is_integer(max_age_seconds) do
        case parse_dashboard_datetime(map_value(candidate, "generated_at")) do
          %DateTime{} = generated_at ->
            DateTime.diff(DateTime.utc_now(), generated_at, :second) <= max_age_seconds

          _ ->
            true
        end
      end

      defp fresh_raster_candidate?(_candidate, _max_age_seconds), do: true

      defp parse_dashboard_datetime(%DateTime{} = value), do: value

      defp parse_dashboard_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

      defp parse_dashboard_datetime(value) when is_binary(value) do
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> dt
          _ -> nil
        end
      end

      defp parse_dashboard_datetime(_value), do: nil

      defp dashboard_raw_raster_cell(cell) when is_map(cell) do
        x = map_value(cell, "x")
        z = map_value(cell, "z")
        rssi = map_value(cell, "rssi")

        with true <- is_number(x),
             true <- is_number(z),
             true <- is_number(rssi) do
          %{
            x: to_float(x),
            z: to_float(z),
            radius_m: clamp(to_float(map_value(cell, "radius_m") || 0.32), 0.08, 2.5),
            rssi: Float.round(to_float(rssi), 1),
            confidence: clamp(to_float(map_value(cell, "confidence") || 0.5), 0.15, 1.0)
          }
        else
          _ -> nil
        end
      end

      defp dashboard_raw_raster_cell(_cell), do: nil
    end
  end
end
