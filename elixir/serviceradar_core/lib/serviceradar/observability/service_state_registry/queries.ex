defmodule ServiceRadar.Observability.ServiceStateRegistry.Queries do
  @moduledoc false

  alias ServiceRadar.Observability.PluginResultSlot
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginStateContract

  @doc false
  def plugin_state_winner_for_identity do
    """
    SELECT
      gateway_id,
      available,
      message,
      details,
      last_observed_at
    FROM platform.service_state AS service_state
    WHERE service_state.agent_id = $1
      AND service_state.partition = $2
      AND service_state.service_type = $3
      AND service_state.service_name = $4
    ORDER BY #{PluginStateContract.state_winner_order_sql()}
    LIMIT 1
    """
  end

  @doc false
  def plugin_status_winner_for_observation do
    """
    WITH normalized AS (
      SELECT
        service_status.*,
        #{PluginStateContract.history_normalized_fields_sql()}
      FROM platform.service_status AS service_status
      WHERE service_status.agent_id = $1
        AND service_status.gateway_id = $2
        AND COALESCE(service_status.partition, 'default') = $3
        AND service_status.service_type = $4
        AND service_status.service_name = $5
        AND service_status.timestamp >= $6::timestamptz -
          INTERVAL '#{PluginResultSlot.allocation_window_microseconds()} microseconds'
        AND service_status.timestamp <= $6::timestamptz +
          INTERVAL '#{PluginResultSlot.block_width_microseconds() - 1} microseconds'
    ),
    payload_winners AS (
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
      timestamp,
      payload_digest
    FROM payload_winners AS payload_winner
    WHERE payload_rank = 1
      AND logical_observed_at = $6::timestamptz
    ORDER BY #{PluginStateContract.history_logical_winner_order_sql()}
    LIMIT 1
    """
  end

  @doc false
  def reported_payload_count_for_observation do
    """
    SELECT count(DISTINCT service_status.details::jsonb #>>
      '{_serviceradar_plugin_result,payload_digest}')::bigint
    FROM platform.service_status AS service_status
    WHERE service_status.agent_id = $1
      AND service_status.gateway_id = $2
      AND COALESCE(service_status.partition, 'default') = $3
      AND service_status.service_type = $4
      AND service_status.service_name = $5
      AND service_status.timestamp >= ($6::text)::timestamptz -
        INTERVAL '#{PluginResultSlot.allocation_window_microseconds()} microseconds'
      AND service_status.timestamp <= ($6::text)::timestamptz +
        INTERVAL '#{PluginResultSlot.block_width_microseconds() - 1} microseconds'
      AND #{PluginStateContract.trusted_reported_marker_sql()}
      AND service_status.details::jsonb #>>
        '{_serviceradar_plugin_result,observation_timestamp}' = $6::text
    """
  end

  @doc false
  def package_state_identities_for_agent do
    """
    SELECT DISTINCT
      service_state.agent_id,
      service_state.partition,
      service_state.service_type,
      service_state.service_name
    FROM platform.service_state AS service_state
    WHERE service_state.agent_id = $1
      AND service_state.service_type = 'plugin'
      AND service_state.state = 'active'
      AND #{PluginStateContract.state_matches_package_sql(:agent_package_params)}
      AND NOT #{eligible_plugin_assignment_sql("$5", "$6", "$7", "$4")}
    ORDER BY
      service_state.agent_id,
      service_state.partition,
      service_state.service_type,
      service_state.service_name
    """
  end

  @doc false
  def orphaned_package_state_identities do
    """
    SELECT DISTINCT
      service_state.agent_id,
      service_state.partition,
      service_state.service_type,
      service_state.service_name
    FROM platform.service_state AS service_state
    WHERE service_state.service_type = 'plugin'
      AND service_state.state = 'active'
      AND #{PluginStateContract.state_matches_package_sql(:package_params)}
      AND NOT EXISTS (
        SELECT 1
        FROM platform.plugin_assignments AS assignment
        JOIN platform.plugin_packages AS package
          ON package.id = assignment.plugin_package_id
        WHERE assignment.enabled = true
          AND package.status = 'approved'
          AND assignment.agent_uid = service_state.agent_id
          AND #{PluginStateContract.state_matches_joined_package_sql()}
          AND (
            package.outputs IN ($3, $4)
            OR $5 = ANY(package.approved_capabilities)
            OR (
              coalesce(array_length(package.approved_capabilities, 1), 0) = 0
              AND package.manifest->'capabilities' ? $5
            )
          )
      )
    ORDER BY
      service_state.agent_id,
      service_state.partition,
      service_state.service_type,
      service_state.service_name
    """
  end

  @doc false
  def reconcile_plugin_state_winners do
    """
    WITH ranked AS (
      SELECT
        id,
        row_number() OVER (
          PARTITION BY agent_id, partition, service_type, service_name
          ORDER BY #{PluginStateContract.state_winner_order_sql()}
        ) AS row_number
      FROM platform.service_state AS service_state
      WHERE service_state.service_type = 'plugin'
        AND #{eligible_plugin_assignment_sql("$1", "$2", "$3")}
    ),
    reconciled AS (
      UPDATE platform.service_state AS service_state
      SET state = CASE WHEN ranked.row_number = 1 THEN 'active' ELSE 'inactive' END,
          updated_at = (now() AT TIME ZONE 'utc')
      FROM ranked
      WHERE service_state.id = ranked.id
        AND service_state.state IS DISTINCT FROM
          CASE WHEN ranked.row_number = 1 THEN 'active' ELSE 'inactive' END
      RETURNING service_state.id
    )
    SELECT count(*)::bigint FROM reconciled
    """
  end

  @doc false
  def lock_plugin_state_reconciliation do
    """
    SELECT pg_advisory_xact_lock(
      hashtextextended('plugin-service-state-reconcile', 0)
    )
    """
  end

  @doc false
  def deactivate_orphaned_active_plugin_states do
    """
    WITH deactivated AS (
      UPDATE platform.service_state AS service_state
      SET state = 'inactive',
          updated_at = (now() AT TIME ZONE 'utc')
      WHERE service_state.service_type = 'plugin'
        AND service_state.state = 'active'
        AND NOT #{eligible_plugin_assignment_sql("$1", "$2", "$3")}
      RETURNING service_state.id
    )
    SELECT count(*)::bigint FROM deactivated
    """
  end

  defp eligible_plugin_assignment_sql(
         plugin_result_output,
         streaming_output,
         streaming_capability,
         excluded_assignment \\ nil
       ) do
    assignment_exclusion =
      if excluded_assignment do
        "AND assignment.id <> (#{excluded_assignment}::text)::uuid"
      else
        ""
      end

    """
    EXISTS (
      SELECT 1
      FROM platform.plugin_assignments AS assignment
      JOIN platform.plugin_packages AS package
        ON package.id = assignment.plugin_package_id
      WHERE assignment.enabled = true
        AND package.status = 'approved'
        AND assignment.agent_uid = service_state.agent_id
        #{assignment_exclusion}
        AND #{PluginStateContract.state_matches_joined_package_sql()}
        AND (
          package.outputs IN (#{plugin_result_output}, #{streaming_output})
          OR #{streaming_capability} = ANY(package.approved_capabilities)
          OR (
            coalesce(array_length(package.approved_capabilities, 1), 0) = 0
            AND package.manifest->'capabilities' ? #{streaming_capability}
          )
        )
    )
    """
  end
end
