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

// src/types/types.ts
import { SweepDetails } from './snmp';

// Generic ServiceDetails for services like ICMP
export interface GenericServiceDetails {
  response_time?: number;
  packet_loss?: number;
  available?: boolean;
  round_trip?: number;
  last_update?: string;
  [key: string]: unknown;
}

// SNMP-specific details
export interface SnmpDeviceDetails {
  available?: boolean;
  last_poll?: string;
  oid_status?: {
    [key: string]: {
      last_value?: number;
      last_update?: string;
      error_count?: number;
    };
  };
}

export interface SnmpDetails {
  [deviceName: string]: SnmpDeviceDetails;
}

// Rperf-specific details (array of results)
export interface RperfResult {
  error?: string | null;
  success?: boolean;
  summary?: {
    bits_per_second?: number;
    bytes_received?: number;
    bytes_sent?: number;
    duration?: number;
    jitter_ms?: number;
    loss_percent?: number;
    packets_lost?: number;
    packets_received?: number;
    packets_sent?: number;
  };
  target?: string;
}

export interface RperfDetails {
  results?: RperfResult[];
  Results?: RperfResult[];
  timestamp?: string;
}

// Union type for ServiceDetails
// export type ServiceDetails = GenericServiceDetails | SweepDetails | SnmpDetails | RperfDetails | Record<string, any>;
// Union type for ServiceDetails
export type ServiceDetails =
    | GenericServiceDetails
    | SweepDetails
    | SnmpDetails
    | RperfDetails
    | { [key: string]: string | number | boolean | null | undefined };

export type { SweepDetails } from './snmp';

export interface Service {
  group: string;
  status: string;
  name: string;
  type: string;
  available: boolean;
  details?: ServiceDetails | string;
}

export interface Poller {
  poller_id: string;
  is_healthy: boolean;
  last_update: string;
  services?: Service[];
}

export interface ServiceStats {
  total_services: number;
  offline_services: number;
  avg_response_time: number;
}


export interface ServiceMetric {
  service_name: string;
  timestamp: string; // ISO string format
  response_time: number;
  response_time_ms?: number;
  [key: string]: unknown; // Allow additional fields if needed
}

export interface SystemStatus {
  total_pollers: number;
  healthy_pollers: number;
  last_update: string;
  service_stats: ServiceStats;
}