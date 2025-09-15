-- OCSF Materialized Views Migration
-- These views automatically aggregate event data into entity state and observable indexes
-- Enables real-time updates from event streams to current state streams

-- Device State Aggregation
-- Populates ocsf_devices_current from device inventory events
DROP VIEW IF EXISTS ocsf_devices_aggregator_mv;
CREATE MATERIALIZED VIEW ocsf_devices_aggregator_mv AS
SELECT
    device_uid,
    time AS last_seen,
    time AS first_seen,

    -- Device Object Fields (take latest non-empty values)
    if(device_name != '', device_name, '') AS device_name,
    device_ip,
    device_mac,
    device_type_id,
    if(device_os_name != '', device_os_name, '') AS device_os_name,
    if(device_os_version != '', device_os_version, '') AS device_os_version,
    if(device_location != '', device_location, '') AS device_location,
    if(device_domain != '', device_domain, '') AS device_domain,

    -- Aggregated Discovery Data
    [discovery_source] AS discovery_sources,
    confidence_level / 4.0 AS confidence_score,  -- Convert 1-4 scale to 0.0-1.0
    1 AS discovery_count,

    -- ServiceRadar Fields
    agent_id,
    poller_id,
    activity_id IN (1, 2) AS is_available,  -- Create=1 or Update=2 means available
    time AS last_response_time,

    -- State Management
    CASE
        WHEN activity_id = 3 THEN 'deleted'
        WHEN activity_id = 1 THEN 'active'
        ELSE 'active'
    END AS status,
    CAST([] AS array(string)) AS tags,
    CAST([] AS array(string)) AS categories,

    -- Raw Data
    raw_data,
    enrichments,
    metadata,

    -- Observable Arrays
    observables_ip,
    observables_mac,
    observables_hostname,
    observables_domain,
    observables_resource_uid

FROM ocsf_device_inventory;

-- User State Aggregation
-- Populates ocsf_users_current from user inventory events
DROP VIEW IF EXISTS ocsf_users_aggregator_mv;
CREATE MATERIALIZED VIEW ocsf_users_aggregator_mv AS
SELECT
    user_uid,
    time AS last_seen,
    time AS first_seen,

    -- User Object Fields
    if(user_name != '', user_name, '') AS user_name,
    if(user_email != '', user_email, '') AS user_email,
    if(user_full_name != '', user_full_name, '') AS user_full_name,
    if(user_domain != '', user_domain, '') AS user_domain,
    user_type_id,
    if(user_credential_uid != '', user_credential_uid, '') AS user_credential_uid,

    -- Account Information
    if(account_name != '', account_name, '') AS account_name,
    account_type_id,
    if(account_uid != '', account_uid, '') AS account_uid,

    -- Aggregated Discovery Data
    [discovery_source] AS discovery_sources,
    confidence_level / 4.0 AS confidence_score,
    1 AS discovery_count,

    -- ServiceRadar Fields
    agent_id,
    poller_id,
    activity_id IN (1, 2) AS is_active,
    time AS last_login,

    -- State Management
    CASE
        WHEN activity_id = 3 THEN 'deleted'
        WHEN activity_id = 1 THEN 'active'
        ELSE 'active'
    END AS status,
    CAST([] AS array(string)) AS groups,
    CAST([] AS array(string)) AS permissions,

    -- Raw Data
    raw_data,
    metadata,

    -- Observable Arrays
    observables_username,
    observables_email,
    observables_hostname,
    observables_domain,
    observables_resource_uid

FROM ocsf_user_inventory;

-- Observable Index Population - Device IPs
-- Index IP addresses from device inventory
DROP VIEW IF EXISTS ocsf_observable_device_ips_mv;
CREATE MATERIALIZED VIEW ocsf_observable_device_ips_mv AS
SELECT
    'ip_address' AS observable_type,
    ip AS observable_value,
    lower(ip) AS observable_value_normalized,
    'device' AS entity_class,
    device_uid AS entity_uid,
    time AS entity_last_seen,
    'device.ip' AS entity_path,
    confidence_level / 4.0 AS confidence_score,
    discovery_source,
    time,
    agent_id,
    poller_id,

    -- Enrichments (would be populated by separate threat intel process)
    '' AS geo_country,
    '' AS geo_region,
    '' AS geo_city,
    0 AS asn_number,
    '' AS asn_org,
    0.0 AS threat_score,
    CAST([] AS array(string)) AS threat_categories,
    CAST([] AS array(string)) AS threat_sources,

    -- Categorization
    CASE
        WHEN starts_with(ip, '10.') OR starts_with(ip, '192.168.') OR starts_with(ip, '172.') THEN 'private'
        WHEN starts_with(ip, '127.') THEN 'loopback'
        ELSE 'public'
    END AS observable_category,
    CAST([] AS array(string)) AS tags,

    metadata

FROM ocsf_device_inventory
ARRAY JOIN device_ip AS ip
WHERE ip != '';

-- Observable Index Population - Device MACs
-- Index MAC addresses from device inventory
DROP VIEW IF EXISTS ocsf_observable_device_macs_mv;
CREATE MATERIALIZED VIEW ocsf_observable_device_macs_mv AS
SELECT
    'mac_address' AS observable_type,
    mac AS observable_value,
    lower(replaceAll(mac, ':', '')) AS observable_value_normalized,
    'device' AS entity_class,
    device_uid AS entity_uid,
    time AS entity_last_seen,
    'device.mac' AS entity_path,
    confidence_level / 4.0 AS confidence_score,
    discovery_source,
    time,
    agent_id,
    poller_id,

    -- Enrichments
    '' AS geo_country,
    '' AS geo_region,
    '' AS geo_city,
    0 AS asn_number,
    '' AS asn_org,
    0.0 AS threat_score,
    CAST([] AS array(string)) AS threat_categories,
    CAST([] AS array(string)) AS threat_sources,
    'hardware' AS observable_category,
    CAST([] AS array(string)) AS tags,
    metadata

FROM ocsf_device_inventory
ARRAY JOIN device_mac AS mac
WHERE mac != '';

-- Observable Index Population - Device Hostnames
-- Index hostnames from device inventory
DROP VIEW IF EXISTS ocsf_observable_device_hostnames_mv;
CREATE MATERIALIZED VIEW ocsf_observable_device_hostnames_mv AS
SELECT
    'hostname' AS observable_type,
    device_name AS observable_value,
    lower(device_name) AS observable_value_normalized,
    'device' AS entity_class,
    device_uid AS entity_uid,
    time AS entity_last_seen,
    'device.name' AS entity_path,
    confidence_level / 4.0 AS confidence_score,
    discovery_source,
    time,
    agent_id,
    poller_id,

    -- Enrichments
    '' AS geo_country,
    '' AS geo_region,
    '' AS geo_city,
    0 AS asn_number,
    '' AS asn_org,
    0.0 AS threat_score,
    CAST([] AS array(string)) AS threat_categories,
    CAST([] AS array(string)) AS threat_sources,
    'internal' AS observable_category,
    CAST([] AS array(string)) AS tags,
    metadata

FROM ocsf_device_inventory
WHERE device_name != '';

-- Observable Index Population - Network Activity Source IPs
-- Index source IPs from network activity events
DROP VIEW IF EXISTS ocsf_observable_netflow_src_ips_mv;
CREATE MATERIALIZED VIEW ocsf_observable_netflow_src_ips_mv AS
SELECT
    'ip_address' AS observable_type,
    src_endpoint_ip AS observable_value,
    lower(src_endpoint_ip) AS observable_value_normalized,
    'network_activity' AS entity_class,
    connection_uid AS entity_uid,
    time AS entity_last_seen,
    'src_endpoint.ip' AS entity_path,
    0.7 AS confidence_score,  -- Lower confidence for transient network data
    'netflow' AS discovery_source,
    time,
    agent_id,
    poller_id,

    -- Enrichments
    '' AS geo_country,
    '' AS geo_region,
    '' AS geo_city,
    0 AS asn_number,
    '' AS asn_org,
    0.0 AS threat_score,
    CAST([] AS array(string)) AS threat_categories,
    CAST([] AS array(string)) AS threat_sources,
    CASE
        WHEN starts_with(src_endpoint_ip, '10.') OR starts_with(src_endpoint_ip, '192.168.') OR starts_with(src_endpoint_ip, '172.') THEN 'private'
        WHEN starts_with(src_endpoint_ip, '127.') THEN 'loopback'
        ELSE 'public'
    END AS observable_category,
    CAST([] AS array(string)) AS tags,
    metadata

FROM ocsf_network_activity
WHERE src_endpoint_ip != '';

-- Observable Index Population - Network Activity Destination IPs
-- Index destination IPs from network activity events
DROP VIEW IF EXISTS ocsf_observable_netflow_dst_ips_mv;
CREATE MATERIALIZED VIEW ocsf_observable_netflow_dst_ips_mv AS
SELECT
    'ip_address' AS observable_type,
    dst_endpoint_ip AS observable_value,
    lower(dst_endpoint_ip) AS observable_value_normalized,
    'network_activity' AS entity_class,
    connection_uid AS entity_uid,
    time AS entity_last_seen,
    'dst_endpoint.ip' AS entity_path,
    0.7 AS confidence_score,
    'netflow' AS discovery_source,
    time,
    agent_id,
    poller_id,

    -- Enrichments
    '' AS geo_country,
    '' AS geo_region,
    '' AS geo_city,
    0 AS asn_number,
    '' AS asn_org,
    0.0 AS threat_score,
    CAST([] AS array(string)) AS threat_categories,
    CAST([] AS array(string)) AS threat_sources,
    CASE
        WHEN starts_with(dst_endpoint_ip, '10.') OR starts_with(dst_endpoint_ip, '192.168.') OR starts_with(dst_endpoint_ip, '172.') THEN 'private'
        WHEN starts_with(dst_endpoint_ip, '127.') THEN 'loopback'
        ELSE 'public'
    END AS observable_category,
    CAST([] AS array(string)) AS tags,
    metadata

FROM ocsf_network_activity
WHERE dst_endpoint_ip != '';

-- Observable Statistics Aggregation
-- Compute hourly statistics for observables
DROP VIEW IF EXISTS ocsf_observable_stats_mv;
CREATE MATERIALIZED VIEW ocsf_observable_stats_mv AS
SELECT
    observable_type,
    observable_value,

    -- Time Window (hourly buckets)
    to_start_of_hour(time) AS time_window_start,
    to_start_of_hour(time) + INTERVAL 1 HOUR AS time_window_end,

    -- Statistics
    uniq(entity_uid) AS entity_count,
    groupUniqArray(entity_class) AS entity_classes,
    groupUniqArray(discovery_source) AS discovery_sources,

    -- Activity Metrics
    min(time) AS first_seen,
    max(time) AS last_seen,
    count() AS occurrence_count,

    -- Confidence and Quality
    avg(confidence_score) AS avg_confidence_score,
    max(confidence_score) AS max_confidence_score,
    1.0 AS data_quality_score,  -- Will be computed by separate process

    -- Threat Intelligence (placeholder - populated by threat intel process)
    max(threat_score) AS max_threat_score,
    groupUniqArray(threat_categories) AS threat_categories,
    max(threat_score) > 0.5 AS is_flagged,

    -- Geographic Summary
    groupUniqArray(geo_country) AS countries,
    groupUniqArray(geo_region) AS regions,
    groupUniqArray(asn_org) AS asn_orgs,

    map() AS metadata

FROM ocsf_observable_index
GROUP BY
    observable_type,
    observable_value,
    to_start_of_hour(time);