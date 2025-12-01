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
    PERFORM set_config('search_path', 'ag_catalog,"$user",public', false);
    PERFORM set_config('graph_path', 'serviceradar', false);

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
        WITH d, col, svc, t, iface, peer, dcap, svcCap, include_topology, collector_only,
             CASE WHEN col IS NOT NULL THEN true ELSE false END AS collector_owned
        WHERE NOT collector_only OR collector_owned
        RETURN jsonb_build_object(
            'device', d,
            'collectors', [c IN collect(DISTINCT col) WHERE c IS NOT NULL],
            'services', [s IN collect(DISTINCT CASE WHEN svc IS NULL THEN NULL ELSE jsonb_build_object(
                'service', svc,
                'collector_id', col.id,
                'collector_owned', collector_owned
            ) END) WHERE s IS NOT NULL],
            'targets', [target IN collect(DISTINCT t) WHERE target IS NOT NULL],
            'interfaces', CASE WHEN include_topology THEN [i IN collect(DISTINCT iface) WHERE i IS NOT NULL] ELSE [] END,
            'peer_interfaces', CASE WHEN include_topology THEN [p IN collect(DISTINCT peer) WHERE p IS NOT NULL] ELSE [] END,
            'device_capabilities', [cap IN collect(DISTINCT dcap) WHERE cap IS NOT NULL],
            'service_capabilities', [cap IN collect(DISTINCT svcCap) WHERE cap IS NOT NULL]
        ) AS result
    $cypher$, include_topology, collector_only, p_device_id);

    SELECT result INTO cypher_result
    FROM ag_catalog.cypher('serviceradar', cypher_sql) AS (result ag_catalog.agtype);

    RETURN cypher_result::jsonb;
EXCEPTION
    WHEN undefined_function THEN
        -- AGE not available; preserve prior behavior by returning NULL.
        RETURN NULL;
END;
$$;
