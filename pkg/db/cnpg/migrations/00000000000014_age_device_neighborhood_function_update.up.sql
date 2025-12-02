-- Refine AGE device neighborhood helper to handle collector/service roots and
-- return host-aware services/collectors without self-target echoes.
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
    -- Ensure AGE objects are visible in the session.
    PERFORM set_config('search_path', 'ag_catalog,pg_catalog,"$user",public', false);

    cypher_sql := format($cypher$
        WITH %s::boolean AS include_topology, %s::boolean AS collector_only
        MATCH (c:Collector {id: %L})
        OPTIONAL MATCH (c)-[:HOSTS_SERVICE]->(svc:Service)
        OPTIONAL MATCH (svc)-[:TARGETS]->(t:Device)
        OPTIONAL MATCH (svc)-[:PROVIDES_CAPABILITY]->(svcCap:Capability)
        OPTIONAL MATCH (reported:Device)-[:REPORTED_BY]->(c)
        OPTIONAL MATCH (c)-[:REPORTED_BY]->(parentCol:Collector)
        WITH c, include_topology,
             collect(DISTINCT CASE WHEN svc IS NOT NULL THEN {service: properties(svc), collector_id: c.id, collector_owned: true} ELSE NULL END) AS services_output_raw,
             collect(DISTINCT t) AS targets,
             collect(DISTINCT svcCap) AS service_caps,
             collect(DISTINCT reported) AS reported_devices,
             collect(DISTINCT parentCol) AS parent_collectors
        UNWIND (targets + reported_devices) AS tgt
        WITH c, include_topology, services_output_raw, service_caps, collect(DISTINCT tgt) AS all_targets, parent_collectors
        RETURN {
            device: properties(c),
            collectors: [pc IN parent_collectors WHERE pc IS NOT NULL | properties(pc)],
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
        $cypher$, include_topology, collector_only, p_device_id);

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
        -- AGE not available; preserve prior behavior by returning NULL.
        RETURN NULL;
END;
$$;
