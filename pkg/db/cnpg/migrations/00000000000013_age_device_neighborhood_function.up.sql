-- Provide a reusable AGE device neighborhood helper that supports filtering collector-owned services
-- and optionally returns interface/topology edges. This keeps Go and SRQL callers aligned.
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
        MATCH (d:Device {id: %L})
        OPTIONAL MATCH (d)-[:REPORTED_BY]->(col:Collector)
        OPTIONAL MATCH (col)-[:HOSTS_SERVICE]->(svc:Service)
        OPTIONAL MATCH (svc)-[:TARGETS]->(t:Device)
        OPTIONAL MATCH (d)-[:PROVIDES_CAPABILITY]->(dcap:Capability)
        OPTIONAL MATCH (svc)-[:PROVIDES_CAPABILITY]->(svcCap:Capability)
        OPTIONAL MATCH (d)-[:HAS_INTERFACE]->(iface:Interface)
        OPTIONAL MATCH (iface)-[:CONNECTS_TO]->(peer:Interface)
        WITH d, include_topology, collector_only,
             collect(DISTINCT col) AS collectors,
             collect(DISTINCT svc) AS services,
             collect(DISTINCT t) AS targets,
             collect(DISTINCT iface) AS interfaces,
             collect(DISTINCT peer) AS peers,
             collect(DISTINCT dcap) AS device_caps,
             collect(DISTINCT svcCap) AS service_caps
        WITH d, include_topology, collector_only, collectors, services, targets, interfaces, peers, device_caps, service_caps,
             CASE WHEN size([c IN collectors WHERE c IS NOT NULL]) > 0 THEN true ELSE false END AS has_collector
        WHERE NOT collector_only OR has_collector
        RETURN {
            device: properties(d),
            collectors: [c IN collectors WHERE c IS NOT NULL | properties(c)],
            services: [s IN services WHERE s IS NOT NULL | {
                service: properties(s),
                collector_id: CASE WHEN size([c IN collectors WHERE c IS NOT NULL]) > 0 THEN (collectors[0].id) ELSE NULL END,
                collector_owned: has_collector
            }],
            targets: [tgt IN targets WHERE tgt IS NOT NULL | properties(tgt)],
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

    RETURN (cypher_result::text)::jsonb;
EXCEPTION
    WHEN undefined_function THEN
        -- AGE not available; preserve prior behavior by returning NULL.
        RETURN NULL;
END;
$$;
