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

export interface SysmonDiskSummary {
    mountPoint: string;
    usagePercent?: number;
    usedBytes?: number;
    totalBytes?: number;
    lastTimestamp?: string;
}

export interface SysmonAgentSummary {
    pollerId?: string;
    agentId?: string;
    hostId?: string;
    deviceId?: string;
    partition?: string;
    avgCpuUsage?: number;
    memoryUsagePercent?: number;
    usedMemoryBytes?: number;
    totalMemoryBytes?: number;
    lastTimestamp?: string;
    disks: SysmonDiskSummary[];
}

interface CachedSysmonData {
    data: SysmonAgentSummary[];
    timestamp: number;
    promise?: Promise<SysmonAgentSummary[]>;
}

interface SrqlQueryResponse<T> {
    results?: T[];
}

interface CpuAverageRow {
    device_id?: string;
    avg_cpu_usage?: number | string;
}

interface CpuSampleRow {
    device_id?: string;
    poller_id?: string;
    partition?: string;
    agent_id?: string;
    host_id?: string;
    usage_percent?: number | string;
    timestamp?: string;
}

interface MemorySampleRow {
    device_id?: string;
    poller_id?: string;
    partition?: string;
    agent_id?: string;
    host_id?: string;
    usage_percent?: number | string;
    used_bytes?: number | string;
    total_bytes?: number | string;
    timestamp?: string;
}

interface DiskSampleRow {
    device_id?: string;
    poller_id?: string;
    partition?: string;
    agent_id?: string;
    host_id?: string;
    mount_point?: string;
    usage_percent?: number | string;
    used_bytes?: number | string;
    total_bytes?: number | string;
    timestamp?: string;
}

class SysmonService {
    private cache: CachedSysmonData | null = null;
    private readonly CACHE_DURATION = 30_000; // 30 seconds cache
    private readonly subscribers: Set<() => void> = new Set();

    async getSysmonData(token?: string): Promise<SysmonAgentSummary[]> {
        const now = Date.now();

        if (this.cache && now - this.cache.timestamp < this.CACHE_DURATION) {
            return this.cache.data;
        }

        if (this.cache?.promise) {
            return this.cache.promise;
        }

        const promise = this.fetchSysmonSummaries(token);

        if (this.cache) {
            this.cache.promise = promise;
        } else {
            this.cache = { data: [], timestamp: 0, promise };
        }

        try {
            const data = await promise;
            this.cache = { data, timestamp: now };
            this.notifySubscribers();
            return data;
        } catch (error) {
            if (this.cache) {
                this.cache.promise = undefined;
            }
            throw error;
        }
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
                // Ignore JSON parsing error; keep default message.
            }
            throw new Error(errorMessage);
        }

        const data = (await response.json()) as SrqlQueryResponse<T>;
        if (!Array.isArray(data.results)) {
            return [];
        }
        return data.results;
    }

    private toNumber(value: number | string | undefined): number | undefined {
        if (typeof value === 'number') {
            return Number.isFinite(value) ? value : undefined;
        }
        if (typeof value === 'string' && value.trim() !== '') {
            const parsed = Number(value);
            return Number.isFinite(parsed) ? parsed : undefined;
        }
        return undefined;
    }

    private normalizeTimestamp(timestamp?: string): string | undefined {
        if (!timestamp) {
            return undefined;
        }
        const parsed = Date.parse(timestamp);
        if (Number.isNaN(parsed)) {
            return undefined;
        }
        return new Date(parsed).toISOString();
    }

    private async fetchSysmonSummaries(token?: string): Promise<SysmonAgentSummary[]> {
        const cpuAverageQuery =
            'in:cpu_metrics time:last_2h stats:"avg(usage_percent) as avg_cpu_usage by device_id"';
        const cpuLatestQuery = 'in:cpu_metrics time:last_2h sort:timestamp:desc limit:5000';
        const memoryLatestQuery = 'in:memory_metrics time:last_2h sort:timestamp:desc limit:5000';
        const diskLatestQuery = 'in:disk_metrics time:last_2h sort:timestamp:desc limit:10000';

        const [cpuAvgRows, cpuSampleRows, memoryRows, diskRows] = await Promise.all([
            this.executeSrqlQuery<CpuAverageRow>(cpuAverageQuery, token).catch(() => []),
            this.executeSrqlQuery<CpuSampleRow>(cpuLatestQuery, token).catch(() => []),
            this.executeSrqlQuery<MemorySampleRow>(memoryLatestQuery, token).catch(() => []),
            this.executeSrqlQuery<DiskSampleRow>(diskLatestQuery, token).catch(() => [])
        ]);

        const summaries = new Map<string, SysmonAgentSummary>();
        const cpuAverages = new Map<string, number>();

        cpuAvgRows.forEach((row) => {
            const deviceId = row.device_id;
            const avg = this.toNumber(row.avg_cpu_usage);
            if (deviceId && typeof avg === 'number') {
                cpuAverages.set(deviceId, avg);
            }
        });

        const ensureSummary = (
            deviceId?: string,
            pollerId?: string,
            hostId?: string,
            partition?: string
        ): SysmonAgentSummary | undefined => {
            const derivedDeviceId =
                deviceId ??
                (partition && hostId ? `${partition}:${hostId}` : undefined) ??
                hostId ??
                pollerId;
            if (!derivedDeviceId) {
                return undefined;
            }

            let summary = summaries.get(derivedDeviceId);
            if (!summary) {
                summary = {
                    deviceId: deviceId ?? derivedDeviceId,
                    pollerId,
                    hostId,
                    partition,
                    disks: []
                };
                summaries.set(derivedDeviceId, summary);
            } else {
                summary.deviceId = summary.deviceId ?? deviceId ?? derivedDeviceId;
                if (pollerId && !summary.pollerId) {
                    summary.pollerId = pollerId;
                }
                if (hostId && !summary.hostId) {
                    summary.hostId = hostId;
                }
                if (partition && !summary.partition) {
                    summary.partition = partition;
                }
            }

            return summary;
        };

        cpuSampleRows.forEach((row) => {
            const summary = ensureSummary(row.device_id, row.poller_id, row.host_id, row.partition);
            if (!summary) {
                return;
            }
            summary.pollerId = summary.pollerId ?? row.poller_id ?? undefined;
            summary.agentId = summary.agentId ?? row.agent_id ?? undefined;
            summary.hostId = summary.hostId ?? row.host_id ?? undefined;
            summary.deviceId = summary.deviceId ?? row.device_id ?? undefined;
            summary.partition = summary.partition ?? row.partition ?? undefined;
            const derivedId = summary.deviceId ?? row.device_id ?? summary.pollerId ?? summary.hostId;
            if (derivedId && cpuAverages.has(derivedId)) {
                summary.avgCpuUsage = cpuAverages.get(derivedId);
            } else if (summary.avgCpuUsage === undefined) {
                summary.avgCpuUsage = this.toNumber(row.usage_percent);
            }
            const ts = this.normalizeTimestamp(row.timestamp);
            if (ts) {
                summary.lastTimestamp = summary.lastTimestamp
                    ? new Date(summary.lastTimestamp) > new Date(ts)
                        ? summary.lastTimestamp
                        : ts
                    : ts;
            }
        });

        memoryRows.forEach((row) => {
            const summary = ensureSummary(row.device_id, row.poller_id, row.host_id, row.partition);
            if (!summary) {
                return;
            }
            summary.pollerId = summary.pollerId ?? row.poller_id ?? undefined;
            summary.agentId = summary.agentId ?? row.agent_id ?? undefined;
            summary.hostId = summary.hostId ?? row.host_id ?? undefined;
            summary.deviceId = summary.deviceId ?? row.device_id ?? undefined;
            summary.partition = summary.partition ?? row.partition ?? undefined;
            summary.memoryUsagePercent = this.toNumber(row.usage_percent);
            summary.usedMemoryBytes = this.toNumber(row.used_bytes);
            summary.totalMemoryBytes = this.toNumber(row.total_bytes);

            const timestamp = this.normalizeTimestamp(row.timestamp);
            if (timestamp) {
                summary.lastTimestamp = summary.lastTimestamp
                    ? new Date(summary.lastTimestamp) > new Date(timestamp)
                        ? summary.lastTimestamp
                        : timestamp
                    : timestamp;
            }
        });

        diskRows.forEach((row) => {
            if (!row.mount_point) {
                return;
            }
            const summary = ensureSummary(row.device_id, row.poller_id, row.host_id, row.partition);
            if (!summary) {
                return;
            }
            summary.pollerId = summary.pollerId ?? row.poller_id ?? undefined;
            summary.agentId = summary.agentId ?? row.agent_id ?? undefined;
            summary.hostId = summary.hostId ?? row.host_id ?? undefined;
            summary.deviceId = summary.deviceId ?? row.device_id ?? undefined;
            summary.partition = summary.partition ?? row.partition ?? undefined;

            const diskEntry: SysmonDiskSummary = {
                mountPoint: row.mount_point,
                usagePercent: this.toNumber(row.usage_percent),
                usedBytes: this.toNumber(row.used_bytes),
                totalBytes: this.toNumber(row.total_bytes),
                lastTimestamp: this.normalizeTimestamp(row.timestamp)
            };
            const existing = summary.disks.find((disk) => disk.mountPoint === diskEntry.mountPoint);
            if (existing) {
                const existingTimestamp = existing.lastTimestamp
                    ? new Date(existing.lastTimestamp)
                    : null;
                const newTimestamp = diskEntry.lastTimestamp ? new Date(diskEntry.lastTimestamp) : null;
                if (!existingTimestamp || (newTimestamp && newTimestamp > existingTimestamp)) {
                    existing.usagePercent = diskEntry.usagePercent;
                    existing.usedBytes = diskEntry.usedBytes;
                    existing.totalBytes = diskEntry.totalBytes;
                    existing.lastTimestamp = diskEntry.lastTimestamp;
                }
            } else {
                summary.disks.push(diskEntry);
            }

            if (diskEntry.lastTimestamp) {
                summary.lastTimestamp = summary.lastTimestamp
                    ? new Date(summary.lastTimestamp) > new Date(diskEntry.lastTimestamp)
                        ? summary.lastTimestamp
                        : diskEntry.lastTimestamp
                    : diskEntry.lastTimestamp;
            }
        });

        cpuAverages.forEach((avg, deviceId) => {
            const summary = summaries.get(deviceId) ?? ensureSummary(deviceId);
            if (summary && summary.avgCpuUsage === undefined) {
                summary.avgCpuUsage = avg;
            }
        });

        return Array.from(summaries.values()).sort((a, b) => {
            const deviceA = a.deviceId ?? '';
            const deviceB = b.deviceId ?? '';
            if (deviceA !== deviceB) {
                return deviceA.localeCompare(deviceB);
            }
            const pollerA = a.pollerId ?? '';
            const pollerB = b.pollerId ?? '';
            return pollerA.localeCompare(pollerB);
        });
    }

    subscribe(callback: () => void): () => void {
        this.subscribers.add(callback);
        return () => this.subscribers.delete(callback);
    }

    private notifySubscribers(): void {
        this.subscribers.forEach((callback) => callback());
    }

    refresh(token?: string): Promise<SysmonAgentSummary[]> {
        this.cache = null;
        return this.getSysmonData(token);
    }

    isCacheValid(): boolean {
        if (!this.cache) {
            return false;
        }
        const now = Date.now();
        return now - this.cache.timestamp < this.CACHE_DURATION;
    }
}

export const sysmonService = new SysmonService();
