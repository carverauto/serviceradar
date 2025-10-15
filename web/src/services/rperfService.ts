/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * You may not use this file except in compliance with the License.
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

import { RperfMetric } from '@/types/rperf';

interface RperfData {
    pollerId: string;
    rperfMetrics: RperfMetric[];
}

interface CachedRperfData {
    data: RperfData[];
    timestamp: number;
    promise?: Promise<RperfData[]>;
}

interface SrqlResponse<T> {
    results?: T[];
}

interface SrqlRperfRow {
    poller_id?: string;
    agent_id?: string;
    metric_name?: string;
    metric_type?: string;
    timestamp?: string;
    metadata?: string;
    message?: string;
    target_device_ip?: string | null;
}

interface RperfMetadataPayload {
    timestamp?: string;
    name?: string;
    bits_per_second?: number;
    bytes_received?: number;
    bytes_sent?: number;
    duration?: number;
    jitter_ms?: number;
    loss_percent?: number;
    packets_lost?: number;
    packets_received?: number;
    packets_sent?: number;
    success?: boolean;
    target?: string;
    response_time?: number;
    error?: string | null;
    agent_id?: string;
    service_name?: string;
    service_type?: string;
    version?: string;
}

class RperfService {
    private cache: CachedRperfData | null = null;
    private readonly CACHE_DURATION = 30000; // 30 seconds cache
    private readonly subscribers: Set<() => void> = new Set();

    async getRperfData(token?: string): Promise<RperfData[]> {
        const now = Date.now();

        if (this.cache && now - this.cache.timestamp < this.CACHE_DURATION) {
            return this.cache.data;
        }

        if (this.cache?.promise) {
            return this.cache.promise;
        }

        const promise = this.fetchRperfData(token);

        if (this.cache) {
            this.cache.promise = promise;
        } else {
            this.cache = {
                data: [],
                timestamp: 0,
                promise
            };
        }

        try {
            const data = await promise;
            this.cache = {
                data,
                timestamp: now,
                promise: undefined
            };
            this.notifySubscribers();
            return data;
        } catch (error) {
            if (this.cache) {
                this.cache.promise = undefined;
            }
            throw error;
        }
    }

    private async fetchRperfData(token?: string): Promise<RperfData[]> {
        const query = 'in:rperf_metrics time:last_2h sort:timestamp:asc limit:2000';
        const rows = await this.executeSrqlQuery<SrqlRperfRow>(query, token);

        if (!rows.length) {
            return [];
        }

        const grouped = new Map<string, RperfMetric[]>();
        const dedupe = new Set<string>();

        rows.forEach((row) => {
            const parsed = this.rowToMetric(row);
            if (!parsed) {
                return;
            }

            const { pollerId, metric } = parsed;
            const key = `${pollerId}|${metric.target}|${metric.timestamp}|${metric.bits_per_second}|${metric.bytes_sent}|${metric.bytes_received}`;
            if (dedupe.has(key)) {
                return;
            }
            dedupe.add(key);

            const entry = grouped.get(pollerId);
            if (entry) {
                entry.push(metric);
            } else {
                grouped.set(pollerId, [metric]);
            }
        });

        return Array.from(grouped.entries()).map(([pollerId, metrics]) => {
            metrics.sort((a, b) => new Date(a.timestamp).getTime() - new Date(b.timestamp).getTime());
            return { pollerId, rperfMetrics: metrics };
        });
    }

    private async executeSrqlQuery<T>(query: string, token?: string): Promise<T[]> {
        const response = await fetch('/api/query', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                ...(token && { Authorization: `Bearer ${token}` })
            },
            body: JSON.stringify({ query })
        });

        if (!response.ok) {
            let errorMessage = `SRQL query failed (${response.status})`;
            try {
                const data = await response.json();
                errorMessage = data?.error ?? errorMessage;
            } catch {
                // ignore parse error and use default message
            }
            throw new Error(errorMessage);
        }

        const data = (await response.json()) as SrqlResponse<T>;
        if (!Array.isArray(data.results)) {
            return [];
        }
        return data.results;
    }

    private rowToMetric(row: SrqlRperfRow): { pollerId: string; metric: RperfMetric } | null {
        const rawPayload = row.metadata ?? row.message;
        if (!rawPayload) {
            return null;
        }

        let metadata: RperfMetadataPayload;
        try {
            metadata = JSON.parse(rawPayload) as RperfMetadataPayload;
        } catch (err) {
            console.error('Failed to parse rperf metadata payload', err);
            return null;
        }

        const pollerId =
            row.poller_id ||
            metadata.agent_id ||
            metadata.service_name ||
            metadata.service_type ||
            'unknown';

        const timestamp =
            this.normalizeTimestamp(row.timestamp) ??
            this.normalizeTimestamp(metadata.timestamp) ??
            new Date().toISOString();

        const metric: RperfMetric = {
            timestamp,
            name: metadata.name ?? (row.metric_name ?? 'rperf_metric'),
            target:
                metadata.target ??
                row.target_device_ip ??
                metadata.agent_id ??
                'unknown',
            agent_id: metadata.agent_id ?? '',
            service_name: metadata.service_name ?? '',
            service_type: metadata.service_type ?? '',
            version: metadata.version ?? '',
            response_time: metadata.response_time ?? 0,
            success: metadata.success ?? false,
            error: metadata.error ?? null,
            bits_per_second: metadata.bits_per_second ?? 0,
            bytes_received: metadata.bytes_received ?? 0,
            bytes_sent: metadata.bytes_sent ?? 0,
            duration: metadata.duration ?? 0,
            jitter_ms: metadata.jitter_ms ?? 0,
            loss_percent: metadata.loss_percent ?? 0,
            packets_lost: metadata.packets_lost ?? 0,
            packets_received: metadata.packets_received ?? 0,
            packets_sent: metadata.packets_sent ?? 0
        };

        return { pollerId, metric };
    }

    private normalizeTimestamp(value?: string): string | undefined {
        if (!value) {
            return undefined;
        }

        const parsed = Date.parse(value);
        if (Number.isNaN(parsed)) {
            return undefined;
        }

        return new Date(parsed).toISOString();
    }

    subscribe(callback: () => void): () => void {
        this.subscribers.add(callback);
        return () => this.subscribers.delete(callback);
    }

    private notifySubscribers(): void {
        this.subscribers.forEach((callback) => callback());
    }

    refresh(token?: string): Promise<RperfData[]> {
        this.cache = null;
        return this.getRperfData(token);
    }

    isCacheValid(): boolean {
        if (!this.cache) {
            return false;
        }
        const now = Date.now();
        return now - this.cache.timestamp < this.CACHE_DURATION;
    }
}

export const rperfService = new RperfService();
