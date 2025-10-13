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

'use client';

import React, { useMemo } from 'react';
import { Activity, Clock, Cpu, Gauge, HardDrive, Server, Users } from 'lucide-react';
import { ServicePayload } from '@/types/types';
import {
    SysmonVmStatusPayload,
    SysmonVmCpuCore,
    SysmonVmCluster,
} from '@/types/sysmon';

interface SysmonVmDetailsProps {
    service: ServicePayload;
    details?: unknown;
}

const nanosecondsToMilliseconds = (value: number | null | undefined): number => {
    if (typeof value !== 'number' || !Number.isFinite(value)) {
        return 0;
    }
    return value / 1_000_000;
};

const hzToGHz = (value: number | null | undefined): number => {
    if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) {
        return 0;
    }
    return value / 1_000_000_000;
};

const bytesToGiB = (value: number | null | undefined): number => {
    if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) {
        return 0;
    }
    return value / 1024 / 1024 / 1024;
};

const formatPercent = (value: number): string => `${value.toFixed(1)}%`;

const formatGHz = (value: number): string => `${value.toFixed(2)} GHz`;

const formatMilliseconds = (value: number): string => `${value.toFixed(2)} ms`;

const formatGiB = (value: number): string => `${value.toFixed(2)} GiB`;

const deriveClusterName = (core: SysmonVmCpuCore): string => {
    if (core && typeof core.cluster === 'string' && core.cluster.trim().length > 0) {
        return core.cluster.trim();
    }

    if (core && typeof core.label === 'string' && core.label.trim().length > 0) {
        const match = core.label.trim().match(/^[A-Za-z]+/);
        if (match && match[0]) {
            return match[0];
        }
    }

    return 'Unassigned';
};

const computeClusterSummaries = (
    cores: SysmonVmCpuCore[],
    clusters: SysmonVmCluster[] = [],
) => {
    const summaryMap = new Map<string, {
        label: string;
        coreCount: number;
        avgUsage: number;
        avgFrequency: number;
    }>();

    cores.forEach((core) => {
        const clusterName = deriveClusterName(core);
        const existing = summaryMap.get(clusterName) || {
            label: clusterName,
            coreCount: 0,
            avgUsage: 0,
            avgFrequency: 0,
        };

        existing.coreCount += 1;
        existing.avgUsage += core.usage_percent || 0;
        existing.avgFrequency += core.frequency_hz || 0;
        summaryMap.set(clusterName, existing);
    });

    return Array.from(summaryMap.values()).map((entry) => {
        const matchingCluster = clusters.find(cluster => cluster.name === entry.label);
        const avgUsage = entry.coreCount > 0 ? entry.avgUsage / entry.coreCount : 0;
        const avgFrequency = entry.coreCount > 0 ? entry.avgFrequency / entry.coreCount : 0;

        return {
            name: entry.label,
            cores: entry.coreCount,
            averageUsage: avgUsage,
            averageFrequencyHz: matchingCluster?.frequency_hz ?? avgFrequency,
        };
    });
};

const parseDetailsPayload = (raw: unknown): SysmonVmStatusPayload | null => {
    let data: unknown = raw;

    if (typeof raw === 'string') {
        try {
            data = JSON.parse(raw);
        } catch {
            return null;
        }
    }

    if (!data || typeof data !== 'object') {
        return null;
    }

    const candidate = data as Partial<SysmonVmStatusPayload>;
    if (typeof candidate.available !== 'boolean') {
        return null;
    }

    const rawResponseTime = typeof candidate.response_time === 'number'
        ? candidate.response_time
        : Number(candidate.response_time);

    if (!Number.isFinite(rawResponseTime)) {
        return null;
    }

    return {
        ...candidate,
        response_time: rawResponseTime,
    } as SysmonVmStatusPayload;
};

export const parseSysmonVmDetails = (details: unknown): SysmonVmStatusPayload | null =>
    parseDetailsPayload(details);

const SysmonVmDetails: React.FC<SysmonVmDetailsProps> = ({ service, details }) => {
    const parsedDetails = useMemo(
        () => parseDetailsPayload(details ?? service.details ?? null),
        [details, service.details],
    );

    if (!parsedDetails) {
        return (
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
                <h3 className="text-lg font-semibold text-gray-800 dark:text-gray-100 mb-2">
                    sysmon-vm Status
                </h3>
                <p className="text-gray-600 dark:text-gray-400">
                    sysmon-vm returned an unexpected payload. Raw details:
                </p>
                <pre className="mt-3 p-3 bg-gray-100 dark:bg-gray-900 rounded text-xs overflow-x-auto text-gray-700 dark:text-gray-300">
                    {typeof service.details === 'string'
                        ? service.details
                        : JSON.stringify(service.details, null, 2)}
                </pre>
            </div>
        );
    }

    const status = parsedDetails.status ?? {};
    const hostId = status.host_id || 'Unknown host';
    const hostIp = status.host_ip || 'Unknown IP';
    const lastSample = status.timestamp
        ? new Date(status.timestamp).toLocaleString()
        : 'Unknown';

    const cores = status.cpus ?? [];
    const clusters = status.clusters ?? [];
    const memory = status.memory ?? {};
    const processes = status.processes ?? [];
    const disks = status.disks ?? [];

    const responseTimeMs = nanosecondsToMilliseconds(parsedDetails.response_time);
    const cpuCount = cores.length;
    const avgCpuUsage = cpuCount > 0
        ? cores.reduce((sum, core) => sum + (core.usage_percent || 0), 0) / cpuCount
        : 0;
    const avgCpuFrequency = cpuCount > 0
        ? cores.reduce((sum, core) => sum + (core.frequency_hz || 0), 0) / cpuCount
        : 0;
    const memoryTotalGiB = bytesToGiB(memory.total_bytes);
    const memoryUsedGiB = bytesToGiB(memory.used_bytes);
    const memoryPercent = memory.total_bytes
        ? Math.min(100, (memory.used_bytes || 0) / memory.total_bytes * 100)
        : 0;

    const clusterSummaries = computeClusterSummaries(cores, clusters);

    return (
        <div className="space-y-6 transition-colors">
            <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 flex items-center justify-between">
                    <div>
                        <p className="text-sm text-gray-500 dark:text-gray-400">Availability</p>
                        <p className="text-xl font-semibold text-gray-900 dark:text-gray-100">
                            {parsedDetails.available ? 'Available' : 'Unavailable'}
                        </p>
                    </div>
                    <Activity className={`h-8 w-8 ${parsedDetails.available ? 'text-green-500' : 'text-red-500'}`} />
                </div>
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 flex items-center justify-between">
                    <div>
                        <p className="text-sm text-gray-500 dark:text-gray-400">Response Time</p>
                        <p className="text-xl font-semibold text-gray-900 dark:text-gray-100">
                            {formatMilliseconds(responseTimeMs)}
                        </p>
                    </div>
                    <Clock className="h-8 w-8 text-blue-500" />
                </div>
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 flex items-center justify-between">
                    <div>
                        <p className="text-sm text-gray-500 dark:text-gray-400">CPU Cores</p>
                        <p className="text-xl font-semibold text-gray-900 dark:text-gray-100">
                            {cpuCount}
                        </p>
                    </div>
                    <Cpu className="h-8 w-8 text-purple-500" />
                </div>
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 flex items-center justify-between">
                    <div>
                        <p className="text-sm text-gray-500 dark:text-gray-400">Average CPU Usage</p>
                        <p className="text-xl font-semibold text-gray-900 dark:text-gray-100">
                            {formatPercent(avgCpuUsage)}
                        </p>
                    </div>
                    <Gauge className="h-8 w-8 text-amber-500" />
                </div>
            </div>

            <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-5">
                    <div className="flex items-center justify-between mb-4">
                        <h3 className="text-lg font-semibold text-gray-900 dark:text-gray-100">
                            Host Details
                        </h3>
                        <Server className="h-5 w-5 text-gray-400" />
                    </div>
                    <dl className="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-3 text-sm">
                        <div>
                            <dt className="text-gray-500 dark:text-gray-400">Host ID</dt>
                            <dd className="text-gray-900 dark:text-gray-100 break-all">{hostId}</dd>
                        </div>
                        <div>
                            <dt className="text-gray-500 dark:text-gray-400">Host IP</dt>
                            <dd className="text-gray-900 dark:text-gray-100 break-all">{hostIp}</dd>
                        </div>
                        <div>
                            <dt className="text-gray-500 dark:text-gray-400">Last Sample</dt>
                            <dd className="text-gray-900 dark:text-gray-100">{lastSample}</dd>
                        </div>
                        <div>
                            <dt className="text-gray-500 dark:text-gray-400">Average Frequency</dt>
                            <dd className="text-gray-900 dark:text-gray-100">
                                {avgCpuFrequency > 0 ? formatGHz(hzToGHz(avgCpuFrequency)) : 'N/A'}
                            </dd>
                        </div>
                    </dl>
                </div>

                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-5">
                    <div className="flex items-center justify-between mb-4">
                        <h3 className="text-lg font-semibold text-gray-900 dark:text-gray-100">
                            Memory & Processes
                        </h3>
                        <Users className="h-5 w-5 text-gray-400" />
                    </div>
                    <dl className="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-3 text-sm">
                        <div>
                            <dt className="text-gray-500 dark:text-gray-400">Memory Used</dt>
                            <dd className="text-gray-900 dark:text-gray-100">
                                {memoryUsedGiB > 0 ? `${formatGiB(memoryUsedGiB)} / ${formatGiB(memoryTotalGiB)}` : 'N/A'}
                            </dd>
                        </div>
                        <div>
                            <dt className="text-gray-500 dark:text-gray-400">Memory Utilization</dt>
                            <dd className="text-gray-900 dark:text-gray-100">
                                {memoryPercent > 0 ? formatPercent(memoryPercent) : 'N/A'}
                            </dd>
                        </div>
                        <div>
                            <dt className="text-gray-500 dark:text-gray-400">Processes Reporting</dt>
                            <dd className="text-gray-900 dark:text-gray-100">{processes.length}</dd>
                        </div>
                        <div>
                            <dt className="text-gray-500 dark:text-gray-400">Disks Reporting</dt>
                            <dd className="text-gray-900 dark:text-gray-100">{disks.length}</dd>
                        </div>
                    </dl>
                </div>
            </div>

            {clusterSummaries.length > 0 && (
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-5 overflow-hidden">
                    <div className="flex items-center justify-between mb-4">
                        <h3 className="text-lg font-semibold text-gray-900 dark:text-gray-100">
                            CPU Clusters
                        </h3>
                        <Gauge className="h-5 w-5 text-gray-400" />
                    </div>
                    <div className="overflow-x-auto">
                        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
                            <thead className="bg-gray-50 dark:bg-gray-900/50">
                                <tr>
                                    <th className="px-4 py-2 text-left text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                        Cluster
                                    </th>
                                    <th className="px-4 py-2 text-right text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                        Cores
                                    </th>
                                    <th className="px-4 py-2 text-right text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                        Avg Usage
                                    </th>
                                    <th className="px-4 py-2 text-right text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                        Avg Frequency
                                    </th>
                                </tr>
                            </thead>
                            <tbody className="divide-y divide-gray-200 dark:divide-gray-700">
                                {clusterSummaries.map(cluster => {
                                    const frequencyGHz = hzToGHz(cluster.averageFrequencyHz || 0);
                                    return (
                                        <tr key={cluster.name}>
                                            <td className="px-4 py-2 whitespace-nowrap text-sm text-gray-900 dark:text-gray-100">
                                                {cluster.name}
                                            </td>
                                            <td className="px-4 py-2 whitespace-nowrap text-sm text-right text-gray-900 dark:text-gray-100">
                                                {cluster.cores}
                                            </td>
                                            <td className="px-4 py-2 whitespace-nowrap text-sm text-right text-gray-900 dark:text-gray-100">
                                                {formatPercent(cluster.averageUsage)}
                                            </td>
                                            <td className="px-4 py-2 whitespace-nowrap text-sm text-right text-gray-900 dark:text-gray-100">
                                                {frequencyGHz > 0 ? formatGHz(frequencyGHz) : 'N/A'}
                                            </td>
                                        </tr>
                                    );
                                })}
                            </tbody>
                        </table>
                    </div>
                </div>
            )}

            {cores.length > 0 && (
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-5 overflow-hidden">
                    <div className="flex items-center justify-between mb-4">
                        <h3 className="text-lg font-semibold text-gray-900 dark:text-gray-100">
                            Per-Core Metrics
                        </h3>
                        <HardDrive className="h-5 w-5 text-gray-400" />
                    </div>
                    <div className="overflow-x-auto">
                        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
                            <thead className="bg-gray-50 dark:bg-gray-900/50">
                                <tr>
                                    <th className="px-4 py-2 text-left text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                        Core
                                    </th>
                                    <th className="px-4 py-2 text-left text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                        Cluster
                                    </th>
                                    <th className="px-4 py-2 text-right text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                        Usage
                                    </th>
                                    <th className="px-4 py-2 text-right text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                                        Frequency
                                    </th>
                                </tr>
                            </thead>
            <tbody className="divide-y divide-gray-200 dark:divide-gray-700">
                {cores.map(core => {
                    const name = core.label || `Core ${core.core_id}`;
                    const derivedCluster = deriveClusterName(core);
                    const frequencyGHz = hzToGHz(core.frequency_hz);
                    return (
                        <tr key={`${derivedCluster}-${core.core_id}`}>
                            <td className="px-4 py-2 whitespace-nowrap text-sm text-gray-900 dark:text-gray-100">
                                {name}
                            </td>
                            <td className="px-4 py-2 whitespace-nowrap text-sm text-gray-900 dark:text-gray-100">
                                {derivedCluster || 'N/A'}
                            </td>
                                            <td className="px-4 py-2 whitespace-nowrap text-sm text-right text-gray-900 dark:text-gray-100">
                                                {formatPercent(core.usage_percent || 0)}
                                            </td>
                                            <td className="px-4 py-2 whitespace-nowrap text-sm text-right text-gray-900 dark:text-gray-100">
                                                {frequencyGHz > 0 ? formatGHz(frequencyGHz) : 'N/A'}
                                            </td>
                                        </tr>
                                    );
                                })}
                            </tbody>
                        </table>
                    </div>
                </div>
            )}

            {!parsedDetails.available && parsedDetails.error && (
                <div className="bg-red-50 dark:bg-red-900/40 border border-red-200 dark:border-red-800 rounded-lg p-4">
                    <p className="text-sm text-red-700 dark:text-red-200">
                        {parsedDetails.error}
                    </p>
                </div>
            )}
        </div>
    );
};

export default SysmonVmDetails;
