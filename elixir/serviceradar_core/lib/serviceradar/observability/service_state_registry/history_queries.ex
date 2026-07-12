defmodule ServiceRadar.Observability.ServiceStateRegistry.HistoryQueries do
  @moduledoc false

  alias ServiceRadar.Observability.PluginResultSlot
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginStateContract

  @doc false
  def latest_plugin_status do
    """
    SELECT
      service_status.agent_id,
      COALESCE(service_status.partition, 'default') AS partition,
      service_status.service_type,
      service_status.service_name
    FROM platform.service_status AS service_status
    WHERE service_status.service_type = 'plugin'
      AND service_status.agent_id IS NOT NULL
      AND service_status.timestamp >= (now() - ($1::text)::interval) -
        INTERVAL '#{PluginResultSlot.allocation_window_microseconds()} microseconds'
      AND (
        service_status.agent_id,
        COALESCE(service_status.partition, 'default'),
        service_status.service_type,
        service_status.service_name
      ) > ($3::text, $4::text, $5::text, $6::text)
      AND #{eligible_assignment_sql(7, 8, 9)}
    GROUP BY
      service_status.agent_id,
      COALESCE(service_status.partition, 'default'),
      service_status.service_type,
      service_status.service_name
    ORDER BY
      service_status.agent_id,
      COALESCE(service_status.partition, 'default'),
      service_status.service_type,
      service_status.service_name
    LIMIT $2
    """
  end

  @doc false
  def latest_plugin_status_for_identity do
    """
    WITH normalized AS (
      SELECT
        service_status.*,
        #{PluginStateContract.history_normalized_fields_sql()}
      FROM platform.service_status AS service_status
      WHERE service_status.service_type = 'plugin'
        AND service_status.timestamp >= (now() - ($1::text)::interval) -
          INTERVAL '#{PluginResultSlot.allocation_window_microseconds()} microseconds'
        AND service_status.agent_id = $2
        AND COALESCE(service_status.partition, 'default') = $3
        AND service_status.service_type = $4
        AND service_status.service_name = $5
        AND #{eligible_assignment_sql(6, 7, 8)}
    )
    #{winner_query_sql()}
    """
  end

  defp winner_query_sql do
    """
    , payload_winners AS (
      SELECT
        normalized.*,
        row_number() OVER (
          PARTITION BY
            normalized.agent_id,
            normalized.gateway_id,
            COALESCE(normalized.partition, 'default'),
            normalized.service_type,
            normalized.service_name,
            normalized.logical_observed_at,
            normalized.payload_lineage
          ORDER BY #{PluginStateContract.history_payload_winner_order_sql()}
        ) AS payload_rank
      FROM normalized
    ),
    logical_winners AS (
      SELECT
        payload_winner.*,
        row_number() OVER (
          PARTITION BY
            payload_winner.agent_id,
            COALESCE(payload_winner.partition, 'default'),
            payload_winner.service_type,
            payload_winner.service_name
          ORDER BY #{PluginStateContract.history_logical_winner_order_sql()}
        ) AS logical_rank
      FROM payload_winners AS payload_winner
      WHERE payload_winner.payload_rank = 1
    )
    SELECT
      agent_id,
      gateway_id,
      COALESCE(partition, 'default') AS partition,
      service_type,
      service_name,
      available,
      message,
      details,
      timestamp
    FROM logical_winners
    WHERE logical_rank = 1
    ORDER BY
      agent_id,
      COALESCE(partition, 'default'),
      service_type,
      service_name
    """
  end

  defp eligible_assignment_sql(plugin_result_param, streaming_param, capability_param) do
    """
    EXISTS (
      SELECT 1
      FROM platform.plugin_assignments AS assignment
      JOIN platform.plugin_packages AS package
        ON package.id = assignment.plugin_package_id
      WHERE assignment.enabled = true
        AND package.status = 'approved'
        AND assignment.agent_uid = service_status.agent_id
        AND #{PluginStateContract.status_matches_joined_package_sql()}
        AND (
          package.outputs IN ($#{plugin_result_param}, $#{streaming_param})
          OR $#{capability_param} = ANY(package.approved_capabilities)
          OR (
            coalesce(array_length(package.approved_capabilities, 1), 0) = 0
            AND package.manifest->'capabilities' ? $#{capability_param}
          )
        )
    )
    """
  end
end
