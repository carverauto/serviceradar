defmodule ServiceRadarWebNGWeb.DashboardLive.Data.SurveySummary do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      @sobelow_skip ["SQL.Query"]
      defp survey_summary(scope) do
        summary =
          cond do
            relation_exists?("platform.survey_rf_pose_matches") ->
              sql = """
              SELECT
                COUNT(*)::bigint AS sample_count,
                COUNT(DISTINCT session_id)::bigint AS session_count,
                COALESCE(AVG(rssi_dbm), 0)::float8 AS avg_rssi,
                COUNT(DISTINCT bssid)::bigint AS secure_count
              FROM platform.survey_rf_pose_matches
              WHERE x IS NOT NULL
                AND z IS NOT NULL
                AND rssi_dbm IS NOT NULL
              """

              case ServiceRadarWebNG.Repo.query(sql, [], timeout: 5_000) do
                {:ok, %{rows: [[samples, sessions, avg_rssi, secure]]}} ->
                  %{
                    sample_count: to_int(samples),
                    session_count: to_int(sessions),
                    avg_rssi: avg_rssi |> to_float() |> Float.round(1),
                    secure_count: to_int(secure)
                  }

                _ ->
                  empty_survey_summary()
              end

            relation_exists?("platform.survey_samples") ->
              sql = """
              SELECT
                COUNT(*)::bigint AS sample_count,
                COUNT(DISTINCT session_id)::bigint AS session_count,
                COALESCE(AVG(rssi), 0)::float8 AS avg_rssi,
                COUNT(*) FILTER (WHERE is_secure = true)::bigint AS secure_count
              FROM platform.survey_samples
              """

              case ServiceRadarWebNG.Repo.query(sql, [], timeout: 5_000) do
                {:ok, %{rows: [[samples, sessions, avg_rssi, secure]]}} ->
                  %{
                    sample_count: to_int(samples),
                    session_count: to_int(sessions),
                    avg_rssi: avg_rssi |> to_float() |> Float.round(1),
                    secure_count: to_int(secure)
                  }

                _ ->
                  empty_survey_summary()
              end

            true ->
              empty_survey_summary()
          end

        Map.merge(summary, latest_survey_raster_summary(scope))
      rescue
        _ -> empty_survey_summary()
      end

      defp latest_survey_raster_summary(scope) do
        if relation_exists?("platform.survey_coverage_rasters") do
          case playlist_survey_raster_summary(scope) do
            {:ok, summary} ->
              summary

            {:fallback, diagnostics} ->
              Map.put(latest_survey_raster_summary_from_sql(), :raster_playlist_diagnostics, diagnostics)
          end
        else
          empty_survey_raster_summary()
        end
      rescue
        _ -> empty_survey_raster_summary()
      end

      defp playlist_survey_raster_summary(scope) do
        case ServiceRadarWebNG.FieldSurveyDashboardPlaylist.list(scope) do
          {:ok, entries} ->
            entries
            |> Enum.filter(& &1.enabled)
            |> rotate_playlist_entries()
            |> resolve_playlist_entries(scope)

          _ ->
            {:fallback, [playlist_diagnostic("Playlist unavailable")]}
        end
      end

      defp resolve_playlist_entries([], _scope), do: {:fallback, []}

      defp resolve_playlist_entries(entries, scope) do
        entries
        |> Enum.reduce_while([], fn entry, diagnostics ->
          case ServiceRadarWebNG.FieldSurveyDashboardPlaylist.preview(scope, entry.srql_query) do
            {:ok, candidate} ->
              if fresh_raster_candidate?(candidate, entry.max_age_seconds) do
                {:halt, {:ok, dashboard_survey_raster_summary(candidate, entry)}}
              else
                {:cont, [playlist_diagnostic("#{entry.label}: raster is older than max age") | diagnostics]}
              end

            {:error, reason} ->
              {:cont, [playlist_diagnostic("#{entry.label}: #{format_playlist_error(reason)}") | diagnostics]}
          end
        end)
        |> case do
          {:ok, _summary} = result -> result
          diagnostics when is_list(diagnostics) -> {:fallback, Enum.reverse(diagnostics)}
        end
      end

      defp playlist_diagnostic(message), do: %{level: :warning, message: message}

      defp format_playlist_error(:playlist_query_must_target_field_survey_rasters),
        do: "query must target field_survey_rasters"

      defp format_playlist_error(:no_field_survey_raster_candidate), do: "query returned no floorplan-backed raster"

      defp format_playlist_error(reason), do: inspect(reason)

      defp rotate_playlist_entries([]), do: []

      defp rotate_playlist_entries(entries) do
        total_dwell =
          entries
          |> Enum.map(&max(&1.dwell_seconds || 30, 5))
          |> Enum.sum()

        position = rem(System.system_time(:second), max(total_dwell, 1))

        {index, _elapsed} =
          entries
          |> Enum.map(&max(&1.dwell_seconds || 30, 5))
          |> Enum.with_index()
          |> Enum.reduce_while({0, 0}, fn {dwell, index}, {_current_index, elapsed} ->
            next_elapsed = elapsed + dwell

            if position < next_elapsed do
              {:halt, {index, elapsed}}
            else
              {:cont, {index, next_elapsed}}
            end
          end)

        Enum.drop(entries, index) ++ Enum.take(entries, index)
      end
    end
  end
end
