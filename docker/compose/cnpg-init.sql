-- Ensure extensions exist in the default database
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS age;

-- Role needed by SPIRE-related migrations and grants
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spire') THEN
        CREATE ROLE spire LOGIN PASSWORD 'spire';
    END IF;
END
$$;

-- Ensure the platform schema exists and is owned by the app role.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'serviceradar') THEN
        CREATE ROLE serviceradar LOGIN PASSWORD 'serviceradar';
    END IF;
END
$$;

CREATE SCHEMA IF NOT EXISTS platform AUTHORIZATION serviceradar;

-- Set search_path to platform first so app migrations land in the platform schema.
ALTER DATABASE serviceradar SET search_path TO platform, ag_catalog;
ALTER ROLE serviceradar SET search_path TO platform, ag_catalog;

-- Ensure Oban tables/sequences are owned by the app role if they already exist.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'serviceradar') THEN
        IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'platform') THEN
            EXECUTE 'ALTER TABLE IF EXISTS platform.oban_jobs OWNER TO serviceradar';
            EXECUTE 'ALTER TABLE IF EXISTS platform.oban_peers OWNER TO serviceradar';
            EXECUTE 'ALTER SEQUENCE IF EXISTS platform.oban_jobs_id_seq OWNER TO serviceradar';
        END IF;
    END IF;
END
$$;
