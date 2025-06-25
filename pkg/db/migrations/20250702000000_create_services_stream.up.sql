-- Creates a stream to store the latest known services from pollers
CREATE STREAM IF NOT EXISTS services (
    poller_id string,
    service_name string,
    service_type string,
    agent_id string,
    timestamp DateTime64(3) DEFAULT now64(3)
) PRIMARY KEY (poller_id, service_name)
SETTINGS mode='versioned_kv', version_column='_tp_time';
