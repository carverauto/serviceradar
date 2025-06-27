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

import React, { useState, useEffect, useCallback } from 'react';
import { useAuth } from '@/components/AuthProvider';
import { Activity, Server, AlertTriangle, ExternalLink } from 'lucide-react';
import Link from 'next/link';

interface SysmonAgent {
    pollerId: string;
    deviceInfo?: {
        hostname?: string;
        ip: string;
        agent_id: string;
    };
    lastCpuReading?: number;
    lastMemoryReading?: number;
    lastUpdate?: Date;
    isActive: boolean;
}

const SysmonOverviewWidget: React.FC = () => {
    const { token } = useAuth();
    const [agents, setAgents] = useState<SysmonAgent[]>([]);
    const [stats, setStats] = useState({
        totalAgents: 0,
        activeAgents: 0,
        avgCpuUsage: 0,
        avgMemoryUsage: 0
    });
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);

    const fetchPollers = useCallback(async () => {
        try {
            const response = await fetch('/api/pollers', {
                headers: {
                    'Content-Type': 'application/json',
                    ...(token && { Authorization: `Bearer ${token}` }),
                },
            });

            if (!response.ok) throw new Error('Failed to fetch pollers');
            return await response.json();
        } catch (err) {
            console.error('Error fetching pollers:', err);
            return [];
        }
    }, [token]);

    const fetchDevicesForPoller = useCallback(async (pollerId: string) => {
        try {
            const response = await fetch('/api/query', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    ...(token && { Authorization: `Bearer ${token}` })
                },
                body: JSON.stringify({
                    query: `SHOW DEVICES WHERE poller_id = '${pollerId}' LIMIT 1`,
                }),
            });

            if (!response.ok) return null;
            const data = await response.json();
            return data.results?.[0] || null;
        } catch (err) {
            console.error(`Error fetching device for poller ${pollerId}:`, err);
            return null;
        }
    }, [token]);

    const fetchSysmonData = useCallback(async (pollerId: string) => {
        try {
            const [cpuResponse, memoryResponse] = await Promise.all([
                fetch(`/api/pollers/${pollerId}/sysmon/cpu?hours=1`, {
                    headers: {
                        'Content-Type': 'application/json',
                        ...(token && { Authorization: `Bearer ${token}` })
                    },
                }),
                fetch(`/api/pollers/${pollerId}/sysmon/memory?hours=1`, {
                    headers: {
                        'Content-Type': 'application/json',
                        ...(token && { Authorization: `Bearer ${token}` })
                    },
                })
            ]);

            const cpuData = cpuResponse.ok ? await cpuResponse.json() : null;
            const memoryData = memoryResponse.ok ? await memoryResponse.json() : null;

            const latestCpu = cpuData && cpuData.length > 0 ? cpuData[cpuData.length - 1] : null;
            const latestMemory = memoryData && memoryData.length > 0 ? memoryData[memoryData.length - 1] : null;

            const lastUpdate = latestCpu?.timestamp || latestMemory?.timestamp;
            const isActive = lastUpdate ? (new Date().getTime() - new Date(lastUpdate).getTime()) < 10 * 60 * 1000 : false;

            return {
                lastCpuReading: latestCpu?.value,
                lastMemoryReading: latestMemory?.value,
                lastUpdate: lastUpdate ? new Date(lastUpdate) : undefined,
                isActive
            };
        } catch (err) {
            console.error(`Error fetching sysmon data for ${pollerId}:`, err);
            return {
                isActive: false
            };
        }
    }, [token]);

    useEffect(() => {
        const loadSysmonOverview = async () => {
            setLoading(true);
            setError(null);

            try {
                const pollers = await fetchPollers();
                const agentPromises = pollers.map(async (poller: any) => {
                    const [deviceInfo, sysmonData] = await Promise.all([
                        fetchDevicesForPoller(poller.poller_id),
                        fetchSysmonData(poller.poller_id)
                    ]);

                    return {
                        pollerId: poller.poller_id,
                        deviceInfo,
                        ...sysmonData
                    };
                });

                const agentsData = await Promise.all(agentPromises);
                setAgents(agentsData);

                // Calculate stats
                const activeAgents = agentsData.filter(agent => agent.isActive);
                const totalCpu = activeAgents.reduce((sum, agent) => sum + (agent.lastCpuReading || 0), 0);
                const totalMemory = activeAgents.reduce((sum, agent) => sum + (agent.lastMemoryReading || 0), 0);

                setStats({
                    totalAgents: agentsData.length,
                    activeAgents: activeAgents.length,
                    avgCpuUsage: activeAgents.length > 0 ? totalCpu / activeAgents.length : 0,
                    avgMemoryUsage: activeAgents.length > 0 ? totalMemory / activeAgents.length : 0
                });
            } catch (err) {
                setError(err instanceof Error ? err.message : 'Unknown error');
            } finally {
                setLoading(false);
            }
        };

        loadSysmonOverview();
    }, [fetchPollers, fetchDevicesForPoller, fetchSysmonData]);

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
                    href="/metrics"
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
                    {agents.slice(0, 5).map(agent => (
                        <div key={agent.pollerId} className="flex items-center justify-between p-2 bg-gray-50 dark:bg-gray-700/50 rounded">
                            <div className="flex items-center space-x-2">
                                <div className={`w-2 h-2 rounded-full ${
                                    agent.isActive ? 'bg-green-500' : 'bg-gray-400 dark:bg-gray-500'
                                }`}></div>
                                <div>
                                    <div className="text-sm font-medium text-gray-900 dark:text-white">
                                        {agent.deviceInfo?.hostname || agent.deviceInfo?.ip || agent.pollerId}
                                    </div>
                                    {agent.isActive && (
                                        <div className="text-xs text-gray-600 dark:text-gray-400">
                                            CPU: {agent.lastCpuReading?.toFixed(1)}% | 
                                            Mem: {agent.lastMemoryReading?.toFixed(1)}%
                                        </div>
                                    )}
                                </div>
                            </div>
                            {agent.isActive && (
                                <Link 
                                    href={`/metrics?pollerId=${agent.pollerId}`}
                                    className="text-blue-600 dark:text-blue-400 hover:text-blue-800 dark:hover:text-blue-200"
                                >
                                    <Activity size={14} />
                                </Link>
                            )}
                        </div>
                    ))}
                    {agents.length > 5 && (
                        <div className="text-center text-xs text-gray-600 dark:text-gray-400 pt-2">
                            +{agents.length - 5} more agents
                        </div>
                    )}
                </div>
            </div>
        </div>
    );
};

export default SysmonOverviewWidget;