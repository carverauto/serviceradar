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

-- Set search_path to include ag_catalog for AGE graph tables used by SRQL
ALTER DATABASE serviceradar SET search_path TO ag_catalog, serviceradar, public;
