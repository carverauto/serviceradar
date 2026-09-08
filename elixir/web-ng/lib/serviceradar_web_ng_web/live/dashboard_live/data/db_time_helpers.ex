defmodule ServiceRadarWebNGWeb.DashboardLive.Data.DbTimeHelpers do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      defp relation_exists?(relation_name) do
        case ServiceRadarWebNG.Repo.query("SELECT to_regclass($1) IS NOT NULL", [relation_name]) do
          {:ok, %{rows: [[true]]}} -> true
          _ -> false
        end
      end

      defp netflow_location_anchors_available? do
        relation_exists?("platform.netflow_local_cidrs") and
          column_exists?("platform.netflow_local_cidrs", "latitude") and
          column_exists?("platform.netflow_local_cidrs", "longitude") and
          column_exists?("platform.netflow_local_cidrs", "location_label")
      end

      defp anchor_partition_filter(relation) do
        if column_exists?(qualified_relation_name(relation), "partition") do
          "(c.partition IS NULL OR c.partition = f.partition)"
        else
          "TRUE"
        end
      end

      defp qualified_relation_name("platform." <> _ = relation), do: relation
      defp qualified_relation_name(relation), do: "platform.#{relation}"

      defp endpoint_inet_expr(column) do
        """
        (CASE
          WHEN NULLIF(#{column}, '') ~ '^[0-9A-Fa-f:.]+$'
          THEN NULLIF(#{column}, '')::inet
          ELSE NULL::inet
        END)
        """
      end

      @sobelow_skip ["SQL.Query"]
      defp column_exists?(relation_name, column_name) do
        case String.split(relation_name, ".", parts: 2) do
          [schema, table] ->
            sql = """
            SELECT EXISTS (
              SELECT 1
              FROM information_schema.columns
              WHERE table_schema = $1
                AND table_name = $2
                AND column_name = $3
            )
            """

            case ServiceRadarWebNG.Repo.query(sql, [schema, table, column_name]) do
              {:ok, %{rows: [[true]]}} -> true
              _ -> false
            end

          _ ->
            false
        end
      end

      defp anchored_expr(true, anchor_expr, fallback_expr), do: "COALESCE(#{anchor_expr}, #{fallback_expr})"
      defp anchored_expr(false, _anchor_expr, fallback_expr), do: fallback_expr

      defp ipinfo_coalesce(true, primary_expr, ipinfo_expr), do: "COALESCE(#{primary_expr}, #{ipinfo_expr})"
      defp ipinfo_coalesce(false, primary_expr, _ipinfo_expr), do: primary_expr

      defp anchored_label_expr(true, anchor_alias, fallback_expr),
        do: "COALESCE(#{anchor_alias}.location_label, #{anchor_alias}.label, #{fallback_expr})"

      defp anchored_label_expr(false, _anchor_alias, fallback_expr), do: fallback_expr

      defp anchored_country_expr(true, anchor_alias, fallback_expr) do
        """
        CASE
          WHEN #{anchor_alias}.latitude IS NOT NULL AND #{anchor_alias}.longitude IS NOT NULL
          THEN NULL::text
          ELSE #{fallback_expr}
        END
        """
      end

      defp anchored_country_expr(false, _anchor_alias, fallback_expr), do: fallback_expr

      defp anchor_label_select_expr(true, anchor_alias),
        do: "COALESCE(#{anchor_alias}.location_label, #{anchor_alias}.label)"

      defp anchor_label_select_expr(false, _anchor_alias), do: "NULL::text"

      defp local_anchor_select_expr(true, anchor_alias),
        do: "(#{anchor_alias}.latitude IS NOT NULL AND #{anchor_alias}.longitude IS NOT NULL)"

      defp local_anchor_select_expr(false, _anchor_alias), do: "FALSE"

      defp flow_count_expr("ocsf_network_activity"), do: "COUNT(*)"
      defp flow_count_expr(_relation), do: "SUM(flow_count)"

      defp cutoff_for_time_window("last_1h"), do: DateTime.add(DateTime.utc_now(), -1, :hour)
      defp cutoff_for_time_window("last_6h"), do: DateTime.add(DateTime.utc_now(), -6, :hour)
      defp cutoff_for_time_window("last_24h"), do: DateTime.add(DateTime.utc_now(), -24, :hour)
      defp cutoff_for_time_window("last_7d"), do: DateTime.add(DateTime.utc_now(), -7, :day)
      defp cutoff_for_time_window("last_30d"), do: DateTime.add(DateTime.utc_now(), -30, :day)
      defp cutoff_for_time_window(_), do: cutoff_for_time_window("last_24h")

      defp netflow_map_cutoff(_time_window), do: DateTime.add(DateTime.utc_now(), -15, :minute)

      defp netflow_map_window_label, do: "Last #{15} min"

      defp sparkline_bucket_for("last_1h"), do: "1 minute"
      defp sparkline_bucket_for("last_6h"), do: "5 minutes"
      defp sparkline_bucket_for("last_24h"), do: "15 minutes"
      defp sparkline_bucket_for("last_7d"), do: "1 hour"
      defp sparkline_bucket_for("last_30d"), do: "6 hours"
      defp sparkline_bucket_for(_), do: sparkline_bucket_for("last_24h")

      defp bucket_seconds_for("last_1h"), do: 60
      defp bucket_seconds_for("last_6h"), do: 300
      defp bucket_seconds_for("last_24h"), do: 900
      defp bucket_seconds_for("last_7d"), do: 3600
      defp bucket_seconds_for("last_30d"), do: 21_600
      defp bucket_seconds_for(_), do: bucket_seconds_for("last_24h")

      defp sparkline_bucket_for_from_seconds(60), do: "1 minute"
      defp sparkline_bucket_for_from_seconds(300), do: "5 minutes"
      defp sparkline_bucket_for_from_seconds(900), do: "15 minutes"
      defp sparkline_bucket_for_from_seconds(3600), do: "1 hour"
      defp sparkline_bucket_for_from_seconds(21_600), do: "6 hours"
      defp sparkline_bucket_for_from_seconds(_), do: sparkline_bucket_for("last_24h")

      defp bucket_interval_literal("1 minute"), do: "'1 minute'::interval"
      defp bucket_interval_literal("5 minutes"), do: "'5 minutes'::interval"
      defp bucket_interval_literal("15 minutes"), do: "'15 minutes'::interval"
      defp bucket_interval_literal("1 hour"), do: "'1 hour'::interval"
      defp bucket_interval_literal("6 hours"), do: "'6 hours'::interval"
      defp bucket_interval_literal(_), do: bucket_interval_literal(sparkline_bucket_for("last_24h"))

      defp time_window_label("last_1h"), do: "Last hour"
      defp time_window_label("last_6h"), do: "Last 6 hours"
      defp time_window_label("last_24h"), do: "Last 24 hours"
      defp time_window_label("last_7d"), do: "Last 7 days"
      defp time_window_label("last_30d"), do: "Last 30 days"
      defp time_window_label(_), do: time_window_label("last_24h")
    end
  end
end
