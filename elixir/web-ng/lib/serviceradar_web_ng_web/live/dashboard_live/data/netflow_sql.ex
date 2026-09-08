defmodule ServiceRadarWebNGWeb.DashboardLive.Data.NetflowSql do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      @doc false
      @spec netflow_map_time_predicate(String.t()) :: String.t()
      def netflow_map_time_predicate("bucket"), do: "f.bucket >= date_trunc('hour', $1::timestamptz)"
      def netflow_map_time_predicate(time_column), do: "f.#{time_column} >= $1"

      defp threat_select_expr(true) do
        """
          COALESCE(BOOL_OR(src_threat.ip IS NOT NULL), false) AS src_threat_matched,
          COALESCE(MAX(src_threat.match_count), 0)::integer AS src_threat_match_count,
          COALESCE(MAX(src_threat.max_severity), 0)::integer AS src_threat_max_severity,
          COALESCE(MAX(array_to_string(src_threat.sources, ',')), '') AS src_threat_sources,
          COALESCE(BOOL_OR(dst_threat.ip IS NOT NULL), false) AS dst_threat_matched,
          COALESCE(MAX(dst_threat.match_count), 0)::integer AS dst_threat_match_count,
          COALESCE(MAX(dst_threat.max_severity), 0)::integer AS dst_threat_max_severity,
          COALESCE(MAX(array_to_string(dst_threat.sources, ',')), '') AS dst_threat_sources
        """
      end

      defp threat_select_expr(false) do
        """
          false AS src_threat_matched,
          0 AS src_threat_match_count,
          0 AS src_threat_max_severity,
          '' AS src_threat_sources,
          false AS dst_threat_matched,
          0 AS dst_threat_match_count,
          0 AS dst_threat_max_severity,
          '' AS dst_threat_sources
        """
      end

      defp attribution_select_expr("ocsf_network_activity") do
        attributed? = "f.ocsf_payload ->> 'event_type' = 'attributed_flow'"
        latest = &latest_attribution_expr(&1, attributed?)

        """
          COALESCE(COUNT(*) FILTER (WHERE #{attributed?}), 0)::bigint AS attributed_flow_count,
          #{latest.("f.ocsf_payload ->> 'agent_id'")} AS attribution_agent_id,
          #{latest.("f.ocsf_payload #>> '{attribution,comm}'")} AS attribution_comm,
          NULLIF(#{latest.("f.ocsf_payload #>> '{attribution,pid}'")}, '')::integer AS attribution_pid,
          #{latest.("f.ocsf_payload #>> '{attribution,container_id}'")} AS attribution_container_id,
          #{latest.("f.ocsf_payload #>> '{attribution,workload_identity,pod_namespace}'")} AS attribution_pod_namespace,
          #{latest.("f.ocsf_payload #>> '{attribution,workload_identity,pod_name}'")} AS attribution_pod_name,
          #{latest.("f.ocsf_payload #>> '{attribution,workload_identity,container_name}'")} AS attribution_container_name,
          COALESCE(
            #{latest.("f.ocsf_payload #>> '{attribution,workload_identity,image}'")},
            #{latest.("f.ocsf_payload #>> '{attribution,workload_identity,image_ref}'")}
          ) AS attribution_image
        """
      end

      defp attribution_select_expr(_relation) do
        """
          0::bigint AS attributed_flow_count,
          NULL::text AS attribution_agent_id,
          NULL::text AS attribution_comm,
          NULL::integer AS attribution_pid,
          NULL::text AS attribution_container_id,
          NULL::text AS attribution_pod_namespace,
          NULL::text AS attribution_pod_name,
          NULL::text AS attribution_container_name,
          NULL::text AS attribution_image
        """
      end

      defp latest_attribution_expr(expr, attributed_predicate) do
        """
        (array_remove(array_agg(NULLIF(#{expr}, '') ORDER BY f.time DESC)
          FILTER (WHERE #{attributed_predicate}), NULL))[1]
        """
      end

      defp threat_sources(src_sources, dst_sources) do
        [src_sources, dst_sources]
        |> Enum.flat_map(fn value ->
          value
          |> to_string()
          |> String.split(",", trim: true)
        end)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.take(6)
      end
    end
  end
end
