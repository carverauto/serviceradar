-- Canonical SRQL device fixture rows (OCSF v1.7.0 aligned).
TRUNCATE ocsf_devices;
WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO ocsf_devices (
        uid,
        type_id,
        type,
        name,
        hostname,
        ip,
        mac,
        vendor_name,
        model,
        first_seen_time,
        last_seen_time,
        created_time,
        modified_time,
        risk_level_id,
        risk_level,
        os,
        gateway_id,
        agent_id,
        discovery_sources,
        is_available,
        metadata
    )
SELECT 'device-alpha',
    12,  -- Router
    'Router',
    'Alpha Edge Router',
    'alpha-edge',
    '10.10.10.5',
    'aa:bb:cc:dd:ee:01',
    'Cisco',
    'ISR 4451',
    base.now_ts - INTERVAL '14 days',
    base.now_ts - INTERVAL '30 minutes',
    base.now_ts - INTERVAL '14 days',
    base.now_ts - INTERVAL '30 minutes',
    0,  -- Info
    'Info',
    '{"name":"IOS-XE","version":"17.9.3"}'::jsonb,
    'gateway-1',
    'agent-1',
    ARRAY ['sweep','armis'],
    TRUE,
    '{"site":"dfw-edge","packet_loss_bucket":"low"}'::jsonb
FROM base
UNION ALL
SELECT 'device-beta',
    10,  -- Switch
    'Switch',
    'Beta Core Switch',
    'beta-core',
    '10.10.20.6',
    'aa:bb:cc:dd:ee:02',
    'Cisco',
    'Nexus 9300',
    base.now_ts - INTERVAL '10 days',
    base.now_ts - INTERVAL '3 hours',
    base.now_ts - INTERVAL '10 days',
    base.now_ts - INTERVAL '3 hours',
    2,  -- Medium
    'Medium',
    '{"name":"NX-OS","version":"10.2(4)"}'::jsonb,
    'gateway-1',
    'agent-2',
    ARRAY ['armis'],
    FALSE,
    '{"site":"dfw-edge","packet_loss_bucket":"medium"}'::jsonb
FROM base
UNION ALL
SELECT 'device-gamma',
    9,  -- Firewall
    'Firewall',
    'Gamma Edge Firewall',
    'gamma-edge',
    '10.10.30.7',
    'aa:bb:cc:dd:ee:03',
    'Palo Alto Networks',
    'PA-5220',
    base.now_ts - INTERVAL '6 days',
    base.now_ts - INTERVAL '2 hours',
    base.now_ts - INTERVAL '6 days',
    base.now_ts - INTERVAL '2 hours',
    3,  -- High
    'High',
    '{"name":"PAN-OS","version":"11.1.0"}'::jsonb,
    'gateway-2',
    'agent-3',
    ARRAY ['sweep'],
    TRUE,
    '{"site":"phx-edge","packet_loss_bucket":"high"}'::jsonb
FROM base
UNION ALL
SELECT 'device-delta',
    10,  -- Switch
    'Switch',
    'Delta Legacy Switch',
    'delta-legacy',
    '10.10.40.8',
    'aa:bb:cc:dd:ee:04',
    'Cisco',
    'Catalyst 3850',
    base.now_ts - INTERVAL '20 days',
    base.now_ts - INTERVAL '8 days',
    base.now_ts - INTERVAL '20 days',
    base.now_ts - INTERVAL '8 days',
    0,  -- Info
    'Info',
    '{"name":"IOS","version":"15.2"}'::jsonb,
    'gateway-2',
    'agent-3',
    ARRAY ['sweep'],
    TRUE,
    '{"site":"phx-edge","packet_loss_bucket":"low"}'::jsonb
FROM base;
WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO gateways (
        gateway_id,
        component_id,
        registration_source,
        status,
        spiffe_identity,
        first_registered,
        first_seen,
        last_seen,
        metadata,
        created_by,
        is_healthy,
        agent_count,
        checker_count,
        updated_at,
        tenant_id,
        partition_id
    )
SELECT 'gateway-1',
    'comp-1',
    'manual',
    'active',
    'spiffe://example.org/gateway/1',
    base.now_ts - INTERVAL '30 days',
    base.now_ts - INTERVAL '30 days',
    base.now_ts - INTERVAL '1 minute',
    '{"region":"us-west"}'::jsonb,
    'admin',
    true,
    10,
    50,
    base.now_ts,
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000010'
FROM base
UNION ALL
SELECT 'gateway-2',
    'comp-2',
    'auto',
    'active',
    'spiffe://example.org/gateway/2',
    base.now_ts - INTERVAL '15 days',
    base.now_ts - INTERVAL '15 days',
    base.now_ts - INTERVAL '2 minutes',
    '{"region":"us-east"}'::jsonb,
    'system',
    true,
    5,
    25,
    base.now_ts,
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000011'
FROM base;
WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO service_status (
        timestamp,
        gateway_id,
        agent_id,
        service_name,
        service_type,
        available,
        message,
        details,
        partition,
        created_at
    )
SELECT base.now_ts - INTERVAL '5 minutes',
    'gateway-1',
    'agent-1',
    'ssh',
    'ssh',
    true,
    'SSH service running',
    'listening on port 22',
    'default',
    base.now_ts
FROM base
UNION ALL
SELECT base.now_ts - INTERVAL '10 minutes',
    'gateway-1',
    'agent-1',
    'http',
    'http',
    false,
    'HTTP service down',
    'connection refused',
    'default',
    base.now_ts
FROM base;
WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO cpu_metrics (
        timestamp,
        gateway_id,
        agent_id,
        host_id,
        core_id,
        usage_percent,
        frequency_hz,
        label,
        cluster,
        device_id,
        partition,
        created_at
    )
SELECT base.now_ts - INTERVAL '1 minute',
    'gateway-1',
    'agent-1',
    'host-1',
    0,
    45.5,
    2400000000,
    'cpu0',
    'cluster-a',
    'device-alpha',
    'default',
    base.now_ts
FROM base
UNION ALL
SELECT base.now_ts - INTERVAL '2 minutes',
    'gateway-1',
    'agent-1',
    'host-1',
    1,
    88.2,
    2400000000,
    'cpu1',
    'cluster-a',
    'device-alpha',
    'default',
    base.now_ts
FROM base;
TRUNCATE timeseries_metrics;
WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO timeseries_metrics (
        timestamp,
        gateway_id,
        agent_id,
        metric_name,
        metric_type,
        device_id,
        value,
        unit,
        tags,
        partition,
        scale,
        is_delta,
        target_device_ip,
        if_index,
        metadata,
        created_at
    )
SELECT base.now_ts - INTERVAL '5 minutes',
    'gateway-1',
    'agent-1',
    'snmp.ifInOctets',
    'snmp',
    'device-alpha',
    12345.5,
    'bytes',
    '{"direction":"in"}'::jsonb,
    'default',
    NULL::FLOAT8,
    FALSE,
    '10.10.10.5',
    1,
    '{"device_id":"device-alpha"}'::jsonb,
    base.now_ts
FROM base
UNION ALL
SELECT base.now_ts - INTERVAL '3 minutes',
    'gateway-2',
    'agent-3',
    'rperf.latency_ms',
    'rperf',
    'device-beta',
    12.3,
    'ms',
    '{"test":"throughput"}'::jsonb,
    'default',
    NULL::FLOAT8,
    FALSE,
    '10.10.20.6',
    NULL,
    '{"target":"device-beta"}'::jsonb,
    base.now_ts
FROM base
UNION ALL
SELECT base.now_ts - INTERVAL '1 minute',
    'gateway-1',
    'agent-1',
    'sysmon.cpu_usage',
    'sysmon',
    'device-alpha',
    76.2,
    'percent',
    '{"source":"sysmon"}'::jsonb,
    'default',
    NULL::FLOAT8,
    FALSE,
    '10.10.10.5',
    NULL,
    '{"component":"cpu"}'::jsonb,
    base.now_ts
FROM base;
WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO logs (
        timestamp,
        trace_id,
        span_id,
        severity_text,
        severity_number,
        body,
        service_name,
        service_version,
        service_instance,
        scope_name,
        scope_version,
        attributes,
        resource_attributes,
        created_at
    )
SELECT base.now_ts - INTERVAL '1 minute',
    'trace-1',
    'span-1',
    'INFO',
    9,
    'Application started',
    'my-service',
    '1.0.0',
    'inst-1',
    'my-scope',
    '1.0',
    '{"key":"value"}'::text,
    '{"res":"val"}'::text,
    base.now_ts
FROM base
UNION ALL
SELECT base.now_ts - INTERVAL '5 minutes',
    'trace-2',
    'span-2',
    'ERROR',
    17,
    'Connection failed',
    'my-service',
    '1.0.0',
    'inst-1',
    'my-scope',
    '1.0',
    '{"error":"timeout"}'::text,
    '{"res":"val"}'::text,
    base.now_ts
FROM base;
WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO otel_traces (
        timestamp,
        trace_id,
        span_id,
        parent_span_id,
        name,
        kind,
        start_time_unix_nano,
        end_time_unix_nano,
        service_name,
        service_version,
        service_instance,
        scope_name,
        scope_version,
        status_code,
        status_message,
        attributes,
        resource_attributes,
        events,
        links,
        created_at
    )
SELECT base.now_ts - INTERVAL '1 minute',
    'trace-1',
    'span-1',
    NULL,
    'handle_request',
    1,
    1600000000000000000,
    1600000000100000000,
    'api-service',
    'v1',
    'pod-1',
    'http-server',
    '1.0',
    1,
    'OK',
    '{"http.method":"GET"}'::text,
    '{"k8s.pod":"pod-1"}'::text,
    '[]',
    '[]',
    base.now_ts
FROM base;

-- Seed AGE graph data for device_graph SRQL queries (best-effort when privileges allow).
SET LOCAL search_path = ag_catalog, public, "$user";

DO $$
BEGIN
    BEGIN
        PERFORM ag_catalog.create_graph('serviceradar');
    EXCEPTION
        WHEN others THEN NULL;
    END;

    BEGIN
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO PUBLIC', 'serviceradar');
        EXECUTE format('GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA %I TO PUBLIC', 'serviceradar');
    EXCEPTION
        WHEN insufficient_privilege THEN NULL;
        WHEN others THEN NULL;
    END;

    BEGIN
        GRANT USAGE ON SCHEMA ag_catalog TO PUBLIC;
        GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ag_catalog TO PUBLIC;
    EXCEPTION
        WHEN insufficient_privilege THEN NULL;
        WHEN others THEN NULL;
    END;

    BEGIN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Device');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Collector');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Service');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Interface');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Capability');
    EXCEPTION
        WHEN others THEN NULL;
    END;

    BEGIN
        PERFORM ag_catalog.create_elabel('serviceradar', 'HOSTS_SERVICE');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_elabel('serviceradar', 'TARGETS');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_elabel('serviceradar', 'HAS_INTERFACE');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_elabel('serviceradar', 'REPORTED_BY');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_elabel('serviceradar', 'PROVIDES_CAPABILITY');
    EXCEPTION
        WHEN others THEN NULL;
    END;

    PERFORM * FROM ag_catalog.cypher('serviceradar', $_cypher$
        MERGE (d:Device {id: 'device-alpha', hostname: 'alpha-edge'})
        MERGE (c:Collector {id: 'serviceradar:agent:agent-1'})
        MERGE (svc:Service {id: 'serviceradar:service:ssh@agent-1', type: 'ssh'})
        MERGE (iface:Interface {id: 'device-alpha/eth0', name: 'eth0'})
        MERGE (cap:Capability {type: 'snmp'})
        MERGE (d)-[:HAS_INTERFACE]->(iface)
        MERGE (d)-[:PROVIDES_CAPABILITY]->(cap)
        MERGE (c)-[:HOSTS_SERVICE]->(svc)
        MERGE (svc)-[:TARGETS]->(d)
        MERGE (d)-[:REPORTED_BY]->(c)
    $_cypher$) AS (result agtype);
EXCEPTION
    WHEN insufficient_privilege THEN
        RAISE NOTICE 'Skipping AGE graph seed due to insufficient privileges';
END $$;

CREATE OR REPLACE FUNCTION public.age_device_neighborhood(
    p_device_id text,
    p_collector_owned_only boolean DEFAULT false,
    p_include_topology boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    cypher_sql text;
    cypher_result ag_catalog.agtype;
    include_topology text := CASE WHEN coalesce(p_include_topology, true) THEN 'true' ELSE 'false' END;
    collector_only text := CASE WHEN coalesce(p_collector_owned_only, false) THEN 'true' ELSE 'false' END;
BEGIN
    PERFORM set_config('search_path', 'ag_catalog,pg_catalog,"$user",public', false);

    cypher_sql := format($cypher$
        WITH %s::boolean AS include_topology, %s::boolean AS collector_only
            MATCH (c:Collector {id: %L})
            OPTIONAL MATCH (c)-[:REPORTED_BY]->(parentCol:Collector)
            OPTIONAL MATCH (devAlias:Device {id: %L})-[:REPORTED_BY]->(parentFromAlias:Collector)
            OPTIONAL MATCH (childCol:Collector)-[:REPORTED_BY]->(c)
            OPTIONAL MATCH (childDev:Device)-[:REPORTED_BY]->(c)
                WHERE childDev.id STARTS WITH 'serviceradar:'
        WITH c, include_topology,
             collect(DISTINCT parentCol) + collect(DISTINCT parentFromAlias) AS parent_collectors,
             collect(DISTINCT childCol) AS child_collectors,
             collect(DISTINCT childDev.id) AS child_dev_ids
        WITH c, include_topology, parent_collectors, child_collectors,
             CASE WHEN size(child_dev_ids) = 0 THEN [NULL] ELSE child_dev_ids END AS child_dev_ids_safe
        UNWIND child_dev_ids_safe AS child_dev_id
            OPTIONAL MATCH (aliasCol:Collector {id: child_dev_id})
            WITH c, include_topology,
                 parent_collectors,
                 child_collectors,
                 collect(DISTINCT aliasCol) AS alias_child_collectors
            WITH c, include_topology,
                 [col IN parent_collectors WHERE col IS NOT NULL] AS parent_collectors,
                 [col IN (child_collectors + alias_child_collectors) WHERE col IS NOT NULL] AS child_collectors,
                 [c] + [col IN (child_collectors + alias_child_collectors) WHERE col IS NOT NULL | col] AS host_collectors
            UNWIND host_collectors AS host_col
        OPTIONAL MATCH (host_col)-[:HOSTS_SERVICE]->(svc:Service)
        OPTIONAL MATCH (svc)-[:TARGETS]->(t:Device)
        OPTIONAL MATCH (svc)-[:PROVIDES_CAPABILITY]->(svcCap:Capability)
        OPTIONAL MATCH (reported:Device)-[:REPORTED_BY]->(host_col)
        WITH c, include_topology, parent_collectors, child_collectors,
             collect(DISTINCT CASE WHEN svc IS NOT NULL THEN {service: properties(svc), collector_id: host_col.id, collector_owned: true} ELSE NULL END) AS services_output_raw,
             collect(DISTINCT t) AS service_targets,
             collect(DISTINCT svcCap) AS service_caps,
             collect(DISTINCT reported) AS reported_devices
        WITH c, include_topology, parent_collectors, child_collectors, services_output_raw, service_targets, service_caps, reported_devices,
             CASE WHEN size(service_targets + reported_devices) = 0 THEN [NULL] ELSE service_targets + reported_devices END AS combined_targets
        UNWIND combined_targets AS tgt
        WITH c, include_topology, parent_collectors, child_collectors, services_output_raw, service_caps,
             collect(DISTINCT tgt) AS all_targets
        RETURN {
            device: properties(c),
            collectors: [col IN (parent_collectors + child_collectors) WHERE col IS NOT NULL | properties(col)],
            services: [s IN services_output_raw WHERE s IS NOT NULL | s],
            targets: [tgt IN all_targets WHERE tgt IS NOT NULL | properties(tgt)],
            interfaces: [],
            peer_interfaces: [],
            device_capabilities: [],
            service_capabilities: [cap IN service_caps WHERE cap IS NOT NULL | properties(cap)]
        } AS result
    $cypher$, include_topology, collector_only, p_device_id);

    EXECUTE 'SELECT result FROM ag_catalog.cypher(''serviceradar'', ' ||
            chr(36) || chr(36) || cypher_sql || chr(36) || chr(36) ||
            ') AS (result ag_catalog.agtype)'
    INTO cypher_result;

    IF cypher_result IS NULL OR cypher_result::text = 'null' THEN
        cypher_sql := format($cypher$
            WITH %s::boolean AS include_topology, %s::boolean AS collector_only
            MATCH (d:Device {id: %L})
            OPTIONAL MATCH (d)-[:REPORTED_BY]->(col:Collector)
            OPTIONAL MATCH (col)-[:HOSTS_SERVICE]->(svc:Service)
            OPTIONAL MATCH (svc)-[:TARGETS]->(t:Device)
            OPTIONAL MATCH (svc)-[:PROVIDES_CAPABILITY]->(svcCap:Capability)
            OPTIONAL MATCH (d)-[:PROVIDES_CAPABILITY]->(dcap:Capability)
            OPTIONAL MATCH (d)-[:HAS_INTERFACE]->(iface:Interface)
            OPTIONAL MATCH (iface)-[:CONNECTS_TO]->(peer:Interface)
            WITH d, include_topology, collector_only,
                 collect(DISTINCT col) AS collectors,
                 collect(DISTINCT CASE WHEN svc IS NOT NULL AND t IS NOT NULL AND t.id = d.id AND col IS NOT NULL THEN {
                     service: properties(svc),
                     collector_id: col.id,
                     collector_owned: col IS NOT NULL
                 } ELSE NULL END) AS services_output_raw,
                 collect(DISTINCT CASE WHEN svc IS NOT NULL AND t IS NOT NULL AND t.id = d.id AND col IS NOT NULL THEN col ELSE NULL END) AS host_collectors_raw,
                 collect(DISTINCT CASE WHEN t IS NOT NULL AND t.id <> d.id THEN properties(t) ELSE NULL END) AS target_props_raw,
                 collect(DISTINCT iface) AS interfaces,
                 collect(DISTINCT peer) AS peers,
                 collect(DISTINCT dcap) AS device_caps,
                 collect(DISTINCT svcCap) AS service_caps
            WITH d, include_topology, collector_only, collectors, target_props_raw, interfaces, peers, device_caps, service_caps,
                 [c IN host_collectors_raw WHERE c IS NOT NULL] AS host_collectors,
                 [s IN services_output_raw WHERE s IS NOT NULL] AS services_output
            WITH d, include_topology, collector_only, collectors, services_output, target_props_raw, interfaces, peers, device_caps, service_caps, host_collectors,
                 CASE WHEN size(host_collectors) > 0 THEN host_collectors ELSE collectors END AS collector_list,
                 (size(host_collectors) > 0 OR size([c IN collectors WHERE c IS NOT NULL]) > 0) AS has_collector,
                 [tgt IN target_props_raw WHERE tgt IS NOT NULL | tgt] AS target_props
            WITH d, include_topology, collector_only, services_output, target_props, interfaces, peers, device_caps, service_caps, has_collector,
                 CASE WHEN size(collector_list) = 0 THEN [NULL] ELSE collector_list END AS collector_list_safe
            UNWIND collector_list_safe AS base_col
            OPTIONAL MATCH (parentCol:Collector)<-[:REPORTED_BY]-(base_col)
            WITH d, include_topology, collector_only, services_output, target_props, interfaces, peers, device_caps, service_caps, has_collector,
                 collect(DISTINCT base_col) AS collector_list_dedup,
                 collect(DISTINCT parentCol) AS parent_collectors
            WITH d, include_topology, collector_only, services_output, target_props, interfaces, peers, device_caps, service_caps,
                 collector_list_dedup + parent_collectors AS combined_collectors,
                 (has_collector OR size([p IN parent_collectors WHERE p IS NOT NULL]) > 0) AS has_any_collector
            WHERE NOT collector_only OR has_any_collector
            RETURN {
                device: properties(d),
                collectors: [c IN combined_collectors WHERE c IS NOT NULL | properties(c)],
                services: services_output,
                targets: target_props,
                interfaces: CASE WHEN include_topology THEN [i IN interfaces WHERE i IS NOT NULL | properties(i)] ELSE [] END,
                peer_interfaces: CASE WHEN include_topology THEN [p IN peers WHERE p IS NOT NULL | properties(p)] ELSE [] END,
                device_capabilities: [cap IN device_caps WHERE cap IS NOT NULL | properties(cap)],
                service_capabilities: [cap IN service_caps WHERE cap IS NOT NULL | properties(cap)]
            } AS result
        $cypher$, include_topology, collector_only, p_device_id, p_device_id);

        EXECUTE 'SELECT result FROM ag_catalog.cypher(''serviceradar'', ' ||
                chr(36) || chr(36) || cypher_sql || chr(36) || chr(36) ||
                ') AS (result ag_catalog.agtype)'
        INTO cypher_result;
    END IF;

    IF cypher_result IS NULL OR cypher_result::text = 'null' THEN
        cypher_sql := format($cypher$
            WITH %s::boolean AS include_topology, %s::boolean AS collector_only
            MATCH (svc:Service {id: %L})
            OPTIONAL MATCH (col:Collector)-[:HOSTS_SERVICE]->(svc)
            OPTIONAL MATCH (svc)-[:TARGETS]->(t:Device)
            OPTIONAL MATCH (svc)-[:PROVIDES_CAPABILITY]->(svcCap:Capability)
            WITH svc, include_topology, collector_only,
                 collect(DISTINCT col) AS collectors,
                 collect(DISTINCT t) AS targets,
                 collect(DISTINCT svcCap) AS service_caps
            WITH svc, include_topology, collector_only,
                 CASE WHEN size(collectors) = 0 THEN [NULL] ELSE collectors END AS collectors_list,
                 CASE WHEN size(targets) = 0 THEN [NULL] ELSE targets END AS targets_list,
                 service_caps
            UNWIND collectors_list AS base_col
            OPTIONAL MATCH (parentCol:Collector)<-[:REPORTED_BY]-(base_col)
            UNWIND targets_list AS tgt
            WITH svc, include_topology, collector_only, service_caps,
                 collect(DISTINCT base_col) AS collectors,
                 collect(DISTINCT parentCol) AS parent_collectors,
                 collect(DISTINCT tgt) AS targets_flat
            WITH svc, include_topology, collector_only,
                 collectors + parent_collectors AS combined_collectors,
                 targets_flat,
                 service_caps,
                 size([c IN (collectors + parent_collectors) WHERE c IS NOT NULL]) > 0 AS has_collector
            WHERE NOT collector_only OR has_collector
            RETURN {
                device: properties(svc),
                collectors: [c IN combined_collectors WHERE c IS NOT NULL | properties(c)],
                services: [{
                    service: properties(svc),
                    collector_id: CASE WHEN size([c IN combined_collectors WHERE c IS NOT NULL]) > 0 THEN (combined_collectors[0].id) ELSE NULL END,
                    collector_owned: size([c IN combined_collectors WHERE c IS NOT NULL]) > 0
                }],
                targets: [tgt IN targets_flat WHERE tgt IS NOT NULL | properties(tgt)],
                interfaces: [],
                peer_interfaces: [],
                device_capabilities: [],
                service_capabilities: [cap IN service_caps WHERE cap IS NOT NULL | properties(cap)]
            } AS result
        $cypher$, include_topology, collector_only, p_device_id);

        EXECUTE 'SELECT result FROM ag_catalog.cypher(''serviceradar'', ' ||
                chr(36) || chr(36) || cypher_sql || chr(36) || chr(36) ||
                ') AS (result ag_catalog.agtype)'
        INTO cypher_result;
    END IF;

    RETURN (cypher_result::text)::jsonb;
EXCEPTION
    WHEN undefined_function THEN
        RETURN NULL;
END;
$$;
