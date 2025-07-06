// src/types/devices.ts
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
