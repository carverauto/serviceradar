-- Consolidated idempotent schema for ServiceRadar CNPG/Timescale
-- PUBLIC SCHEMA ONLY - Platform-level tables
-- Tenant-scoped tables are created via Elixir tenant migrations in:
--   elixir/serviceradar_core/priv/repo/tenant_migrations/

-- ================================
-- Extensions
-- ================================
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ================================
-- Platform Registry (gateways, agents, checkers)
-- These are platform-level registrations, not tenant-scoped
-- ================================
CREATE TABLE IF NOT EXISTS gateways (
    gateway_id           TEXT              PRIMARY KEY,
    component_id        TEXT              DEFAULT '',
    registration_source TEXT              DEFAULT 'implicit',
    status              TEXT              DEFAULT 'active',
    spiffe_identity     TEXT              DEFAULT '',
    first_registered    TIMESTAMPTZ       DEFAULT now(),
    first_seen          TIMESTAMPTZ,
    last_seen           TIMESTAMPTZ       DEFAULT now(),
    metadata            JSONB             DEFAULT '{}'::jsonb,
    created_by          TEXT              DEFAULT 'system',
    is_healthy          BOOLEAN           DEFAULT TRUE,
    agent_count         INTEGER           DEFAULT 0,
    checker_count       INTEGER           DEFAULT 0,
    updated_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_gateways_last_seen ON gateways (last_seen DESC);

CREATE TABLE IF NOT EXISTS agents (
    agent_id            TEXT              PRIMARY KEY,
    gateway_id           TEXT              NOT NULL,
    component_id        TEXT              DEFAULT '',
    registration_source TEXT              DEFAULT 'implicit',
    status              TEXT              DEFAULT 'active',
    spiffe_identity     TEXT              DEFAULT '',
    first_registered    TIMESTAMPTZ       DEFAULT now(),
    first_seen          TIMESTAMPTZ,
    last_seen           TIMESTAMPTZ       DEFAULT now(),
    metadata            JSONB             DEFAULT '{}'::jsonb,
    created_by          TEXT              DEFAULT 'system',
    checker_count       INTEGER           DEFAULT 0,
    updated_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_agents_gateway ON agents (gateway_id);

CREATE TABLE IF NOT EXISTS checkers (
    checker_id          TEXT              PRIMARY KEY,
    agent_id            TEXT              NOT NULL,
    gateway_id           TEXT              NOT NULL,
    checker_kind        TEXT              NOT NULL,
    component_id        TEXT              DEFAULT '',
    registration_source TEXT              DEFAULT 'implicit',
    status              TEXT              DEFAULT 'active',
    spiffe_identity     TEXT              DEFAULT '',
    first_registered    TIMESTAMPTZ       DEFAULT now(),
    first_seen          TIMESTAMPTZ,
    last_seen           TIMESTAMPTZ       DEFAULT now(),
    metadata            JSONB             DEFAULT '{}'::jsonb,
    created_by          TEXT              DEFAULT 'system',
    updated_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_checkers_agent ON checkers (agent_id);
CREATE INDEX IF NOT EXISTS idx_checkers_gateway ON checkers (gateway_id);

CREATE TABLE IF NOT EXISTS service_registration_events (
    event_id            TEXT              NOT NULL,
    event_type          TEXT              NOT NULL,
    service_id          TEXT              NOT NULL,
    service_type        TEXT              NOT NULL,
    parent_id           TEXT,
    registration_source TEXT,
    actor               TEXT,
    timestamp           TIMESTAMPTZ       NOT NULL DEFAULT now(),
    metadata            JSONB             DEFAULT '{}'::jsonb,
    PRIMARY KEY (event_id, timestamp)
);
SELECT create_hypertable('service_registration_events','timestamp', if_not_exists => TRUE);

-- ================================
-- Edge onboarding (platform-managed)
-- ================================
CREATE TABLE IF NOT EXISTS edge_onboarding_packages (
    package_id             UUID             PRIMARY KEY,
    label                  TEXT             NOT NULL,
    component_id           TEXT             DEFAULT '',
    component_type         TEXT             DEFAULT 'gateway',
    parent_type            TEXT             DEFAULT '',
    parent_id              TEXT             DEFAULT '',
    gateway_id              TEXT,
    site                   TEXT,
    status                 TEXT             DEFAULT 'pending',
    security_mode          TEXT             DEFAULT 'spire',
    downstream_entry_id    TEXT             DEFAULT '',
    downstream_spiffe_id   TEXT             DEFAULT '',
    selectors              TEXT[]           DEFAULT '{}',
    checker_kind           TEXT             DEFAULT '',
    checker_config_json    JSONB            DEFAULT '{}'::jsonb,
    join_token_ciphertext  TEXT,
    join_token_expires_at  TIMESTAMPTZ,
    bundle_ciphertext      TEXT,
    download_token_hash    TEXT,
    download_token_expires_at TIMESTAMPTZ,
    created_by             TEXT             DEFAULT 'system',
    created_at             TIMESTAMPTZ      NOT NULL,
    updated_at             TIMESTAMPTZ      NOT NULL,
    delivered_at           TIMESTAMPTZ,
    activated_at           TIMESTAMPTZ,
    activated_from_ip      TEXT,
    last_seen_spiffe_id    TEXT,
    revoked_at             TIMESTAMPTZ,
    deleted_at             TIMESTAMPTZ,
    deleted_by             TEXT             DEFAULT '',
    deleted_reason         TEXT             DEFAULT '',
    metadata_json          JSONB            DEFAULT '{}'::jsonb,
    kv_revision            BIGINT           DEFAULT 0,
    notes                  TEXT
);
CREATE INDEX IF NOT EXISTS idx_edge_packages_status ON edge_onboarding_packages (status, updated_at DESC);

CREATE TABLE IF NOT EXISTS edge_onboarding_events (
    event_time            TIMESTAMPTZ      NOT NULL,
    package_id            UUID             NOT NULL,
    event_type            TEXT             NOT NULL,
    actor                 TEXT,
    source_ip             TEXT,
    details_json          JSONB            DEFAULT '{}'::jsonb,
    PRIMARY KEY (event_time, package_id)
);
SELECT create_hypertable('edge_onboarding_events','event_time', if_not_exists => TRUE);

-- ================================
-- Apache AGE graph bootstrap (platform-level graph)
-- ================================
DO $$
BEGIN
    -- Try to create AGE extension (may not be available in all environments)
    BEGIN
        CREATE EXTENSION IF NOT EXISTS age;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'AGE extension not available: %', SQLERRM;
        RETURN;
    END;
END $$;

-- AGE graph setup (only runs if AGE is available)
DO $$
DECLARE
    graph_oid oid;
BEGIN
    -- Check if AGE is available
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'age') THEN
        RETURN;
    END IF;

    -- Set search path for AGE
    PERFORM set_config('search_path', 'ag_catalog, public', false);

    -- Create the graph if missing
    SELECT graphid INTO graph_oid FROM ag_catalog.ag_graph WHERE name = 'serviceradar';
    IF graph_oid IS NULL THEN
        PERFORM ag_catalog.create_graph('serviceradar');
        SELECT graphid INTO graph_oid FROM ag_catalog.ag_graph WHERE name = 'serviceradar';
    END IF;

    -- Vertex labels
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'Device' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Device');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'Service' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Service');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'Collector' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Collector');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'Interface' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Interface');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'Capability' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Capability');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'CheckerDefinition' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'CheckerDefinition');
    END IF;

    -- Edge labels
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'HOSTS_SERVICE' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_elabel('serviceradar', 'HOSTS_SERVICE');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'RUNS_CHECKER' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_elabel('serviceradar', 'RUNS_CHECKER');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'TARGETS' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_elabel('serviceradar', 'TARGETS');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'HAS_INTERFACE' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_elabel('serviceradar', 'HAS_INTERFACE');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'CONNECTS_TO' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_elabel('serviceradar', 'CONNECTS_TO');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'PROVIDES_CAPABILITY' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_elabel('serviceradar', 'PROVIDES_CAPABILITY');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'REPORTED_BY' AND graph = graph_oid) THEN
        PERFORM ag_catalog.create_elabel('serviceradar', 'REPORTED_BY');
    END IF;

    -- Property indexes
    IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'ag_catalog'::regnamespace AND proname = 'create_property_index') THEN
        BEGIN
            PERFORM ag_catalog.create_property_index('serviceradar', 'Device', 'id');
        EXCEPTION WHEN duplicate_table OR duplicate_object THEN NULL;
        END;
        BEGIN
            PERFORM ag_catalog.create_property_index('serviceradar', 'Service', 'id');
        EXCEPTION WHEN duplicate_table OR duplicate_object THEN NULL;
        END;
        BEGIN
            PERFORM ag_catalog.create_property_index('serviceradar', 'Collector', 'id');
        EXCEPTION WHEN duplicate_table OR duplicate_object THEN NULL;
        END;
        BEGIN
            PERFORM ag_catalog.create_property_index('serviceradar', 'Interface', 'id');
        EXCEPTION WHEN duplicate_table OR duplicate_object THEN NULL;
        END;
    END IF;

    -- Grant AGE access to serviceradar role
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'serviceradar') THEN
        EXECUTE 'GRANT USAGE ON SCHEMA ag_catalog TO serviceradar';
        EXECUTE 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ag_catalog TO serviceradar';
        EXECUTE 'GRANT USAGE ON SCHEMA serviceradar TO serviceradar';
        EXECUTE 'GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA serviceradar TO serviceradar';
        EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA serviceradar GRANT ALL ON TABLES TO serviceradar';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'AGE graph setup skipped: %', SQLERRM;
END $$;

-- AGE sequence privileges
DO $$
DECLARE
    seq record;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'serviceradar') THEN
        RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'serviceradar') THEN
        RETURN;
    END IF;

    FOR seq IN
        SELECT schemaname, sequencename
        FROM pg_sequences
        WHERE schemaname = 'serviceradar'
    LOOP
        EXECUTE format(
            'GRANT USAGE, SELECT, UPDATE ON SEQUENCE %I.%I TO serviceradar',
            seq.schemaname, seq.sequencename
        );
    END LOOP;

    ALTER DEFAULT PRIVILEGES IN SCHEMA serviceradar
        GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO serviceradar;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Sequence grants skipped: %', SQLERRM;
END $$;

-- AGE device neighborhood function
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
    $cypher$, include_topology, collector_only, p_device_id, p_device_id);

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
        RETURN NULL;
END;
$$;
