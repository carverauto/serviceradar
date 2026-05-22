-- ServiceRadar service monitoring demo seed.
--
-- This file creates 200 URL service targets, 200 database service targets,
-- monitoring groups, descriptor bindings, check instances, latest check state,
-- SLIs, SLOs, and example SLO evaluations.
--
-- It is intended for demo and staging environments after the service
-- monitoring migrations have been applied.

BEGIN;

SET LOCAL search_path TO platform, public;

WITH clock AS (
  SELECT (now() AT TIME ZONE 'utc')::timestamptz AS now_ts
),
import_batch AS (
  INSERT INTO monitored_service_import_batches (
    id,
    source_type,
    status,
    filename,
    total_rows,
    valid_rows,
    invalid_rows,
    duplicate_rows,
    created_by_actor_id,
    metadata
  )
  VALUES (
    '30000000-0000-0000-0000-000000000001'::uuid,
    'api',
    'committed',
    'service-monitoring-demo-seed.sql',
    400,
    400,
    0,
    0,
    'demo-seed',
    '{"scenario":"service-monitoring-400-targets"}'::jsonb
  )
  ON CONFLICT (id) DO UPDATE SET
    status = EXCLUDED.status,
    total_rows = EXCLUDED.total_rows,
    valid_rows = EXCLUDED.valid_rows,
    invalid_rows = EXCLUDED.invalid_rows,
    duplicate_rows = EXCLUDED.duplicate_rows,
    metadata = EXCLUDED.metadata,
    updated_at = now()
  RETURNING id
),
groups AS (
  INSERT INTO service_groups (
    id,
    name,
    slug,
    description,
    selection_mode,
    srql_query,
    status,
    tags,
    metadata
  )
  VALUES
    (
      '31000000-0000-0000-0000-000000000001'::uuid,
      'Demo Public URLs',
      'demo-public-urls',
      'Two hundred HTTP URL checks for NOC dashboard demos.',
      'explicit',
      NULL,
      'active',
      '{"demo":"service-monitoring","role":"public-web"}'::jsonb,
      '{"import_batch_id":"30000000-0000-0000-0000-000000000001"}'::jsonb
    ),
    (
      '31000000-0000-0000-0000-000000000002'::uuid,
      'Demo Databases',
      'demo-databases',
      'Two hundred database availability checks for credential and SLO demos.',
      'explicit',
      NULL,
      'active',
      '{"demo":"service-monitoring","role":"database"}'::jsonb,
      '{"import_batch_id":"30000000-0000-0000-0000-000000000001"}'::jsonb
    ),
    (
      '31000000-0000-0000-0000-000000000003'::uuid,
      'Demo NOC Critical',
      'demo-noc-critical',
      'Combined service group used by the NOC dashboard and SLO examples.',
      'srql',
      'in:monitored_services tag.demo:service-monitoring status:active',
      'active',
      '{"demo":"service-monitoring","noc":"primary"}'::jsonb,
      '{"import_batch_id":"30000000-0000-0000-0000-000000000001"}'::jsonb
    )
  ON CONFLICT (slug) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    selection_mode = EXCLUDED.selection_mode,
    srql_query = EXCLUDED.srql_query,
    status = EXCLUDED.status,
    tags = EXCLUDED.tags,
    metadata = EXCLUDED.metadata,
    updated_at = now()
  RETURNING id, slug
),
url_services AS (
  INSERT INTO monitored_services (
    id,
    service_key,
    display_name,
    description,
    service_kind,
    protocol,
    endpoint_url,
    host,
    port,
    path,
    owner,
    status,
    source,
    tags,
    metadata
  )
  SELECT
    ('32000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
    'https://demo-url-' || lpad(n::text, 3, '0') || '.example.test/health',
    'Demo URL ' || lpad(n::text, 3, '0'),
    'Synthetic URL availability target for service monitoring demos.',
    'http',
    'https',
    'https://demo-url-' || lpad(n::text, 3, '0') || '.example.test/health',
    'demo-url-' || lpad(n::text, 3, '0') || '.example.test',
    443,
    '/health',
    'noc',
    'active',
    'bulk_import',
    jsonb_build_object(
      'demo', 'service-monitoring',
      'role', 'public-web',
      'noc', 'primary',
      'import_batch', 'service-monitoring-demo'
    ),
    jsonb_build_object(
      'import_batch_id', '30000000-0000-0000-0000-000000000001',
      'ordinal', n
    )
  FROM generate_series(1, 200) AS gs(n)
  ON CONFLICT (service_key) DO UPDATE SET
    display_name = EXCLUDED.display_name,
    description = EXCLUDED.description,
    service_kind = EXCLUDED.service_kind,
    protocol = EXCLUDED.protocol,
    endpoint_url = EXCLUDED.endpoint_url,
    host = EXCLUDED.host,
    port = EXCLUDED.port,
    path = EXCLUDED.path,
    owner = EXCLUDED.owner,
    status = EXCLUDED.status,
    source = EXCLUDED.source,
    tags = EXCLUDED.tags,
    metadata = EXCLUDED.metadata,
    updated_at = now()
  RETURNING id
),
database_services AS (
  INSERT INTO monitored_services (
    id,
    service_key,
    display_name,
    description,
    service_kind,
    protocol,
    host,
    port,
    database_name,
    owner,
    status,
    source,
    tags,
    metadata
  )
  SELECT
    ('32100000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
    'postgres://demo-db-' || lpad(n::text, 3, '0') || '.example.test:5432/app',
    'Demo Database ' || lpad(n::text, 3, '0'),
    'Synthetic PostgreSQL availability target for service monitoring demos.',
    'database',
    'postgres',
    'demo-db-' || lpad(n::text, 3, '0') || '.example.test',
    5432,
    'app',
    'noc',
    'active',
    'bulk_import',
    jsonb_build_object(
      'demo', 'service-monitoring',
      'role', 'database',
      'noc', 'primary',
      'credential_purpose', 'database.monitor',
      'import_batch', 'service-monitoring-demo'
    ),
    jsonb_build_object(
      'import_batch_id', '30000000-0000-0000-0000-000000000001',
      'ordinal', n,
      'example_device_tag_selector', 'role:database'
    )
  FROM generate_series(1, 200) AS gs(n)
  ON CONFLICT (service_key) DO UPDATE SET
    display_name = EXCLUDED.display_name,
    description = EXCLUDED.description,
    service_kind = EXCLUDED.service_kind,
    protocol = EXCLUDED.protocol,
    host = EXCLUDED.host,
    port = EXCLUDED.port,
    database_name = EXCLUDED.database_name,
    owner = EXCLUDED.owner,
    status = EXCLUDED.status,
    source = EXCLUDED.source,
    tags = EXCLUDED.tags,
    metadata = EXCLUDED.metadata,
    updated_at = now()
  RETURNING id
),
memberships AS (
  INSERT INTO service_group_memberships (
    id,
    service_group_id,
    monitored_service_id,
    source,
    metadata
  )
  SELECT
    ('33000000-0000-0000-0001-' || lpad(row_number() OVER (ORDER BY id)::text, 12, '0'))::uuid,
    '31000000-0000-0000-0000-000000000001'::uuid,
    id,
    'bulk_import',
    '{"reason":"url-demo"}'::jsonb
  FROM url_services
  UNION ALL
  SELECT
    ('33000000-0000-0000-0002-' || lpad(row_number() OVER (ORDER BY id)::text, 12, '0'))::uuid,
    '31000000-0000-0000-0000-000000000002'::uuid,
    id,
    'bulk_import',
    '{"reason":"database-demo"}'::jsonb
  FROM database_services
  UNION ALL
  SELECT
    ('33000000-0000-0000-0003-' || lpad(row_number() OVER (ORDER BY id)::text, 12, '0'))::uuid,
    '31000000-0000-0000-0000-000000000003'::uuid,
    id,
    'bulk_import',
    '{"reason":"noc-critical-demo"}'::jsonb
  FROM (
    SELECT id FROM url_services
    UNION ALL
    SELECT id FROM database_services
  ) all_services
  ON CONFLICT (service_group_id, monitored_service_id) DO UPDATE SET
    source = EXCLUDED.source,
    metadata = EXCLUDED.metadata,
    updated_at = now()
  RETURNING id
),
bindings AS (
  INSERT INTO monitoring_bindings (
    id,
    name,
    description,
    descriptor_id,
    descriptor_version,
    capability_kind,
    target_set_type,
    service_group_id,
    interval_seconds,
    timeout_seconds,
    credential_policy,
    threshold_policy,
    event_policy,
    alert_policy,
    status,
    metadata
  )
  VALUES
    (
      '34000000-0000-0000-0000-000000000001'::uuid,
      'Demo HTTP availability',
      'Run the loaded HTTP availability check across the demo URL services.',
      'http.url.availability',
      '1.0.0',
      'plugin',
      'service_group',
      '31000000-0000-0000-0000-000000000001'::uuid,
      60,
      5,
      '{"requirement":"none"}'::jsonb,
      '{"critical_after_failures":2,"warning_latency_ms":750}'::jsonb,
      '{"emit_on":["status_change","slo_transition"],"minimum_severity":"info"}'::jsonb,
      '{"promote_after_failures":2,"cooldown_seconds":300}'::jsonb,
      'active',
      '{"demo":"service-monitoring"}'::jsonb
    ),
    (
      '34000000-0000-0000-0000-000000000002'::uuid,
      'Demo PostgreSQL availability',
      'Run the loaded PostgreSQL availability check across the demo database services.',
      'postgres.availability',
      '1.0.0',
      'plugin',
      'service_group',
      '31000000-0000-0000-0000-000000000002'::uuid,
      120,
      10,
      '{"requirement":"required","purpose":"database.monitor","source_preference":["service_override","device_override","network_rule","external_secret"]}'::jsonb,
      '{"critical_after_failures":2,"warning_latency_ms":1000}'::jsonb,
      '{"emit_on":["status_change","slo_transition"],"minimum_severity":"info"}'::jsonb,
      '{"promote_after_failures":2,"cooldown_seconds":300}'::jsonb,
      'active',
      '{"demo":"service-monitoring","credential_demo":"openbao-ready"}'::jsonb
    )
  ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    descriptor_id = EXCLUDED.descriptor_id,
    descriptor_version = EXCLUDED.descriptor_version,
    capability_kind = EXCLUDED.capability_kind,
    target_set_type = EXCLUDED.target_set_type,
    service_group_id = EXCLUDED.service_group_id,
    interval_seconds = EXCLUDED.interval_seconds,
    timeout_seconds = EXCLUDED.timeout_seconds,
    credential_policy = EXCLUDED.credential_policy,
    threshold_policy = EXCLUDED.threshold_policy,
    event_policy = EXCLUDED.event_policy,
    alert_policy = EXCLUDED.alert_policy,
    status = EXCLUDED.status,
    metadata = EXCLUDED.metadata,
    updated_at = now()
  RETURNING id
),
checks AS (
  INSERT INTO check_instances (
    id,
    check_key,
    monitoring_binding_id,
    monitored_service_id,
    descriptor_id,
    descriptor_version,
    capability_kind,
    vantage_kind,
    vantage_id,
    target_snapshot,
    credential_policy_snapshot,
    event_policy_snapshot,
    status,
    last_materialized_at,
    metadata
  )
  SELECT
    ('35000000-0000-0000-0001-' || lpad(row_number() OVER (ORDER BY service_key)::text, 12, '0'))::uuid,
    'demo:http:' || service_key,
    '34000000-0000-0000-0000-000000000001'::uuid,
    id,
    'http.url.availability',
    '1.0.0',
    'plugin',
    'agent',
    'demo-agent',
    jsonb_build_object('url', endpoint_url, 'host', host, 'port', port, 'path', path),
    '{"requirement":"none"}'::jsonb,
    '{"emit_on":["status_change","slo_transition"],"minimum_severity":"info"}'::jsonb,
    'active',
    clock.now_ts - interval '2 minutes',
    '{"demo":"service-monitoring"}'::jsonb
  FROM monitored_services, clock
  WHERE service_key LIKE 'https://demo-url-%'
  UNION ALL
  SELECT
    ('35000000-0000-0000-0002-' || lpad(row_number() OVER (ORDER BY service_key)::text, 12, '0'))::uuid,
    'demo:postgres:' || service_key,
    '34000000-0000-0000-0000-000000000002'::uuid,
    id,
    'postgres.availability',
    '1.0.0',
    'plugin',
    'agent',
    'demo-agent',
    jsonb_build_object('host', host, 'port', port, 'database', database_name),
    '{"requirement":"required","purpose":"database.monitor","broker_grant_required":true}'::jsonb,
    '{"emit_on":["status_change","slo_transition"],"minimum_severity":"info"}'::jsonb,
    'active',
    clock.now_ts - interval '2 minutes',
    '{"demo":"service-monitoring"}'::jsonb
  FROM monitored_services, clock
  WHERE service_key LIKE 'postgres://demo-db-%'
  ON CONFLICT (check_key) DO UPDATE SET
    monitoring_binding_id = EXCLUDED.monitoring_binding_id,
    monitored_service_id = EXCLUDED.monitored_service_id,
    descriptor_id = EXCLUDED.descriptor_id,
    descriptor_version = EXCLUDED.descriptor_version,
    capability_kind = EXCLUDED.capability_kind,
    vantage_kind = EXCLUDED.vantage_kind,
    vantage_id = EXCLUDED.vantage_id,
    target_snapshot = EXCLUDED.target_snapshot,
    credential_policy_snapshot = EXCLUDED.credential_policy_snapshot,
    event_policy_snapshot = EXCLUDED.event_policy_snapshot,
    status = EXCLUDED.status,
    last_materialized_at = EXCLUDED.last_materialized_at,
    metadata = EXCLUDED.metadata,
    updated_at = now()
  RETURNING id, check_key, monitoring_binding_id, monitored_service_id, descriptor_id, vantage_kind, vantage_id
),
latest AS (
  INSERT INTO latest_check_states (
    id,
    check_instance_id,
    monitored_service_id,
    monitoring_binding_id,
    vantage_kind,
    vantage_id,
    status,
    previous_status,
    status_changed_at,
    last_observed_at,
    response_time_ms,
    summary,
    details,
    metrics,
    consecutive_failures,
    event_emitted_at
  )
  SELECT
    ('36000000-0000-0000-0000-' || lpad(row_number() OVER (ORDER BY check_key)::text, 12, '0'))::uuid,
    c.id,
    c.monitored_service_id,
    c.monitoring_binding_id,
    c.vantage_kind,
    c.vantage_id,
    CASE
      WHEN row_number() OVER (ORDER BY check_key) % 37 = 0 THEN 'critical'
      WHEN row_number() OVER (ORDER BY check_key) % 19 = 0 THEN 'warning'
      ELSE 'ok'
    END,
    'ok',
    clock.now_ts - ((row_number() OVER (ORDER BY check_key) % 30) || ' minutes')::interval,
    clock.now_ts - ((row_number() OVER (ORDER BY check_key) % 10) || ' minutes')::interval,
    CASE
      WHEN c.descriptor_id = 'postgres.availability' THEN 80 + (row_number() OVER (ORDER BY check_key) % 900)
      ELSE 20 + (row_number() OVER (ORDER BY check_key) % 700)
    END,
    CASE
      WHEN row_number() OVER (ORDER BY check_key) % 37 = 0 THEN 'Synthetic critical state'
      WHEN row_number() OVER (ORDER BY check_key) % 19 = 0 THEN 'Synthetic warning state'
      ELSE 'Synthetic OK state'
    END,
    jsonb_build_object('demo', true, 'descriptor_id', c.descriptor_id),
    jsonb_build_object(
      'latency_ms',
      CASE
        WHEN c.descriptor_id = 'postgres.availability' THEN 80 + (row_number() OVER (ORDER BY check_key) % 900)
        ELSE 20 + (row_number() OVER (ORDER BY check_key) % 700)
      END
    ),
    CASE
      WHEN row_number() OVER (ORDER BY check_key) % 37 = 0 THEN 3
      WHEN row_number() OVER (ORDER BY check_key) % 19 = 0 THEN 1
      ELSE 0
    END,
    clock.now_ts - ((row_number() OVER (ORDER BY check_key) % 10) || ' minutes')::interval
  FROM checks c, clock
  ON CONFLICT (check_instance_id) DO UPDATE SET
    monitored_service_id = EXCLUDED.monitored_service_id,
    monitoring_binding_id = EXCLUDED.monitoring_binding_id,
    vantage_kind = EXCLUDED.vantage_kind,
    vantage_id = EXCLUDED.vantage_id,
    status = EXCLUDED.status,
    previous_status = EXCLUDED.previous_status,
    status_changed_at = EXCLUDED.status_changed_at,
    last_observed_at = EXCLUDED.last_observed_at,
    response_time_ms = EXCLUDED.response_time_ms,
    summary = EXCLUDED.summary,
    details = EXCLUDED.details,
    metrics = EXCLUDED.metrics,
    consecutive_failures = EXCLUDED.consecutive_failures,
    event_emitted_at = EXCLUDED.event_emitted_at,
    updated_at = now()
  RETURNING id
),
slis AS (
  INSERT INTO service_level_indicators (
    id,
    sli_key,
    name,
    description,
    sli_type,
    source_type,
    measurement_kind,
    good_statuses,
    window_config,
    status,
    metadata
  )
  VALUES
    (
      '37000000-0000-0000-0000-000000000001'::uuid,
      'demo-url-availability',
      'Demo URL availability',
      'Good events are URL checks in OK or warning status.',
      'availability',
      'check_state',
      'request',
      ARRAY['ok','warning'],
      '{}'::jsonb,
      'active',
      '{"demo":"service-monitoring"}'::jsonb
    ),
    (
      '37000000-0000-0000-0000-000000000002'::uuid,
      'demo-database-availability',
      'Demo database availability',
      'Good events are database checks in OK status.',
      'availability',
      'check_state',
      'request',
      ARRAY['ok'],
      '{}'::jsonb,
      'active',
      '{"demo":"service-monitoring"}'::jsonb
    )
  ON CONFLICT (sli_key) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    sli_type = EXCLUDED.sli_type,
    source_type = EXCLUDED.source_type,
    measurement_kind = EXCLUDED.measurement_kind,
    good_statuses = EXCLUDED.good_statuses,
    window_config = EXCLUDED.window_config,
    status = EXCLUDED.status,
    metadata = EXCLUDED.metadata,
    updated_at = now()
  RETURNING id, sli_key
),
slos AS (
  INSERT INTO service_level_objectives (
    id,
    slo_key,
    name,
    description,
    sli_id,
    target_set_type,
    service_group_id,
    slo_kind,
    goal_basis_points,
    compliance_period_type,
    rolling_period_days,
    calendar_period,
    measurement_window_seconds,
    burn_rate_policy,
    alert_policy,
    owner,
    status,
    last_evaluated_at,
    last_compliance_state,
    last_budget_remaining_basis_points,
    last_burn_rate,
    metadata
  )
  VALUES
    (
      '38000000-0000-0000-0000-000000000001'::uuid,
      'demo-url-99-9-rolling-30d',
      'Demo URL 99.9% rolling 30 day availability',
      'Request-based SLO over the demo public URL service group.',
      '37000000-0000-0000-0000-000000000001'::uuid,
      'service_group',
      '31000000-0000-0000-0000-000000000001'::uuid,
      'request_based',
      9990,
      'rolling',
      30,
      NULL,
      NULL,
      '{"short_window_threshold":4.0,"critical_threshold":10.0}'::jsonb,
      '{"warn_budget_remaining_below_basis_points":2500,"promote_on":["budget_exhausted","critical_burn_rate"]}'::jsonb,
      'noc',
      'active',
      (SELECT now_ts FROM clock),
      'at_risk',
      2100,
      4.250000,
      '{"demo":"service-monitoring"}'::jsonb
    ),
    (
      '38000000-0000-0000-0000-000000000002'::uuid,
      'demo-db-99-calendar-week',
      'Demo database 99% calendar week availability',
      'Request-based SLO over the demo database service group.',
      '37000000-0000-0000-0000-000000000002'::uuid,
      'service_group',
      '31000000-0000-0000-0000-000000000002'::uuid,
      'request_based',
      9900,
      'calendar',
      NULL,
      'week',
      NULL,
      '{"short_window_threshold":2.0,"critical_threshold":6.0}'::jsonb,
      '{"warn_budget_remaining_below_basis_points":3000,"promote_on":["budget_exhausted","critical_burn_rate"]}'::jsonb,
      'database-ops',
      'active',
      (SELECT now_ts FROM clock),
      'noncompliant',
      -800,
      7.500000,
      '{"demo":"service-monitoring","credential_demo":"openbao-ready"}'::jsonb
    )
  ON CONFLICT (slo_key) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    sli_id = EXCLUDED.sli_id,
    target_set_type = EXCLUDED.target_set_type,
    service_group_id = EXCLUDED.service_group_id,
    slo_kind = EXCLUDED.slo_kind,
    goal_basis_points = EXCLUDED.goal_basis_points,
    compliance_period_type = EXCLUDED.compliance_period_type,
    rolling_period_days = EXCLUDED.rolling_period_days,
    calendar_period = EXCLUDED.calendar_period,
    measurement_window_seconds = EXCLUDED.measurement_window_seconds,
    burn_rate_policy = EXCLUDED.burn_rate_policy,
    alert_policy = EXCLUDED.alert_policy,
    owner = EXCLUDED.owner,
    status = EXCLUDED.status,
    last_evaluated_at = EXCLUDED.last_evaluated_at,
    last_compliance_state = EXCLUDED.last_compliance_state,
    last_budget_remaining_basis_points = EXCLUDED.last_budget_remaining_basis_points,
    last_burn_rate = EXCLUDED.last_burn_rate,
    metadata = EXCLUDED.metadata,
    updated_at = now()
  RETURNING id
)
INSERT INTO service_level_objective_evaluations (
  id,
  evaluation_key,
  slo_id,
  period_started_at,
  period_ended_at,
  evaluated_at,
  compliance_state,
  eligible_events,
  good_events,
  bad_events,
  compliance_basis_points,
  goal_basis_points,
  error_budget_total,
  error_budget_consumed,
  error_budget_remaining,
  budget_remaining_basis_points,
  burn_rate_short,
  burn_rate_long,
  projected_exhaustion_at,
  severity,
  details,
  metadata
)
VALUES
  (
    '39000000-0000-0000-0000-000000000001'::uuid,
    'demo-url-99-9-rolling-30d:' || to_char((SELECT now_ts FROM clock), 'YYYYMMDDHH24MI'),
    '38000000-0000-0000-0000-000000000001'::uuid,
    (SELECT now_ts FROM clock) - interval '30 days',
    (SELECT now_ts FROM clock),
    (SELECT now_ts FROM clock),
    'at_risk',
    6000,
    5987,
    13,
    9978,
    9990,
    6,
    13,
    -7,
    2100,
    4.250000,
    1.800000,
    (SELECT now_ts FROM clock) + interval '9 hours',
    'warning',
    '{"error_budget_state":"at_risk","burn_rate_state":"warning"}'::jsonb,
    '{"demo":"service-monitoring"}'::jsonb
  ),
  (
    '39000000-0000-0000-0000-000000000002'::uuid,
    'demo-db-99-calendar-week:' || to_char((SELECT now_ts FROM clock), 'IYYYIW'),
    '38000000-0000-0000-0000-000000000002'::uuid,
    date_trunc('week', (SELECT now_ts FROM clock)),
    (SELECT now_ts FROM clock),
    (SELECT now_ts FROM clock),
    'noncompliant',
    2400,
    2355,
    45,
    9813,
    9900,
    24,
    45,
    -21,
    -800,
    7.500000,
    3.100000,
    NULL,
    'critical',
    '{"error_budget_state":"exhausted","burn_rate_state":"critical"}'::jsonb,
    '{"demo":"service-monitoring","credential_demo":"openbao-ready"}'::jsonb
  )
ON CONFLICT (evaluation_key) DO UPDATE SET
  period_started_at = EXCLUDED.period_started_at,
  period_ended_at = EXCLUDED.period_ended_at,
  evaluated_at = EXCLUDED.evaluated_at,
  compliance_state = EXCLUDED.compliance_state,
  eligible_events = EXCLUDED.eligible_events,
  good_events = EXCLUDED.good_events,
  bad_events = EXCLUDED.bad_events,
  compliance_basis_points = EXCLUDED.compliance_basis_points,
  goal_basis_points = EXCLUDED.goal_basis_points,
  error_budget_total = EXCLUDED.error_budget_total,
  error_budget_consumed = EXCLUDED.error_budget_consumed,
  error_budget_remaining = EXCLUDED.error_budget_remaining,
  budget_remaining_basis_points = EXCLUDED.budget_remaining_basis_points,
  burn_rate_short = EXCLUDED.burn_rate_short,
  burn_rate_long = EXCLUDED.burn_rate_long,
  projected_exhaustion_at = EXCLUDED.projected_exhaustion_at,
  severity = EXCLUDED.severity,
  details = EXCLUDED.details,
  metadata = EXCLUDED.metadata,
  updated_at = now();

COMMIT;
