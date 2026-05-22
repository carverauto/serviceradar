defmodule ServiceRadar.Monitoring.ServiceMonitoringBackfill do
  @moduledoc """
  Backfills legacy service check and service state identities into service monitoring tables.
  """

  @type repo :: module()

  @spec run!(repo()) :: :ok
  def run!(repo \\ ServiceRadar.Repo) when is_atom(repo) do
    Enum.each(statements(), &repo.query!(&1, []))
    :ok
  end

  defp statements do
    [
      legacy_service_check_services_sql(),
      legacy_service_check_instances_sql(),
      legacy_service_check_states_sql(),
      legacy_service_identity_services_sql("service_state"),
      legacy_service_identity_instances_sql("service_state"),
      legacy_service_identity_states_sql("service_state"),
      legacy_service_identity_services_sql("service_status"),
      legacy_service_identity_instances_sql("service_status"),
      legacy_service_identity_states_sql("service_status")
    ]
  end

  defp legacy_service_check_services_sql do
    """
    WITH legacy AS (
      SELECT
        sc.id,
        'legacy:service-check-target:' ||
          md5(concat_ws('|', lower(sc.check_type::text), COALESCE(sc.device_uid, ''), sc.target, COALESCE(sc.port::text, ''))) AS service_key,
        CASE lower(sc.check_type::text)
          WHEN 'http' THEN 'http'
          WHEN 'tcp' THEN 'tcp'
          WHEN 'grpc' THEN 'grpc'
          WHEN 'dns' THEN 'dns'
          ELSE 'custom'
        END AS service_kind,
        lower(sc.check_type::text) AS protocol,
        sc.name,
        sc.description,
        sc.target,
        sc.port,
        sc.device_uid,
        sc.config,
        sc.metadata
      FROM platform.service_checks AS sc
      WHERE COALESCE(sc.target, '') <> ''
    )
    INSERT INTO platform.monitored_services (
      service_key,
      display_name,
      description,
      service_kind,
      protocol,
      endpoint_url,
      host,
      port,
      device_uid,
      status,
      source,
      tags,
      metadata,
      inserted_at,
      updated_at
    )
    SELECT
      service_key,
      COALESCE(NULLIF(name, ''), target),
      description,
      service_kind,
      protocol,
      CASE WHEN protocol = 'http' THEN target ELSE NULL END,
      CASE WHEN protocol = 'http' AND target ~* '^https?://' THEN NULL ELSE target END,
      port,
      device_uid,
      'active',
      'backfill',
      jsonb_strip_nulls(jsonb_build_object(
        'legacy_source', 'service_checks',
        'check_type', protocol
      )),
      jsonb_strip_nulls(jsonb_build_object(
        'backfill_source', 'service_checks',
        'legacy_target', target,
        'legacy_check_type', protocol,
        'legacy_config', COALESCE(config, '{}'::jsonb),
        'legacy_metadata', COALESCE(metadata, '{}'::jsonb)
      )),
      now() AT TIME ZONE 'utc',
      now() AT TIME ZONE 'utc'
    FROM legacy
    ON CONFLICT (service_key) DO UPDATE SET
      display_name = EXCLUDED.display_name,
      description = COALESCE(EXCLUDED.description, platform.monitored_services.description),
      service_kind = EXCLUDED.service_kind,
      protocol = EXCLUDED.protocol,
      endpoint_url = EXCLUDED.endpoint_url,
      host = EXCLUDED.host,
      port = EXCLUDED.port,
      device_uid = COALESCE(EXCLUDED.device_uid, platform.monitored_services.device_uid),
      tags = platform.monitored_services.tags || EXCLUDED.tags,
      metadata = platform.monitored_services.metadata || EXCLUDED.metadata,
      updated_at = now() AT TIME ZONE 'utc'
    """
  end

  defp legacy_service_check_instances_sql do
    """
    WITH legacy AS (
      SELECT
        sc.*,
        'legacy:service-check-target:' ||
          md5(concat_ws('|', lower(sc.check_type::text), COALESCE(sc.device_uid, ''), sc.target, COALESCE(sc.port::text, ''))) AS service_key,
        'legacy:service-check:' || sc.id::text AS check_key,
        CASE lower(sc.check_type::text)
          WHEN 'http' THEN 'builtin.http.availability'
          WHEN 'tcp' THEN 'builtin.tcp.connect'
          WHEN 'grpc' THEN 'builtin.grpc.health'
          WHEN 'dns' THEN 'builtin.dns.resolve'
          WHEN 'ping' THEN 'builtin.icmp.availability'
          ELSE 'legacy.service_check.availability'
        END AS descriptor_id
      FROM platform.service_checks AS sc
      WHERE COALESCE(sc.target, '') <> ''
    )
    INSERT INTO platform.check_instances (
      check_key,
      monitored_service_id,
      device_uid,
      descriptor_id,
      descriptor_version,
      capability_kind,
      vantage_kind,
      vantage_id,
      agent_id,
      target_snapshot,
      credential_policy_snapshot,
      event_policy_snapshot,
      status,
      last_materialized_at,
      metadata,
      inserted_at,
      updated_at
    )
    SELECT
      legacy.check_key,
      service.id,
      legacy.device_uid,
      legacy.descriptor_id,
      '1.0.0',
      'builtin',
      'agent',
      legacy.agent_uid,
      legacy.agent_uid,
      jsonb_strip_nulls(jsonb_build_object(
        'legacy_service_check_id', legacy.id,
        'name', legacy.name,
        'check_type', lower(legacy.check_type::text),
        'target', legacy.target,
        'port', legacy.port,
        'device_uid', legacy.device_uid,
        'agent_uid', legacy.agent_uid,
        'interval_seconds', legacy.interval_seconds,
        'timeout_seconds', legacy.timeout_seconds,
        'retries', legacy.retries,
        'config', COALESCE(legacy.config, '{}'::jsonb)
      )),
      '{}'::jsonb,
      jsonb_strip_nulls(jsonb_build_object(
        'legacy_warning_threshold_ms', legacy.warning_threshold_ms,
        'legacy_critical_threshold_ms', legacy.critical_threshold_ms
      )),
      CASE WHEN COALESCE(legacy.enabled, true) THEN 'active' ELSE 'disabled' END,
      now() AT TIME ZONE 'utc',
      jsonb_strip_nulls(jsonb_build_object(
        'backfill_source', 'service_checks',
        'legacy_service_check_id', legacy.id,
        'legacy_metadata', COALESCE(legacy.metadata, '{}'::jsonb)
      )),
      now() AT TIME ZONE 'utc',
      now() AT TIME ZONE 'utc'
    FROM legacy
    JOIN platform.monitored_services AS service ON service.service_key = legacy.service_key
    ON CONFLICT (check_key) DO UPDATE SET
      monitored_service_id = EXCLUDED.monitored_service_id,
      device_uid = EXCLUDED.device_uid,
      descriptor_id = EXCLUDED.descriptor_id,
      descriptor_version = EXCLUDED.descriptor_version,
      capability_kind = EXCLUDED.capability_kind,
      vantage_kind = EXCLUDED.vantage_kind,
      vantage_id = EXCLUDED.vantage_id,
      agent_id = EXCLUDED.agent_id,
      target_snapshot = EXCLUDED.target_snapshot,
      credential_policy_snapshot = EXCLUDED.credential_policy_snapshot,
      event_policy_snapshot = EXCLUDED.event_policy_snapshot,
      status = EXCLUDED.status,
      last_materialized_at = EXCLUDED.last_materialized_at,
      metadata = platform.check_instances.metadata || EXCLUDED.metadata,
      updated_at = now() AT TIME ZONE 'utc'
    """
  end

  defp legacy_service_check_states_sql do
    """
    WITH legacy AS (
      SELECT
        sc.*,
        'legacy:service-check:' || sc.id::text AS check_key,
        CASE lower(COALESCE(sc.last_result::text, 'unknown'))
          WHEN 'success' THEN 'ok'
          WHEN 'warning' THEN 'warning'
          WHEN 'critical' THEN 'critical'
          WHEN 'error' THEN 'critical'
          ELSE 'unknown'
        END AS normalized_status,
        COALESCE(sc.last_check_at::timestamptz, sc.updated_at, sc.created_at, now()) AS observed_at
      FROM platform.service_checks AS sc
      WHERE COALESCE(sc.target, '') <> ''
        AND (sc.last_check_at IS NOT NULL OR sc.last_result IS NOT NULL OR sc.last_error IS NOT NULL)
    )
    INSERT INTO platform.latest_check_states (
      check_instance_id,
      monitored_service_id,
      device_uid,
      agent_id,
      vantage_kind,
      vantage_id,
      status,
      status_changed_at,
      last_observed_at,
      response_time_ms,
      summary,
      details,
      metrics,
      consecutive_failures,
      inserted_at,
      updated_at
    )
    SELECT
      check_instance.id,
      check_instance.monitored_service_id,
      legacy.device_uid,
      legacy.agent_uid,
      'agent',
      legacy.agent_uid,
      legacy.normalized_status,
      legacy.observed_at,
      legacy.observed_at,
      legacy.last_response_time_ms,
      legacy.last_error,
      jsonb_strip_nulls(jsonb_build_object(
        'backfill_source', 'service_checks',
        'legacy_service_check_id', legacy.id,
        'legacy_result', legacy.last_result,
        'legacy_error', legacy.last_error
      )),
      '{}'::jsonb,
      COALESCE(legacy.consecutive_failures, 0),
      now() AT TIME ZONE 'utc',
      now() AT TIME ZONE 'utc'
    FROM legacy
    JOIN platform.check_instances AS check_instance ON check_instance.check_key = legacy.check_key
    ON CONFLICT (check_instance_id) DO UPDATE SET
      monitored_service_id = EXCLUDED.monitored_service_id,
      device_uid = EXCLUDED.device_uid,
      agent_id = EXCLUDED.agent_id,
      vantage_kind = EXCLUDED.vantage_kind,
      vantage_id = EXCLUDED.vantage_id,
      status = EXCLUDED.status,
      status_changed_at = EXCLUDED.status_changed_at,
      last_observed_at = EXCLUDED.last_observed_at,
      response_time_ms = EXCLUDED.response_time_ms,
      summary = EXCLUDED.summary,
      details = EXCLUDED.details,
      metrics = EXCLUDED.metrics,
      consecutive_failures = EXCLUDED.consecutive_failures,
      updated_at = now() AT TIME ZONE 'utc'
    """
  end

  defp legacy_service_identity_services_sql(source) do
    """
    WITH latest AS (
      #{legacy_service_identity_source_sql(source)}
    )
    INSERT INTO platform.monitored_services (
      service_key,
      display_name,
      description,
      service_kind,
      protocol,
      status,
      source,
      tags,
      metadata,
      inserted_at,
      updated_at
    )
    SELECT
      identity_key,
      service_name,
      message,
      'custom',
      service_type,
      CASE WHEN state = 'inactive' THEN 'retired' ELSE 'active' END,
      'backfill',
      jsonb_strip_nulls(jsonb_build_object(
        'legacy_source', source_table,
        'service_type', service_type
      )),
      jsonb_strip_nulls(jsonb_build_object(
        'backfill_source', source_table,
        'agent_id', agent_id,
        'gateway_id', gateway_id,
        'partition', partition,
        'service_type', service_type,
        'service_name', service_name
      )),
      now() AT TIME ZONE 'utc',
      now() AT TIME ZONE 'utc'
    FROM latest
    ON CONFLICT (service_key) DO UPDATE SET
      display_name = EXCLUDED.display_name,
      description = COALESCE(EXCLUDED.description, platform.monitored_services.description),
      protocol = EXCLUDED.protocol,
      status = CASE
        WHEN platform.monitored_services.status = 'retired' THEN platform.monitored_services.status
        ELSE EXCLUDED.status
      END,
      tags = platform.monitored_services.tags || EXCLUDED.tags,
      metadata = platform.monitored_services.metadata || EXCLUDED.metadata,
      updated_at = now() AT TIME ZONE 'utc'
    """
  end

  defp legacy_service_identity_instances_sql(source) do
    """
    WITH latest AS (
      #{legacy_service_identity_source_sql(source)}
    )
    INSERT INTO platform.check_instances (
      check_key,
      monitored_service_id,
      descriptor_id,
      descriptor_version,
      capability_kind,
      vantage_kind,
      vantage_id,
      agent_id,
      target_snapshot,
      credential_policy_snapshot,
      event_policy_snapshot,
      status,
      last_materialized_at,
      metadata,
      inserted_at,
      updated_at
    )
    SELECT
      check_key,
      service.id,
      CASE WHEN latest.service_type = 'plugin' THEN 'plugin.service_state.availability' ELSE 'legacy.service_state.availability' END,
      '1.0.0',
      CASE WHEN latest.service_type = 'plugin' THEN 'plugin' ELSE 'builtin' END,
      'agent',
      latest.agent_id,
      agent.uid,
      jsonb_strip_nulls(jsonb_build_object(
        'agent_id', latest.agent_id,
        'gateway_id', latest.gateway_id,
        'partition', latest.partition,
        'service_type', latest.service_type,
        'service_name', latest.service_name,
        'source_table', latest.source_table
      )),
      '{}'::jsonb,
      '{}'::jsonb,
      CASE WHEN latest.state = 'inactive' THEN 'retired' ELSE 'active' END,
      now() AT TIME ZONE 'utc',
      jsonb_strip_nulls(jsonb_build_object(
        'backfill_source', latest.source_table,
        'agent_id', latest.agent_id,
        'gateway_id', latest.gateway_id,
        'partition', latest.partition,
        'service_type', latest.service_type,
        'service_name', latest.service_name
      )),
      now() AT TIME ZONE 'utc',
      now() AT TIME ZONE 'utc'
    FROM latest
    JOIN platform.monitored_services AS service ON service.service_key = latest.identity_key
    LEFT JOIN platform.ocsf_agents AS agent ON agent.uid = latest.agent_id
    ON CONFLICT (check_key) DO UPDATE SET
      monitored_service_id = EXCLUDED.monitored_service_id,
      descriptor_id = EXCLUDED.descriptor_id,
      descriptor_version = EXCLUDED.descriptor_version,
      capability_kind = EXCLUDED.capability_kind,
      vantage_kind = EXCLUDED.vantage_kind,
      vantage_id = EXCLUDED.vantage_id,
      agent_id = EXCLUDED.agent_id,
      target_snapshot = EXCLUDED.target_snapshot,
      credential_policy_snapshot = EXCLUDED.credential_policy_snapshot,
      event_policy_snapshot = EXCLUDED.event_policy_snapshot,
      status = EXCLUDED.status,
      last_materialized_at = EXCLUDED.last_materialized_at,
      metadata = platform.check_instances.metadata || EXCLUDED.metadata,
      updated_at = now() AT TIME ZONE 'utc'
    """
  end

  defp legacy_service_identity_states_sql(source) do
    """
    WITH latest AS (
      #{legacy_service_identity_source_sql(source)}
    )
    INSERT INTO platform.latest_check_states (
      check_instance_id,
      monitored_service_id,
      agent_id,
      vantage_kind,
      vantage_id,
      status,
      status_changed_at,
      last_observed_at,
      summary,
      details,
      metrics,
      consecutive_failures,
      inserted_at,
      updated_at
    )
    SELECT
      check_instance.id,
      check_instance.monitored_service_id,
      agent.uid,
      'agent',
      latest.agent_id,
      CASE WHEN latest.available THEN 'ok' ELSE 'critical' END,
      latest.last_observed_at,
      latest.last_observed_at,
      latest.message,
      latest.details,
      '{}'::jsonb,
      CASE WHEN latest.available THEN 0 ELSE 1 END,
      now() AT TIME ZONE 'utc',
      now() AT TIME ZONE 'utc'
    FROM latest
    JOIN platform.check_instances AS check_instance ON check_instance.check_key = latest.check_key
    LEFT JOIN platform.ocsf_agents AS agent ON agent.uid = latest.agent_id
    ON CONFLICT (check_instance_id) DO UPDATE SET
      monitored_service_id = EXCLUDED.monitored_service_id,
      agent_id = EXCLUDED.agent_id,
      vantage_kind = EXCLUDED.vantage_kind,
      vantage_id = EXCLUDED.vantage_id,
      status = EXCLUDED.status,
      status_changed_at = EXCLUDED.status_changed_at,
      last_observed_at = EXCLUDED.last_observed_at,
      summary = EXCLUDED.summary,
      details = EXCLUDED.details,
      metrics = EXCLUDED.metrics,
      consecutive_failures = EXCLUDED.consecutive_failures,
      updated_at = now() AT TIME ZONE 'utc'
    """
  end

  defp legacy_service_identity_source_sql("service_state") do
    """
    SELECT
      'service_state' AS source_table,
      agent_id,
      gateway_id,
      COALESCE(partition, 'default') AS partition,
      service_type,
      service_name,
      available,
      state,
      message,
      CASE
        WHEN details IS JSON THEN details::jsonb
        WHEN details IS NULL OR details = '' THEN '{}'::jsonb
        ELSE jsonb_build_object('raw_details', details)
      END AS details,
      last_observed_at,
      'legacy:service-identity:' ||
        md5(concat_ws('|', agent_id, gateway_id, COALESCE(partition, 'default'), service_type, service_name)) AS identity_key,
      'legacy:service-identity:' ||
        md5(concat_ws('|', agent_id, gateway_id, COALESCE(partition, 'default'), service_type, service_name)) AS check_key
    FROM platform.service_state
    WHERE COALESCE(agent_id, '') <> ''
      AND COALESCE(gateway_id, '') <> ''
      AND COALESCE(service_type, '') <> ''
      AND COALESCE(service_name, '') <> ''
    """
  end

  defp legacy_service_identity_source_sql("service_status") do
    """
    SELECT DISTINCT ON (status.agent_id, status.gateway_id, COALESCE(status.partition, 'default'), status.service_type, status.service_name)
      'service_status' AS source_table,
      status.agent_id,
      status.gateway_id,
      COALESCE(status.partition, 'default') AS partition,
      status.service_type,
      status.service_name,
      status.available,
      'active' AS state,
      status.message,
      CASE
        WHEN status.details IS JSON THEN status.details::jsonb
        WHEN status.details IS NULL OR status.details = '' THEN '{}'::jsonb
        ELSE jsonb_build_object('raw_details', status.details)
      END AS details,
      status.timestamp AS last_observed_at,
      'legacy:service-identity:' ||
        md5(concat_ws('|', status.agent_id, status.gateway_id, COALESCE(status.partition, 'default'), status.service_type, status.service_name)) AS identity_key,
      'legacy:service-identity:' ||
        md5(concat_ws('|', status.agent_id, status.gateway_id, COALESCE(status.partition, 'default'), status.service_type, status.service_name)) AS check_key
    FROM platform.service_status AS status
    WHERE COALESCE(status.agent_id, '') <> ''
      AND COALESCE(status.gateway_id, '') <> ''
      AND COALESCE(status.service_type, '') <> ''
      AND COALESCE(status.service_name, '') <> ''
      AND NOT EXISTS (
        SELECT 1
        FROM platform.service_state AS state
        WHERE state.agent_id = status.agent_id
          AND state.gateway_id = status.gateway_id
          AND COALESCE(state.partition, 'default') = COALESCE(status.partition, 'default')
          AND state.service_type = status.service_type
          AND state.service_name = status.service_name
      )
    ORDER BY status.agent_id, status.gateway_id, COALESCE(status.partition, 'default'), status.service_type, status.service_name, status.timestamp DESC
    """
  end
end
