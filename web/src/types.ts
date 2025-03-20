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

export interface ServiceDetails {
  response_time?: number;
  packet_loss?: number;
  available?: boolean;
  round_trip?: number;
  [key: string]: unknown;
}

export interface Service {
  name: string;
  type: string;
  available: boolean;
  details?: ServiceDetails | string;
}

export interface Node {
  node_id: string;
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
  total_nodes: number;
  healthy_nodes: number;
  last_update: string;
  service_stats: ServiceStats;
}
