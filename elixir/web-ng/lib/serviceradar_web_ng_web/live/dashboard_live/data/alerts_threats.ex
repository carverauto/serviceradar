# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule ServiceRadarWebNGWeb.DashboardLive.Data.AlertsThreats do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      defp sparkline_tail(values) do
        values
        |> Enum.map(&to_float/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(-48)
      end

      @sobelow_skip ["SQL.Query"]
      defp alert_feed(time_window) do
        if relation_exists?("platform.alerts") do
          cutoff = cutoff_for_time_window(time_window)

          sql = """
          SELECT
            id::text,
            COALESCE(title, '') AS title,
            COALESCE(description, '') AS description,
            COALESCE(severity::text, '') AS severity,
            COALESCE(status::text, '') AS status,
            COALESCE(source_type::text, '') AS source_type,
            COALESCE(device_uid, '') AS device_uid,
            COALESCE(triggered_at, created_at) AS observed_at
          FROM platform.alerts
          WHERE COALESCE(triggered_at, created_at) >= $1
          ORDER BY COALESCE(triggered_at, created_at) DESC
          LIMIT 8
          """

          case ServiceRadarWebNG.Repo.query(sql, [cutoff]) do
            {:ok, %{rows: rows}} ->
              Enum.map(rows, fn [id, title, description, severity, status, source_type, device_uid, observed_at] ->
                %{
                  id: id,
                  title:
                    ServiceRadar.Observability.EventTitle.alert_title(%{"title" => title, "description" => description}),
                  description: description,
                  severity: severity,
                  status: status,
                  source_type: source_type,
                  device_uid: device_uid,
                  observed_at: observed_at
                }
              end)

            _ ->
              []
          end
        else
          []
        end
      rescue
        _ -> []
      end

      defp threat_intel_summary do
        empty_threat_intel_summary()
        |> Map.merge(threat_intel_indicator_counts())
        |> Map.merge(threat_intel_match_counts())
        |> Map.merge(threat_intel_recent_matches())
        |> Map.merge(threat_intel_latest_status())
      rescue
        _ -> empty_threat_intel_summary()
      end

      @sobelow_skip ["SQL.Query"]
      defp threat_intel_indicator_counts do
        counts =
          if relation_exists?("platform.threat_intel_indicators") do
            sql = """
            SELECT
              COUNT(*)::bigint,
              COUNT(DISTINCT source)::bigint
            FROM platform.threat_intel_indicators
            WHERE expires_at IS NULL OR expires_at > now()
            """

            case ServiceRadarWebNG.Repo.query(sql, []) do
              {:ok, %{rows: [[indicators, sources]]}} ->
                %{imported_indicators: to_int(indicators), sources: to_int(sources)}

              _ ->
                %{}
            end
          else
            %{}
          end

        source_objects =
          if relation_exists?("platform.threat_intel_source_objects") do
            case ServiceRadarWebNG.Repo.query("SELECT COUNT(*)::bigint FROM platform.threat_intel_source_objects", []) do
              {:ok, %{rows: [[count]]}} -> %{source_objects: to_int(count)}
              _ -> %{}
            end
          else
            %{}
          end

        Map.merge(counts, source_objects)
      end

      @sobelow_skip ["SQL.Query"]
      defp threat_intel_match_counts do
        if relation_exists?("platform.ip_threat_intel_cache") do
          sql = """
          SELECT
            COUNT(*) FILTER (WHERE matched = true AND expires_at > now())::bigint,
            COALESCE(SUM(match_count) FILTER (WHERE matched = true AND expires_at > now()), 0)::bigint,
            COALESCE(MAX(max_severity) FILTER (WHERE matched = true AND expires_at > now()), 0)::integer
          FROM platform.ip_threat_intel_cache
          """

          case ServiceRadarWebNG.Repo.query(sql, []) do
            {:ok, %{rows: [[matched_ips, indicator_matches, max_severity]]}} ->
              %{
                matched_ips: to_int(matched_ips),
                indicator_matches: to_int(indicator_matches),
                max_severity: to_int(max_severity)
              }

            _ ->
              %{}
          end
        else
          %{}
        end
      end

      @sobelow_skip ["SQL.Query"]
      defp threat_intel_recent_matches do
        if relation_exists?("platform.ip_threat_intel_cache") do
          sql = threat_intel_recent_matches_sql()

          case ServiceRadarWebNG.Repo.query(sql, []) do
            {:ok, %{rows: rows}} ->
              %{recent_matches: Enum.map(rows, &decode_threat_intel_match/1)}

            _ ->
              %{recent_matches: []}
          end
        else
          %{recent_matches: []}
        end
      end

      defp threat_intel_recent_matches_sql do
        if relation_exists?("platform.ocsf_devices") do
          """
          SELECT
            c.ip,
            c.match_count,
            COALESCE(c.max_severity, 0)::integer,
            COALESCE(c.sources, '{}'::text[]),
            c.looked_up_at,
            d.uid,
            d.hostname
          FROM platform.ip_threat_intel_cache c
          LEFT JOIN LATERAL (
            SELECT uid, hostname
            FROM platform.ocsf_devices
            WHERE ip = c.ip
              AND deleted_at IS NULL
            ORDER BY last_seen_time DESC NULLS LAST
            LIMIT 1
          ) d ON true
          WHERE c.matched = true AND c.expires_at > now()
          ORDER BY c.looked_up_at DESC
          LIMIT 8
          """
        else
          """
          SELECT
            ip,
            match_count,
            COALESCE(max_severity, 0)::integer,
            COALESCE(sources, '{}'::text[]),
            looked_up_at,
            NULL,
            NULL
          FROM platform.ip_threat_intel_cache
          WHERE matched = true AND expires_at > now()
          ORDER BY looked_up_at DESC
          LIMIT 8
          """
        end
      end

      defp decode_threat_intel_match([ip, match_count, max_severity, sources, looked_up_at, device_uid, hostname]) do
        %{
          ip: to_string(ip || ""),
          match_count: to_int(match_count),
          max_severity: to_int(max_severity),
          sources: decode_threat_intel_sources(sources),
          looked_up_at: looked_up_at,
          device_uid: blank_to_nil(device_uid),
          hostname: blank_to_nil(hostname)
        }
      end

      defp decode_threat_intel_sources(sources) when is_list(sources) do
        sources
        |> Enum.map(&to_string/1)
        |> Enum.reject(&(&1 == ""))
      end

      defp decode_threat_intel_sources(_sources), do: []

      defp blank_to_nil(nil), do: nil

      defp blank_to_nil(value) when is_binary(value) do
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end
      end

      defp blank_to_nil(value), do: blank_to_nil(to_string(value))

      @sobelow_skip ["SQL.Query"]
      defp threat_intel_latest_status do
        if relation_exists?("platform.threat_intel_sync_statuses") do
          sql = """
          SELECT
            provider,
            source,
            last_status,
            COALESCE(last_message, last_error, ''),
            last_attempt_at,
            last_success_at,
            indicators_count,
            skipped_count,
            total_count
          FROM platform.threat_intel_sync_statuses
          ORDER BY last_attempt_at DESC
          LIMIT 1
          """

          case ServiceRadarWebNG.Repo.query(sql, []) do
            {:ok,
             %{
               rows: [[provider, source, status, message, attempted_at, success_at, indicators, skipped, total]]
             }} ->
              %{
                latest_provider: provider,
                latest_source: source,
                latest_status: status,
                latest_message: message,
                latest_attempt_at: attempted_at,
                latest_success_at: success_at,
                latest_sync_indicators: to_int(indicators),
                latest_sync_skipped: to_int(skipped),
                latest_sync_total: to_int(total)
              }

            _ ->
              %{}
          end
        else
          %{}
        end
      end
    end
  end
end
