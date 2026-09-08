defmodule ServiceRadarWebNGWeb.DashboardLive.Data.SurveyMarkers do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      defp latest_dashboard_ap_markers(_session_id) do
        # AP/device enrichment currently depends on raw RF+pose scans and can block the dashboard.
        # Keep the dashboard card fast; richer AP drill-in belongs behind an indexed summary path.
        []
      end

      defp score_dashboard_ap_marker(
             %{sample_count: sample_count, support_count: support_count, strongest_rssi: strongest_rssi} = marker
           ) do
        sample_score = min(:math.log10(max(sample_count, 1)) / 3.0, 1.0)
        support_score = min(:math.log10(max(support_count, 1)) / 2.3, 1.0)
        signal_score = min(max((strongest_rssi + 86.0) / 36.0, 0.0), 1.0)
        confidence = sample_score * 0.36 + support_score * 0.34 + signal_score * 0.3

        Map.put(marker, :confidence, Float.round(confidence, 3))
      end

      defp dashboard_ap_marker_candidate?(marker) do
        (Map.get(marker, :confidence) || 0.0) >= 0.82 and
          (Map.get(marker, :support_count) || 0) >= 20 and
          is_number(Map.get(marker, :x)) and
          is_number(Map.get(marker, :z)) and
          not invalid_dashboard_bssid?(Map.get(marker, :bssid))
      end

      defp cluster_dashboard_ap_markers(markers) do
        Enum.reduce(markers, [], fn marker, selected ->
          if Enum.any?(selected, &same_dashboard_ap_candidate?(&1, marker)) do
            selected
          else
            selected ++ [marker]
          end
        end)
      end

      defp same_dashboard_ap_candidate?(left, right) do
        distance =
          :math.sqrt(
            :math.pow((Map.get(left, :x) || 0.0) - (Map.get(right, :x) || 0.0), 2) +
              :math.pow((Map.get(left, :z) || 0.0) - (Map.get(right, :z) || 0.0), 2)
          )

        same_dashboard_radio_family?(Map.get(left, :bssid), Map.get(right, :bssid)) or distance <= 1.8
      end

      defp same_dashboard_radio_family?(left, right) when is_binary(left) and is_binary(right) do
        left_parts = left |> String.downcase() |> String.split(":")
        right_parts = right |> String.downcase() |> String.split(":")

        length(left_parts) == 6 and length(right_parts) == 6 and Enum.take(left_parts, 4) == Enum.take(right_parts, 4)
      end

      defp same_dashboard_radio_family?(_left, _right), do: false

      defp invalid_dashboard_bssid?(bssid) when is_binary(bssid) do
        normalized = String.downcase(String.trim(bssid))
        normalized in ["", "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff"]
      end

      defp invalid_dashboard_bssid?(_bssid), do: true

      @sobelow_skip ["SQL.Query"]
      defp latest_dashboard_floorplan_segments(session_id) do
        if relation_exists?("platform.survey_room_artifacts") do
          sql = """
          SELECT metadata
          FROM platform.survey_room_artifacts
          WHERE session_id = $1
            AND artifact_type = 'floorplan_geojson'
            AND jsonb_typeof(metadata->'floorplan_segments') = 'array'
            AND jsonb_array_length(metadata->'floorplan_segments') > 0
          ORDER BY uploaded_at DESC
          LIMIT 1
          """

          case ServiceRadarWebNG.Repo.query(sql, [session_id]) do
            {:ok, %{rows: [[metadata]]}} ->
              ServiceRadarWebNG.FieldSurveyFloorplan.segments_from_metadata(metadata)

            _ ->
              []
          end
        else
          []
        end
      rescue
        _ -> []
      end

      defp zero_dashboard_segment?(segment) do
        abs(segment.start_x_pct - segment.end_x_pct) < 0.01 and abs(segment.start_z_pct - segment.end_z_pct) < 0.01
      end
    end
  end
end
