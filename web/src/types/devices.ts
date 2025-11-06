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

export interface CapabilitySnapshot {
    capability: string;
    service_id?: string;
    service_type?: string;
    state?: string;
    enabled?: boolean;
    last_checked?: string;
    last_success?: string;
    last_failure?: string;
    failure_reason?: string;
    metadata?: Record<string, unknown>;
    recorded_by?: string;
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
    capability_snapshots?: CapabilitySnapshot[];
}
export interface Pagination {
    next_cursor?: string;
    prev_cursor?: string;
    limit?: number;
    offset?: number;
}
export interface DevicesApiResponse {
    results: Device[];
    pagination: Pagination;
    error?: string;
}

export interface DeviceSearchRequestPayload {
    query: string;
    mode?: string;
    filters?: Record<string, string>;
    pagination?: {
      limit?: number;
      offset?: number;
      cursor?: string;
      direction?: "next" | "prev";
    };
}

export interface DeviceSearchApiResponse {
    engine: string;
    results: Device[];
    pagination?: Pagination;
    diagnostics?: Record<string, unknown>;
    raw_results?: Array<Record<string, unknown>>;
    error?: string;
}
