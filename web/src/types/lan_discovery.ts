// src/types/lan_discovery.ts
// Re-typing some of the interfaces that were local to LANDiscoveryDashboard.tsx
// to centralize them and make them properly part of the ServiceDetails union.

export interface RawDevice {
    device_id?: string;
    hostname?: string;
    ip?: string; // raw ip address
    mac?: string; // raw mac address
    sys_descr?: string; // directly on device object
    sys_object_id?: string;
    sys_contact?: string;
    uptime?: number;
    discovery_source?: string;
    is_available?: boolean;
    last_seen?: string;
    metadata?: {
        discovery_id?: string;
        discovery_time?: string;
        [key: string]: unknown;
    };
    [key: string]: unknown;
}

export interface RawInterface {
    device_ip?: string;
    if_index?: number;
    if_name?: string;
    if_descr?: string;
    if_speed?: { value?: number } | number;
    if_phys_address?: string;
    if_admin_status?: number;
    if_oper_status?: number;
    if_type?: number;
    ip_addresses?: string[];
    metadata?: {
        discovery_id?: string;
        discovery_time?: string;
        if_type?: string;
        [key: string]: unknown;
    };
    [key: string]: unknown;
}

export interface RawNetworkTopologyNode { // Renamed to clearly be raw
    id: string;
    label: string;
    type?: string;
    ip?: string;
    [key: string]: unknown;
}

export interface RawNetworkTopologyEdge { // Renamed
    from: string;
    to: string;
    label?: string;
    [key: string]: unknown;
}

export interface RawNetworkTopology { // Renamed
    nodes?: RawNetworkTopologyNode[];
    edges?: RawNetworkTopologyEdge[];
    subnets?: string[];
    [key: string]: unknown;
}

export interface RawBackendLanDiscoveryData {
    devices?: RawDevice[];
    interfaces?: RawInterface[];
    topology?: RawNetworkTopology; // Use RawNetworkTopology
    last_discovery?: string;
    discovery_duration?: number;
    total_devices?: number;
    active_devices?: number;
    [key: string]: unknown;
}