/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

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