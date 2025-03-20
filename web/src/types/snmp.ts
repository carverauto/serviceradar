// src/types/snmp.ts
export interface SnmpDataPoint {
    oid_name: string;
    timestamp: string;
    value: string | number;
    rate?: number;
}

export interface PortResult {
    port: number;
    available: boolean;
    service?: string;
}

export interface IcmpStatus {
    available: boolean;
    response_time?: number;
    packet_loss?: number;
    round_trip?: number;
}

export interface SweepHost {
    host: string;
    available: boolean;
    icmp_status?: IcmpStatus;
    port_results?: PortResult[];
    first_seen: string;
    last_seen: string;
}

export interface SweepPort {
    port: number;
    available: number;
}

export interface SweepDetails {
    network: string;
    total_hosts: number;
    available_hosts: number;
    last_sweep: number;
    hosts: SweepHost[];
    ports: SweepPort[];
}