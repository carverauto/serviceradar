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
import { RawBackendLanDiscoveryData } from './lan_discovery';

// Generic ServiceDetails for services like ICMP
export interface GenericServiceDetails {
  response_time?: number;
  packet_loss?: number;
  available?: boolean;
  round_trip?: number;
  last_update?: string;
  [key: string]: unknown; // Allow for other fields not explicitly listed
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
      [key: string]: unknown; // Allow for other fields in oid_status
    };
  };
  [key: string]: unknown; // Allow for other fields in SnmpDeviceDetails
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
    [key: string]: unknown; // Allow for other fields in summary
  };
  target?: string;
  [key: string]: unknown; // Allow for other fields in RperfDetails
}

export interface RperfDetails {
  results?: RperfResult[];
  Results?: RperfResult[]; // Backend might return with uppercase 'R'
  timestamp?: string;
  [key: string]: unknown; // Allow for other fields in RperfDetails
}

// Union type for ServiceDetails
// This covers various types of 'details' payloads a service might have.
export type ServiceDetails =
    | GenericServiceDetails
    | SweepDetails
    | SnmpDetails
    | RperfDetails
    | RawBackendLanDiscoveryData
    | { [key: string]: string | number | boolean | null | undefined | object | unknown[] }; // Broad type for general JSON objects

// Core Service interface: Represents the essential attributes of a service.
// This is suitable for general display or when only core properties are needed.
export interface Service {
  id?: string;
  group: string; // The logical group this service belongs to
  status: string; // The service's current operational status (e.g., "OK", "ERROR", "UP", "DOWN")
  name: string; // Human-readable name of the service (e.g., "Ping Service")
  type: string; // Type of service (e.g., "icmp", "snmp", "grpc", "sweep", "network_discovery")
  available: boolean; // Indicates current operational availability (derived from status)
  details?: ServiceDetails | string; // Details can be a parsed object or a raw JSON string
  [key: string]: unknown; // Allows for additional, non-standard fields that might come from the backend
}

// ServiceEntry represents a record from the services inventory stream.
export interface ServiceEntry {
  _tp_time?: string;
  agent_id: string;
  poller_id: string;
  service_name: string;
  service_type: string;
  timestamp: string;
}

// ServicePayload interface: Represents the full structure of a service object
// as typically returned by the backend API (e.g., from /api/pollers/{pollerId}/services/{serviceName}).
// It extends the core Service interface with API-specific metadata that is usually part of the top-level API response.
export interface ServicePayload extends Service {
  poller_id: string; // The ID of the poller that owns this service
  service_name: string; // The programmatic name of the service (often unique within a poller, used in API paths)
  last_update: string; // The ISO 8601 timestamp string of the last time this specific service's status was updated
}

export interface Poller {
  poller_id: string;
  is_healthy: boolean;
  last_update: string;
  services?: Service[]; // Services within a poller might be the basic Service interface, not full ServicePayloads
}

export interface Partition {
  partition: string;
}

export interface ServiceStats {
  total_services: number;
  offline_services: number;
  avg_response_time: number;
}

export interface ServiceMetric {
  service_name: string; // The name of the service this metric belongs to
  timestamp: string; // ISO string format for the metric timestamp
  response_time: number; // Raw response time (e.g., in nanoseconds)
  response_time_ms?: number; // Optional pre-converted response time in milliseconds
  [key: string]: unknown; // Allow additional fields if needed
}

export interface SystemStatus {
  total_pollers: number;
  healthy_pollers: number;
  last_update: string; // Last update of the overall system status
  service_stats: ServiceStats; // Summary statistics for services
  [key: string]: unknown; // Allow additional fields if needed
}
