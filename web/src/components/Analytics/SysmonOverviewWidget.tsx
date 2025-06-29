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
import { Activity, AlertTriangle, ExternalLink } from 'lucide-react';
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

    const fetchSysmonAgentInfo = useCallback(async (pollerId: string) => {
        try {
            // Use the dedicated sysmon API endpoints instead of the query API
            const endTime = new Date();
            const startTime = new Date(endTime.getTime() - 60 * 60 * 1000); // Last hour
            
            const [cpuResponse, memoryResponse, diskResponse] = await Promise.all([
                fetch(`/api/pollers/${pollerId}/sysmon/cpu?start=${startTime.toISOString()}&end=${endTime.toISOString()}`, {
                    headers: {
                        'Content-Type': 'application/json',
                        ...(token && { Authorization: `Bearer ${token}` })
                    }
                }),
                fetch(`/api/pollers/${pollerId}/sysmon/memory?start=${startTime.toISOString()}&end=${endTime.toISOString()}`, {
                    headers: {
                        'Content-Type': 'application/json',
                        ...(token && { Authorization: `Bearer ${token}` })
                    }
                }),
                fetch(`/api/pollers/${pollerId}/sysmon/disk?start=${startTime.toISOString()}&end=${endTime.toISOString()}`, {
                    headers: {
                        'Content-Type': 'application/json',
                        ...(token && { Authorization: `Bearer ${token}` })
                    }
                })
            ]);

            if (!cpuResponse.ok && !memoryResponse.ok && !diskResponse.ok) {
                return null;
            }

            const [cpuData, memoryData, diskData] = await Promise.all([
                cpuResponse.ok ? cpuResponse.json() : [],
                memoryResponse.ok ? memoryResponse.json() : [],
                diskResponse.ok ? diskResponse.json() : []
            ]);
            
            console.log(`Sysmon data for ${pollerId}:`, { cpuData, memoryData, diskData });

            // Get the most recent data from each metric type
            const latestCpu = cpuData.length > 0 ? cpuData[cpuData.length - 1] : null;
            const latestMemory = memoryData.length > 0 ? memoryData[memoryData.length - 1] : null;
            const latestDisk = diskData.length > 0 ? diskData[diskData.length - 1] : null;

            if (!latestCpu && !latestMemory && !latestDisk) {
                return null;
            }

            // Determine if the agent is active (has data within the last 2 hours)
            const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000);
            const isActive = [latestCpu, latestMemory, latestDisk].some(data => 
                data && new Date(data.timestamp) > twoHoursAgo
            );

            // Extract agent info from any available metric (CPU cores, memory, or disk)
            const agentInfo = latestCpu?.cpus?.[0] || latestMemory?.memory || latestDisk;
            const hostname = agentInfo?.host_id || (pollerId === 'demo-staging' ? 'serviceradar-demo-staging' : 'Unknown Host');
            const agentId = agentInfo?.agent_id || 'unknown';

            // Calculate average CPU usage from all cores
            let avgCpuUsage = 0;
            if (latestCpu?.cpus && latestCpu.cpus.length > 0) {
                const totalUsage = latestCpu.cpus.reduce((sum: number, core: { usage_percent: number }) => sum + core.usage_percent, 0);
                avgCpuUsage = totalUsage / latestCpu.cpus.length;
            }

            // Calculate memory usage percentage
            let memoryUsagePercent = 0;
            if (latestMemory?.memory) {
                const totalMemory = latestMemory.memory.total_bytes;
                const usedMemory = latestMemory.memory.used_bytes;
                if (totalMemory && usedMemory) {
                    memoryUsagePercent = (usedMemory / totalMemory) * 100;
                }
            }

            return {
                hostname: hostname,
                ip: 'Unknown IP', // IP not available in these endpoints
                agent_id: agentId,
                avg_cpu_usage: avgCpuUsage,
                memory_usage_percent: memoryUsagePercent,
                total_memory_bytes: latestMemory?.memory?.total_bytes,
                used_memory_bytes: latestMemory?.memory?.used_bytes,
                total_disk_bytes: latestDisk?.disk?.total_bytes,
                used_disk_bytes: latestDisk?.disk?.used_bytes,
                last_update: latestCpu?.timestamp || latestMemory?.timestamp || latestDisk?.timestamp,
                is_active: isActive
            };
        } catch (err) {
            console.error(`Error fetching sysmon agent info for poller ${pollerId}:`, err);
            return null;
        }
    }, [token]);


    useEffect(() => {
        const loadSysmonOverview = async () => {
            setLoading(true);
            setError(null);

            try {
                const pollers = await fetchPollers();
                const agentPromises = pollers.map(async (poller: { poller_id: string }) => {
                    // Now we only need to fetch from the unified sysmon metrics
                    const agentInfo = await fetchSysmonAgentInfo(poller.poller_id);
                    
                    return {
                        pollerId: poller.poller_id,
                        deviceInfo: agentInfo ? {
                            hostname: agentInfo.hostname,
                            ip: agentInfo.ip,
                            agent_id: agentInfo.agent_id
                        } : null,
                        lastCpuReading: agentInfo ? agentInfo.avg_cpu_usage : undefined,
                        lastMemoryReading: agentInfo ? agentInfo.memory_usage_percent : undefined,
                        lastUpdate: agentInfo ? new Date(agentInfo.last_update) : undefined,
                        isActive: agentInfo ? agentInfo.is_active : false
                    };
                });

                const agentsData = await Promise.all(agentPromises);
                
                // Debug logging
                console.log('SysmonOverviewWidget - Agent data:', agentsData.map(agent => ({
                    pollerId: agent.pollerId,
                    hostname: agent.deviceInfo?.hostname,
                    ip: agent.deviceInfo?.ip,
                    agent_id: agent.deviceInfo?.agent_id,
                    isActive: agent.isActive
                })));
                
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
    }, [fetchPollers, fetchSysmonAgentInfo, token]);

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
                    href={`/metrics${agents.length > 0 ? `?pollerId=${encodeURIComponent(agents[0].pollerId)}${agents[0].deviceInfo?.agent_id ? `&agentId=${encodeURIComponent(agents[0].deviceInfo.agent_id)}` : ''}` : ''}`}
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
                                    {(agent.lastCpuReading !== undefined || agent.lastMemoryReading !== undefined) && (
                                        <div className="text-xs text-gray-600 dark:text-gray-400">
                                            CPU: {agent.lastCpuReading?.toFixed(1) || 'N/A'}% | 
                                            Mem: {agent.lastMemoryReading?.toFixed(1) || 'N/A'}%
                                        </div>
                                    )}
                                </div>
                            </div>
                            {agent.deviceInfo && (
                                <Link 
                                    href={`/metrics?pollerId=${encodeURIComponent(agent.pollerId)}${agent.deviceInfo?.agent_id ? `&agentId=${encodeURIComponent(agent.deviceInfo.agent_id)}` : ''}`}
                                    className={`${agent.isActive ? 'text-blue-600 dark:text-blue-400 hover:text-blue-800 dark:hover:text-blue-200' : 'text-gray-400 dark:text-gray-600'}`}
                                    title={`View metrics for ${agent.deviceInfo?.hostname || agent.pollerId}`}
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