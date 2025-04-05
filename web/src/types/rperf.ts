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

// src/types/rperf.ts
export interface RperfMetric {
    timestamp: string; // ISO string
    name: string;      // e.g., "rperf_tcp_bandwidth"
    target: string;    // e.g., target IP or hostname
    success: boolean;
    error?: string | null;
    bits_per_second: number;
    bytes_received: number;
    bytes_sent: number;
    duration: number;
    jitter_ms: number;
    loss_percent: number;
    packets_lost: number;
    packets_received: number;
    packets_sent: number;
}