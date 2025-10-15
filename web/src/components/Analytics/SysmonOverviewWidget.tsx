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
import { Activity, AlertTriangle, ExternalLink } from 'lucide-react';
import Link from 'next/link';
import { useSysmon } from '@/contexts/SysmonContext';

const SysmonOverviewWidget: React.FC = () => {
    const { data, loading, error } = useSysmon();

    const stats = useMemo(() => {
        if (!data) {
            return {
                totalAgents: 0,
                activeAgents: 0,
                avgCpuUsage: 0,
                avgMemoryUsage: 0
            };
        }

        const twoHoursAgo = Date.now() - 2 * 60 * 60 * 1000;
        const activeAgents = data.filter((agent) => {
            const lastTs = agent.lastTimestamp ? Date.parse(agent.lastTimestamp) : undefined;
            return lastTs ? lastTs > twoHoursAgo : false;
        });

        const avgCpu =
            activeAgents.reduce((sum, agent) => sum + (agent.avgCpuUsage ?? 0), 0) /
            (activeAgents.length || 1);
        const avgMemory =
            activeAgents.reduce((sum, agent) => sum + (agent.memoryUsagePercent ?? 0), 0) /
            (activeAgents.length || 1);

        return {
            totalAgents: data.length,
            activeAgents: activeAgents.length,
            avgCpuUsage: Number.isFinite(avgCpu) ? avgCpu : 0,
            avgMemoryUsage: Number.isFinite(avgMemory) ? avgMemory : 0
        };
    }, [data]);

    const parsedAgents = useMemo(() => {
        if (!data) {
            return [];
        }
        const twoHoursAgo = Date.now() - 2 * 60 * 60 * 1000;
        return data.map((agent) => {
            const lastTs = agent.lastTimestamp ? Date.parse(agent.lastTimestamp) : undefined;
            const isActive = lastTs ? lastTs > twoHoursAgo : false;
            const ipFromDevice =
                agent.deviceId && agent.deviceId.includes(':')
                    ? agent.deviceId.split(':')[1]
                    : undefined;
            const displayName =
                agent.hostId ??
                ipFromDevice ??
                agent.deviceId ??
                agent.pollerId ??
                agent.agentId ??
                'Unknown';

            return {
                pollerId: agent.pollerId ?? 'unknown',
                agentId: agent.agentId ?? 'unknown',
                displayName,
                deviceIp: ipFromDevice,
                avgCpuUsage: agent.avgCpuUsage,
                memoryUsagePercent: agent.memoryUsagePercent,
                lastUpdate: agent.lastTimestamp ? new Date(agent.lastTimestamp) : undefined,
                isActive
            };
        });
    }, [data]);

    const metricsLink = useMemo(() => {
        if (parsedAgents.length === 0) {
            return '/metrics';
        }
        const first = parsedAgents.find(agent => agent.pollerId !== 'unknown') ?? parsedAgents[0];
        if (!first || first.pollerId === 'unknown') {
            return '/metrics';
        }
        const agentQuery = first.agentId ? `&agentId=${encodeURIComponent(first.agentId)}` : '';
        return `/metrics?pollerId=${encodeURIComponent(first.pollerId)}${agentQuery}`;
    }, [parsedAgents]);

    if (loading) {
        return (
            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 flex flex-col h-[320px]">
                <div className="flex justify-between items-start mb-4">
                    <h3 className="font-semibold text-gray-900 dark:text-white">Sysmon Agents</h3>
                </div>
                <div className="flex-1 flex items-center justify-center">
                    <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600"></div>
                </div>
            </div>
        );
    }

    if (error) {
        return (
            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 flex flex-col h-[320px]">
                <div className="flex justify-between items-start mb-4">
                    <h3 className="font-semibold text-gray-900 dark:text-white">Sysmon Agents</h3>
                </div>
                <div className="flex-1 flex items-center justify-center">
                    <div className="text-center text-red-500 dark:text-red-400">
                        <AlertTriangle className="h-8 w-8 mx-auto mb-2" />
                        <p className="text-sm">Failed to load Sysmon data</p>
                    </div>
                </div>
            </div>
        );
    }

    return (
        <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 flex flex-col h-[320px]">
            <div className="flex justify-between items-start mb-4">
                <h3 className="font-semibold text-gray-900 dark:text-white">Sysmon Agents</h3>
                <Link
                    prefetch={false}
                    href={metricsLink}
                    className="text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
                >
                    <ExternalLink size={16} />
                </Link>
            </div>
            
            <div className="flex-1">
                {/* Stats Summary */}
                <div className="grid grid-cols-2 gap-4 mb-4">
                    <div className="text-center">
                        <div className="text-2xl font-bold text-gray-900 dark:text-white">
                            {stats.activeAgents}/{stats.totalAgents}
                        </div>
                        <div className="text-xs text-gray-600 dark:text-gray-400">Active Agents</div>
                    </div>
                    <div className="text-center">
                        <div className="text-2xl font-bold text-gray-900 dark:text-white">
                            {stats.avgCpuUsage.toFixed(1)}%
                        </div>
                        <div className="text-xs text-gray-600 dark:text-gray-400">Avg CPU Usage</div>
                    </div>
                </div>

                {/* Agent List */}
                <div className="space-y-2 max-h-40 overflow-y-auto">
                    {parsedAgents.slice(0, 5).map(agent => (
                        <div key={`${agent.pollerId}-${agent.displayName}`} className="flex items-center justify-between p-2 bg-gray-50 dark:bg-gray-700/50 rounded">
                            <div className="flex items-center space-x-2">
                                <div className={`w-2 h-2 rounded-full ${
                                    agent.isActive ? 'bg-green-500' : 'bg-gray-400 dark:bg-gray-500'
                                }`}></div>
                                <div>
                                    <div className="text-sm font-medium text-gray-900 dark:text-white">
                                        {agent.displayName}
                                    </div>
                                    {(agent.avgCpuUsage !== undefined || agent.memoryUsagePercent !== undefined) && (
                                        <div className="text-xs text-gray-600 dark:text-gray-400">
                                            CPU: {agent.avgCpuUsage !== undefined ? agent.avgCpuUsage.toFixed(1) : 'N/A'}% | 
                                            Mem: {agent.memoryUsagePercent !== undefined ? agent.memoryUsagePercent.toFixed(1) : 'N/A'}%
                                        </div>
                                    )}
                                </div>
                            </div>
                            {agent.isActive && agent.pollerId !== 'unknown' && (
                                <Link
                                    prefetch={false}
                                    href={`/metrics?pollerId=${encodeURIComponent(agent.pollerId)}${agent.agentId ? `&agentId=${encodeURIComponent(agent.agentId)}` : ''}`}
                                    className={`${agent.isActive ? 'text-blue-600 dark:text-blue-400 hover:text-blue-800 dark:hover:text-blue-200' : 'text-gray-400 dark:text-gray-600'}`}
                                    title={`View metrics for ${agent.displayName}`}
                                >
                                    <Activity size={14} />
                                </Link>
                            )}
                        </div>
                    ))}
                    {parsedAgents.length > 5 && (
                        <div className="text-center text-xs text-gray-600 dark:text-gray-400 pt-2">
                            +{parsedAgents.length - 5} more agents
                        </div>
                    )}
                </div>
            </div>
        </div>
    );
};

export default SysmonOverviewWidget;
