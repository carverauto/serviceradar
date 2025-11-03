-- =================================================================
-- Service Registry - Extend Existing Streams
-- =================================================================
-- This migration extends the existing pollers stream and creates
-- similar versioned_kv streams for agents and checkers instead of
-- creating entirely new tables.
--
-- Philosophy: Reuse existing infrastructure, extend with registry fields
-- =================================================================

-- =================================================================
-- Step 1: Extend existing pollers stream with registry fields
-- =================================================================

-- Drop and recreate pollers stream with extended schema
-- Note: In production, you'd want to migrate data, but for now we drop/recreate
DROP STREAM IF EXISTS pollers;

CREATE STREAM IF NOT EXISTS pollers (
    -- Core identity
    poller_id string,

    -- Onboarding/registration metadata
    component_id string DEFAULT '',
    registration_source string DEFAULT 'implicit',  -- 'edge_onboarding', 'k8s_spiffe', 'config', 'implicit'
    status string DEFAULT 'active',  -- 'pending', 'active', 'inactive', 'revoked', 'deleted'

    -- SPIFFE identity
    spiffe_identity string DEFAULT '',

    -- Timestamps
    first_registered datetime64(3) DEFAULT now64(),
    first_seen nullable(datetime64(3)),
    last_seen datetime64(3) DEFAULT now64(),

    -- Metadata
    metadata string DEFAULT '{}',  -- JSON
    created_by string DEFAULT 'system',

    -- Health (existing field, kept for compatibility)
    is_healthy bool DEFAULT true,

    -- Stats (denormalized for performance)
    agent_count uint32 DEFAULT 0,
    checker_count uint32 DEFAULT 0

) PRIMARY KEY (poller_id)
  SETTINGS mode='versioned_kv', version_column='_tp_time';

-- NO TTL! We manage lifecycle through status field instead

-- =================================================================
-- Step 2: Create agents stream (similar to pollers)
-- =================================================================

CREATE STREAM IF NOT EXISTS agents (
    -- Core identity
    agent_id string,
    poller_id string,  -- Parent poller (required)

    -- Onboarding/registration metadata
    component_id string DEFAULT '',
    registration_source string DEFAULT 'implicit',
    status string DEFAULT 'active',  -- 'pending', 'active', 'inactive', 'revoked', 'deleted'

    -- SPIFFE identity
    spiffe_identity string DEFAULT '',

    -- Timestamps
    first_registered datetime64(3) DEFAULT now64(),
    first_seen nullable(datetime64(3)),
    last_seen datetime64(3) DEFAULT now64(),

    -- Metadata
    metadata string DEFAULT '{}',
    created_by string DEFAULT 'system',

    -- Stats
    checker_count uint32 DEFAULT 0

) PRIMARY KEY (agent_id)
  SETTINGS mode='versioned_kv', version_column='_tp_time';

-- NO TTL! Lifecycle managed through status field

-- =================================================================
-- Step 3: Create checkers stream
-- =================================================================

CREATE STREAM IF NOT EXISTS checkers (
    -- Core identity
    checker_id string,
    agent_id string,   -- Parent agent (required)
    poller_id string,  -- Grandparent poller (denormalized for queries)
    checker_kind string,  -- 'snmp', 'sysmon', 'rperf', etc.

    -- Onboarding/registration metadata
    component_id string DEFAULT '',
    registration_source string DEFAULT 'implicit',
    status string DEFAULT 'active',  -- 'pending', 'active', 'inactive', 'revoked', 'deleted'

    -- SPIFFE identity
    spiffe_identity string DEFAULT '',

    -- Timestamps
    first_registered datetime64(3) DEFAULT now64(),
    first_seen nullable(datetime64(3)),
    last_seen datetime64(3) DEFAULT now64(),

    -- Metadata
    metadata string DEFAULT '{}',
    created_by string DEFAULT 'system'

) PRIMARY KEY (checker_id)
  SETTINGS mode='versioned_kv', version_column='_tp_time';

-- NO TTL! Lifecycle managed through status field

-- =================================================================
-- Step 4: Create audit stream for registration events
-- =================================================================

CREATE STREAM IF NOT EXISTS service_registration_events (
    event_id string,
    event_type string,  -- 'registered', 'activated', 'deactivated', 'revoked', 'deleted'
    service_id string,
    service_type string,  -- 'poller', 'agent', 'checker'
    parent_id string DEFAULT '',
    registration_source string,
    actor string,
    timestamp datetime64(3) DEFAULT now64(),
    metadata string DEFAULT '{}'

) ENGINE = Stream(1, 1, rand())
PARTITION BY to_start_of_day(timestamp)
ORDER BY (timestamp, service_id)
TTL to_start_of_day(coalesce(timestamp, _tp_time)) + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;

-- =================================================================
-- Migration Notes
-- =================================================================
--
-- BREAKING CHANGES:
-- - pollers stream schema changed (added many fields)
-- - Existing poller data will be lost on DROP
--
-- MIGRATION PATH:
-- 1. If you have critical pollers data, export it first:
--    SELECT * FROM pollers FINAL INTO OUTFILE 'pollers_backup.csv'
--
-- 2. Run this migration
--
-- 3. Re-register pollers via:
--    - Heartbeats (implicit registration with defaults)
--    - Edge onboarding (explicit registration with metadata)
--    - Manual INSERT for static pollers
--
-- BACKWARD COMPATIBILITY:
-- - services stream unchanged (heartbeat data still works)
-- - New agent/checker streams won't break existing code
-- - Old code querying pollers will get new schema (should be compatible for basic fields)
--
-- TTL STRATEGY:
-- - Registry streams (pollers/agents/checkers): NO TTL
--   Growth controlled by lifecycle status + manual deletion + purge jobs
-- - Audit events: 90-day TTL (compliance requirement)
-- - Existing services/service_status streams: Keep 3-day TTL (unchanged)
--
-- DELETION STRATEGY:
-- - Soft delete: Set status='deleted' (retains record for audit)
-- - Hard delete: Use DELETE FROM pollers WHERE poller_id = ? (permanent removal)
-- - Automated purge: Background job deletes services with status IN ('inactive', 'revoked', 'deleted')
--   that haven't updated in > retention_period (default: 90 days)
-- - Active/pending services cannot be deleted (must mark inactive/revoked first)
-- - All deletions emit audit events before removal (90-day retention)
--
-- RETENTION RECOMMENDATIONS:
-- - Active services: Never auto-deleted
-- - Pending services: 30 days (if never activated)
-- - Inactive services: 90 days after last heartbeat
-- - Revoked services: 90 days after revocation
-- - Deleted services: 7 days grace period before hard delete
--
