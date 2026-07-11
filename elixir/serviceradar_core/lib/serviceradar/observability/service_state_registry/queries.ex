defmodule ServiceRadar.Observability.ServiceStateRegistry.Queries do
  @moduledoc false

  @doc false
  def latest_plugin_status do
    """
    SELECT DISTINCT ON (agent_id, COALESCE(partition, 'default'), service_type, service_name)
      agent_id,
      gateway_id,
      COALESCE(partition, 'default') AS partition,
      service_type,
      service_name,
      available,
      message,
      details,
      timestamp
    FROM platform.service_status
    WHERE service_type = 'plugin'
      AND timestamp >= (now() - ($1::text)::interval)
    ORDER BY agent_id, COALESCE(partition, 'default'), service_type, service_name, timestamp DESC
    LIMIT $2
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
      AND (
        service_state.service_name = $1
        OR (
          service_state.details IS JSON
          AND (
            service_state.details::jsonb #>> '{labels,plugin_id}' = $2
            OR service_state.details::jsonb ->> 'plugin_id' = $2
            OR service_state.details::jsonb #>> '{reported_result,labels,plugin_id}' = $2
            OR service_state.details::jsonb #>> '{reported_result,plugin_id}' = $2
          )
        )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM platform.plugin_assignments AS assignment
        JOIN platform.plugin_packages AS package
          ON package.id = assignment.plugin_package_id
        WHERE assignment.enabled = true
          AND assignment.agent_uid = service_state.agent_id
          AND (
            package.name = service_state.service_name
            OR (
              service_state.details IS JSON
              AND (
                service_state.details::jsonb #>> '{labels,plugin_id}' = package.plugin_id
                OR service_state.details::jsonb ->> 'plugin_id' = package.plugin_id
                OR service_state.details::jsonb #>> '{reported_result,labels,plugin_id}' = package.plugin_id
                OR service_state.details::jsonb #>> '{reported_result,plugin_id}' = package.plugin_id
              )
            )
          )
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
  def deactivate_stale_active_plugin_shadows do
    """
    WITH ranked AS (
      SELECT
        id,
        row_number() OVER (
          PARTITION BY agent_id, partition, service_type, service_name
          ORDER BY last_observed_at DESC, updated_at DESC, inserted_at DESC, id DESC
        ) AS row_number
      FROM platform.service_state
      WHERE service_type = 'plugin' AND state = 'active'
    ),
    deactivated AS (
      UPDATE platform.service_state AS service_state
      SET state = 'inactive',
          updated_at = (now() AT TIME ZONE 'utc')
      FROM ranked
      WHERE service_state.id = ranked.id
        AND ranked.row_number > 1
      RETURNING service_state.id
    )
    SELECT count(*)::bigint FROM deactivated
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
        AND NOT EXISTS (
          SELECT 1
          FROM platform.plugin_assignments AS assignment
          JOIN platform.plugin_packages AS package
            ON package.id = assignment.plugin_package_id
          WHERE assignment.enabled = true
            AND assignment.agent_uid = service_state.agent_id
            AND (
              package.name = service_state.service_name
              OR (
                service_state.details IS JSON
                AND (
                  service_state.details::jsonb #>> '{labels,plugin_id}' = package.plugin_id
                  OR service_state.details::jsonb ->> 'plugin_id' = package.plugin_id
                  OR service_state.details::jsonb #>> '{reported_result,labels,plugin_id}' = package.plugin_id
                  OR service_state.details::jsonb #>> '{reported_result,plugin_id}' = package.plugin_id
                )
              )
            )
            AND (
              package.outputs IN ($1, $2)
              OR $3 = ANY(package.approved_capabilities)
              OR (
                coalesce(array_length(package.approved_capabilities, 1), 0) = 0
                AND package.manifest->'capabilities' ? $3
              )
            )
        )
      RETURNING service_state.id
    )
    SELECT count(*)::bigint FROM deactivated
    """
  end
end
