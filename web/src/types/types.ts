// src/types/types.ts
import { SweepDetails } from './snmp';
import { RperfMetric } from './rperf';

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
export type ServiceDetails = GenericServiceDetails | SweepDetails | SnmpDetails | RperfDetails | Record<string, any>;

export interface Service {
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
  response_time: number; // Assuming nanoseconds or milliseconds
  [key: string]: unknown; // Allow additional fields if needed
}

export interface SystemStatus {
  total_pollers: number;
  healthy_pollers: number;
  last_update: string;
  service_stats: ServiceStats;
}