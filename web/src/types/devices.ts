// src/types/devices.ts
export interface DeviceAliasRecord {
    id?: string;
    ip?: string;
    last_seen_at?: string;
}

export interface DeviceAliasHistory {
    last_seen_at?: string;
    collector_ip?: string;
    current_service_id?: string;
    current_ip?: string;
    services?: DeviceAliasRecord[];
    ips?: DeviceAliasRecord[];
}

export interface CollectorCapabilities {
    has_collector?: boolean;
    supports_icmp?: boolean;
    supports_snmp?: boolean;
    supports_sysmon?: boolean;
    capabilities?: string[];
    agent_id?: string;
    poller_id?: string;
    service_name?: string;
    last_seen?: string;
}

export interface Device {
    _tp_time: string;
    agent_id: string;
    device_id: string;
    discovery_sources: string[];
    first_seen: string;
    hostname: string | null;
    ip: string;
    is_available: boolean;
    last_seen: string;
    mac: string | null;
    metadata: Record<string, unknown>;
    poller_id: string;
    sys_descr?: string;
    alias_history?: DeviceAliasHistory;
    collector_capabilities?: CollectorCapabilities;
    metrics_summary?: Record<string, boolean>;
}
export interface Pagination {
    next_cursor?: string;
    prev_cursor?: string;
    limit?: number;
}
export interface DevicesApiResponse {
    results: Device[];
    pagination: Pagination;
    error?: string;
}
