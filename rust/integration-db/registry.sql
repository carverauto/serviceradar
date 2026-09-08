-- Version 1. All registry access and advisory locks use database postgres.
-- Generation lock: (1397904460, signed int32 of digest[0:8]).
-- Capacity/bootstrap lock: (1397904461, 0). When both needed: generation first.
-- Builders retain their generation SESSION lock across all DDL and publication.
-- Fresh initialization only, inside a transaction after proving this schema absent.
-- Existing registries must be validated without running any of this DDL.
CREATE SCHEMA sr_template_registry;
REVOKE ALL ON SCHEMA sr_template_registry FROM PUBLIC;
CREATE TABLE sr_template_registry.metadata (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    version integer NOT NULL CHECK (version = 1)
);
INSERT INTO sr_template_registry.metadata(singleton, version) VALUES (true, 1);
CREATE SEQUENCE sr_template_registry.builder_tokens;
CREATE TABLE sr_template_registry.generations (
    digest text PRIMARY KEY CHECK (digest ~ '^[0-9a-f]{64}$'),
    manifest text NOT NULL,
    database_name text UNIQUE NOT NULL CHECK (database_name = 'sr_tpl_' || left(digest, 48)),
    builder_token bigint NOT NULL CHECK (builder_token > 0),
    state text NOT NULL CHECK (state IN ('building', 'ready')),
    server_major integer NOT NULL CHECK (server_major > 0),
    extensions text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    last_used_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE sr_template_registry.leases (
    digest text NOT NULL REFERENCES sr_template_registry.generations(digest) ON DELETE CASCADE,
    lease_id text NOT NULL CHECK (length(lease_id) BETWEEN 1 AND 128),
    expires_at timestamptz NOT NULL,
    PRIMARY KEY (digest, lease_id)
);
