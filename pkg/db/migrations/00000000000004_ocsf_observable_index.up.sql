-- OCSF Observable Index Stream Migration
-- Fast lookup table for cross-entity searches using observable values
-- Enables OCSF-aligned queries: observable:ip_address value:192.168.1.1

-- Observable Index Stream
-- Maps observable values (IPs, MACs, CVEs, etc.) to entities that contain them
CREATE STREAM ocsf_observable_index (
    -- Observable Identification
    observable_type string,               -- 'ip_address', 'mac_address', 'hostname', 'cve', etc.
    observable_value string,              -- The actual observable value
    observable_value_normalized string,   -- Normalized form (lowercase, no special chars)

    -- Entity Reference
    entity_class string,                  -- 'device', 'user', 'vulnerability', 'service', 'network_activity'
    entity_uid string,                    -- Reference to the entity containing this observable
    entity_last_seen DateTime64(3) DEFAULT now64(),

    -- Observable Context
    entity_path string DEFAULT '',        -- Path within entity (e.g., 'device.ip[0]', 'src_endpoint.ip')
    confidence_score float32 DEFAULT 1.0, -- How confident we are in this mapping (0.0-1.0)
    discovery_source string DEFAULT '',   -- Where this observable mapping came from

    -- Metadata
    time DateTime64(3) DEFAULT now64(),   -- When this mapping was created/updated
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',

    -- Observable Enrichments
    geo_country string DEFAULT '',        -- For IP addresses
    geo_region string DEFAULT '',
    geo_city string DEFAULT '',
    asn_number int32 DEFAULT 0,           -- Autonomous System Number
    asn_org string DEFAULT '',            -- ASN Organization

    -- Threat Intelligence
    threat_score float32 DEFAULT 0.0,     -- Threat intelligence score (0.0-1.0)
    threat_categories array(string) DEFAULT [], -- malware, phishing, botnet, etc.
    threat_sources array(string) DEFAULT [],    -- Sources that flagged this observable

    -- Categorization
    observable_category string DEFAULT '', -- internal, external, public, private, etc.
    tags array(string) DEFAULT [],        -- User-defined tags

    -- Raw Data
    metadata map(string, string) DEFAULT map()

) ENGINE = Stream(1, 1, rand())
PARTITION BY (observable_type, farmHash64(observable_value))  -- Distribute by type and value
ORDER BY (observable_type, observable_value, entity_last_seen)
TTL to_start_of_day(entity_last_seen) + INTERVAL 30 DAY
SETTINGS index_granularity = 8192;

-- Observable Statistics Stream
-- Track frequency and relationships of observables over time
CREATE STREAM ocsf_observable_statistics (
    -- Observable Identity
    observable_type string,
    observable_value string,

    -- Time Window
    window_start DateTime64(3),
    window_end DateTime64(3),

    -- Statistics
    entity_count int32 DEFAULT 0,         -- Number of entities containing this observable
    entity_classes array(string) DEFAULT [], -- Types of entities (device, user, etc.)
    discovery_sources array(string) DEFAULT [], -- Sources that reported this observable

    -- Activity Metrics
    first_seen DateTime64(3) DEFAULT now64(),
    last_seen DateTime64(3) DEFAULT now64(),
    occurrence_count int32 DEFAULT 0,      -- How many times we've seen this observable

    -- Confidence and Quality
    avg_confidence_score float32 DEFAULT 0.0,
    max_confidence_score float32 DEFAULT 0.0,
    data_quality_score float32 DEFAULT 1.0,  -- Based on consistency across sources

    -- Threat Intelligence Summary
    max_threat_score float32 DEFAULT 0.0,
    threat_categories array(string) DEFAULT [],
    is_flagged bool DEFAULT false,

    -- Geographic Summary (for IPs)
    countries array(string) DEFAULT [],
    regions array(string) DEFAULT [],
    asn_orgs array(string) DEFAULT [],

    -- Metadata
    metadata map(string, string) DEFAULT map()

) ENGINE = Stream(1, 1, rand())
PARTITION BY (observable_type, int_div(to_unix_timestamp(window_start), 3600))
ORDER BY (observable_type, observable_value, window_start)
TTL to_start_of_day(window_start) + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;

-- Entity Relationship Stream
-- Track relationships between entities discovered through shared observables
CREATE STREAM ocsf_entity_relationships (
    -- Relationship Identity
    relationship_uid string,              -- Unique identifier for this relationship
    relationship_type string,             -- 'shares_ip', 'shares_network', 'communicates_with', etc.

    -- Source Entity
    source_entity_class string,           -- device, user, service, etc.
    source_entity_uid string,
    source_entity_name string DEFAULT '',

    -- Target Entity
    target_entity_class string,
    target_entity_uid string,
    target_entity_name string DEFAULT '',

    -- Relationship Details
    shared_observables array(string) DEFAULT [],  -- Observable values that link these entities
    observable_types array(string) DEFAULT [],    -- Types of shared observables
    confidence_score float32 DEFAULT 0.0,         -- Confidence in this relationship

    -- Temporal Information
    time DateTime64(3) DEFAULT now64(),
    first_observed DateTime64(3) DEFAULT now64(),
    last_observed DateTime64(3) DEFAULT now64(),
    observation_count int32 DEFAULT 1,

    -- Context
    discovery_source string DEFAULT '',
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',

    -- Relationship Strength
    interaction_frequency string DEFAULT 'low',  -- low, medium, high
    relationship_strength float32 DEFAULT 0.0,   -- 0.0-1.0 based on frequency and confidence

    -- Metadata
    metadata map(string, string) DEFAULT map(),
    tags array(string) DEFAULT []

) ENGINE = Stream(1, 1, rand())
PARTITION BY farmHash64(concat(source_entity_uid, target_entity_uid))
ORDER BY (relationship_type, source_entity_uid, target_entity_uid, time)
TTL to_start_of_day(time) + INTERVAL 30 DAY
SETTINGS index_granularity = 8192;

-- Search Query Performance Stream
-- Track query patterns and performance for observable-based searches
CREATE STREAM ocsf_search_performance (
    -- Query Identity
    query_id string DEFAULT '',
    query_hash string,                    -- Hash of normalized query
    query_text string,                   -- Original query

    -- Query Classification
    query_type string DEFAULT '',        -- 'observable_search', 'entity_search', 'federated', etc.
    entity_classes array(string) DEFAULT [], -- Entities being searched
    observable_types array(string) DEFAULT [], -- Observable types in query

    -- Performance Metrics
    time DateTime64(3) DEFAULT now64(),
    execution_time_ms int32 DEFAULT 0,
    result_count int32 DEFAULT 0,
    cache_hit bool DEFAULT false,

    -- Query Optimization
    optimization_applied array(string) DEFAULT [], -- Optimizations used
    index_usage array(string) DEFAULT [],          -- Indexes utilized
    estimated_cost float32 DEFAULT 0.0,

    -- User Context
    user_id string DEFAULT '',
    session_id string DEFAULT '',
    client_ip string DEFAULT '',

    -- Metadata
    metadata map(string, string) DEFAULT map()

) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(time), 3600)
ORDER BY (time, query_hash)
TTL to_start_of_day(time) + INTERVAL 7 DAY
SETTINGS index_granularity = 8192;
