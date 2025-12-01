-- Bootstrap Apache AGE graph for ServiceRadar relationships.
-- Idempotently ensures the AGE extension, graph, labels, and useful defaults exist.

-- Enable AGE if not already present.
CREATE EXTENSION IF NOT EXISTS age;

-- Apply database-level defaults so new sessions see AGE objects without per-connection setup.
DO $$
BEGIN
    EXECUTE format('ALTER DATABASE %I SET search_path = ag_catalog, "$user", public', current_database());
    EXECUTE format('ALTER DATABASE %I SET graph_path = serviceradar', current_database());
END $$;

-- Ensure the current session can use AGE objects for the remaining statements.
SET search_path = ag_catalog, "$user", public;
SELECT set_config('graph_path', 'serviceradar', false);

-- Create the graph if missing.
DO $$
DECLARE
    graph_oid oid;
BEGIN
    SELECT oid INTO graph_oid FROM ag_catalog.ag_graph WHERE name = 'serviceradar';
    IF graph_oid IS NULL THEN
        PERFORM ag_catalog.create_graph('serviceradar');
        SELECT oid INTO graph_oid FROM ag_catalog.ag_graph WHERE name = 'serviceradar';
    END IF;

    -- Vertex labels (devices, services, collectors, interfaces, capabilities, checker defs).
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

    -- Edge labels for relationships.
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
END $$;

-- Create property indexes on canonical IDs when supported by AGE.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'ag_catalog'::regnamespace AND proname = 'create_property_index') THEN
        BEGIN
            PERFORM ag_catalog.create_property_index('serviceradar', 'Device', 'id');
        EXCEPTION
            WHEN duplicate_table THEN NULL;
            WHEN duplicate_object THEN NULL;
        END;
        BEGIN
            PERFORM ag_catalog.create_property_index('serviceradar', 'Service', 'id');
        EXCEPTION
            WHEN duplicate_table THEN NULL;
            WHEN duplicate_object THEN NULL;
        END;
        BEGIN
            PERFORM ag_catalog.create_property_index('serviceradar', 'Collector', 'id');
        EXCEPTION
            WHEN duplicate_table THEN NULL;
            WHEN duplicate_object THEN NULL;
        END;
        BEGIN
            PERFORM ag_catalog.create_property_index('serviceradar', 'Interface', 'id');
        EXCEPTION
            WHEN duplicate_table THEN NULL;
            WHEN duplicate_object THEN NULL;
        END;
    END IF;
END $$;
