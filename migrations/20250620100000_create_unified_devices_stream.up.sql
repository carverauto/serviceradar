CREATE STREAM IF NOT EXISTS unified_devices (
    device_id string,
    ip string,
    poller_id string,
    hostname Nullable(string),
    mac Nullable(string),
    discovery_source string,
    is_available boolean,
    first_seen DateTime64(3),
    last_seen DateTime64(3),
    metadata Map(string, string),
    agent_id string
)
PRIMARY KEY (device_id)
SETTINGS mode='versioned_kv', version_column='_tp_time';
