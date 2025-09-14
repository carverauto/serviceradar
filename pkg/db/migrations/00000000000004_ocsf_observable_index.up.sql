-- OCSF Observable Index Stream Migration
-- Fast lookup table for cross-entity searches using observable values
-- Enables OCSF-aligned queries: observable:ip_address value:192.168.1.1

-- Observable Index Stream
-- Maps observable values (IPs, MACs, CVEs, etc.) to entities that contain them
CREATE STREAM ocsf_observable_index (
    -- Observable Identification
    observable_type String,               -- 'ip_address', 'mac_address', 'hostname', 'cve', etc.
    observable_value String,              -- The actual observable value
    observable_value_normalized String,   -- Normalized form (lowercase, no special chars)

    -- Entity Reference
    entity_class String,                  -- 'device', 'user', 'vulnerability', 'service', 'network_activity'
    entity_uid String,                    -- Reference to the entity containing this observable
    entity_last_seen DateTime64(3) DEFAULT now64(),

    -- Observable Context
    entity_path String DEFAULT '',        -- Path within entity (e.g., 'device.ip[0]', 'src_endpoint.ip')
    confidence_score Float32 DEFAULT 1.0, -- How confident we are in this mapping (0.0-1.0)
    discovery_source String DEFAULT '',   -- Where this observable mapping came from

    -- Metadata
    time DateTime64(3) DEFAULT now64(),   -- When this mapping was created/updated
    agent_id String DEFAULT '',
    poller_id String DEFAULT '',

    -- Observable Enrichments
    geo_country String DEFAULT '',        -- For IP addresses
    geo_region String DEFAULT '',
    geo_city String DEFAULT '',
    asn_number Int32 DEFAULT 0,           -- Autonomous System Number
    asn_org String DEFAULT '',            -- ASN Organization

    -- Threat Intelligence
    threat_score Float32 DEFAULT 0.0,     -- Threat intelligence score (0.0-1.0)
    threat_categories Array(String) DEFAULT [], -- malware, phishing, botnet, etc.
    threat_sources Array(String) DEFAULT [],    -- Sources that flagged this observable

    -- Categorization
    observable_category String DEFAULT '', -- internal, external, public, private, etc.
    tags Array(String) DEFAULT [],        -- User-defined tags

    -- Raw Data
    metadata Map(String, String) DEFAULT map()

) ENGINE = Stream(1, 1, rand())
PARTITION BY (observable_type, farmHash64(observable_value))  -- Distribute by type and value
ORDER BY (observable_type, observable_value, entity_last_seen)
TTL to_start_of_day(entity_last_seen) + INTERVAL 30 DAY
SETTINGS index_granularity = 8192;

-- Observable Statistics Stream
-- Track frequency and relationships of observables over time
CREATE STREAM ocsf_observable_statistics (
    -- Observable Identity
    observable_type String,
    observable_value String,

    -- Time Window
    window_start DateTime64(3),
    window_end DateTime64(3),

    -- Statistics
    entity_count Int32 DEFAULT 0,         -- Number of entities containing this observable
    entity_classes Array(String) DEFAULT [], -- Types of entities (device, user, etc.)
    discovery_sources Array(String) DEFAULT [], -- Sources that reported this observable

    -- Activity Metrics
    first_seen DateTime64(3) DEFAULT now64(),
    last_seen DateTime64(3) DEFAULT now64(),
    occurrence_count Int32 DEFAULT 0,      -- How many times we've seen this observable

    -- Confidence and Quality
    avg_confidence_score Float32 DEFAULT 0.0,
    max_confidence_score Float32 DEFAULT 0.0,
    data_quality_score Float32 DEFAULT 1.0,  -- Based on consistency across sources

    -- Threat Intelligence Summary
    max_threat_score Float32 DEFAULT 0.0,
    threat_categories Array(String) DEFAULT [],
    is_flagged Bool DEFAULT false,

    -- Geographic Summary (for IPs)
    countries Array(String) DEFAULT [],
    regions Array(String) DEFAULT [],
    asn_orgs Array(String) DEFAULT [],

    -- Metadata
    metadata Map(String, String) DEFAULT map()

) ENGINE = Stream(1, 1, rand())
PARTITION BY (observable_type, int_div(to_unix_timestamp(window_start), 3600))
ORDER BY (observable_type, observable_value, window_start)
TTL to_start_of_day(window_start) + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;

-- Entity Relationship Stream
-- Track relationships between entities discovered through shared observables
CREATE STREAM ocsf_entity_relationships (
    -- Relationship Identity
    relationship_uid String,              -- Unique identifier for this relationship
    relationship_type String,             -- 'shares_ip', 'shares_network', 'communicates_with', etc.

    -- Source Entity
    source_entity_class String,           -- device, user, service, etc.
    source_entity_uid String,
    source_entity_name String DEFAULT '',

    -- Target Entity
    target_entity_class String,
    target_entity_uid String,
    target_entity_name String DEFAULT '',

    -- Relationship Details
    shared_observables Array(String) DEFAULT [],  -- Observable values that link these entities
    observable_types Array(String) DEFAULT [],    -- Types of shared observables
    confidence_score Float32 DEFAULT 0.0,         -- Confidence in this relationship

    -- Temporal Information
    time DateTime64(3) DEFAULT now64(),
    first_observed DateTime64(3) DEFAULT now64(),
    last_observed DateTime64(3) DEFAULT now64(),
    observation_count Int32 DEFAULT 1,

    -- Context
    discovery_source String DEFAULT '',
    agent_id String DEFAULT '',
    poller_id String DEFAULT '',

    -- Relationship Strength
    interaction_frequency String DEFAULT 'low',  -- low, medium, high
    relationship_strength Float32 DEFAULT 0.0,   -- 0.0-1.0 based on frequency and confidence

    -- Metadata
    metadata Map(String, String) DEFAULT map(),
    tags Array(String) DEFAULT []

) ENGINE = Stream(1, 1, rand())
PARTITION BY farmHash64(concat(source_entity_uid, target_entity_uid))
ORDER BY (relationship_type, source_entity_uid, target_entity_uid, time)
TTL to_start_of_day(time) + INTERVAL 30 DAY
SETTINGS index_granularity = 8192;

-- Search Query Performance Stream
-- Track query patterns and performance for observable-based searches
CREATE STREAM ocsf_search_performance (
    -- Query Identity
    query_id String DEFAULT '',
    query_hash String,                    -- Hash of normalized query
    query_text String,                   -- Original query

    -- Query Classification
    query_type String DEFAULT '',        -- 'observable_search', 'entity_search', 'federated', etc.
    entity_classes Array(String) DEFAULT [], -- Entities being searched
    observable_types Array(String) DEFAULT [], -- Observable types in query

    -- Performance Metrics
    time DateTime64(3) DEFAULT now64(),
    execution_time_ms Int32 DEFAULT 0,
    result_count Int32 DEFAULT 0,
    cache_hit Bool DEFAULT false,

    -- Query Optimization
    optimization_applied Array(String) DEFAULT [], -- Optimizations used
    index_usage Array(String) DEFAULT [],          -- Indexes utilized
    estimated_cost Float32 DEFAULT 0.0,

    -- User Context
    user_id String DEFAULT '',
    session_id String DEFAULT '',
    client_ip String DEFAULT '',

    -- Metadata
    metadata Map(String, String) DEFAULT map()

) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(time), 3600)
ORDER BY (time, query_hash)
TTL to_start_of_day(time) + INTERVAL 7 DAY
SETTINGS index_granularity = 8192;
