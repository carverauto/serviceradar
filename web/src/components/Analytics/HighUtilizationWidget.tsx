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
import { AlertTriangle, Cpu, HardDrive, MemoryStick, ExternalLink } from 'lucide-react';
import Link from 'next/link';
import { Poller } from '@/types/types';

interface CpuCore {
    core_id: string;
    usage_percent: number;
    host_id?: string;
    agent_id?: string;
}

interface CpuMetric {
    timestamp: string;
    cpus: CpuCore[];
}

interface MemoryInfo {
    total_bytes: number;
    used_bytes: number;
    host_id?: string;
    agent_id?: string;
}

interface MemoryMetric {
    timestamp: string;
    memory: MemoryInfo;
}

interface DiskInfo {
    total_bytes: number;
    used_bytes: number;
    mount_point?: string;
    host_id?: string;
    agent_id?: string;
}

interface DiskMetric {
    timestamp: string;
    disks?: DiskInfo[];
    disk?: DiskInfo; // Legacy support
}

interface SysmonPollerData {
    pollerId: string;
    cpuData: CpuMetric[];
    memoryData: MemoryMetric[];
    diskData: DiskMetric[];
}

interface HighUtilizationService {
    host_id: string;
    agent_id: string;
    poller_id: string;
    timestamp: string;
    cpuUsage?: number;
    memoryUsage?: number;
    diskUsage?: number;
    metric_type: 'cpu' | 'memory' | 'disk';
    severity: 'warning' | 'critical';
}

const HighUtilizationWidget: React.FC = () => {
    const { token } = useAuth();
    const [services, setServices] = useState<HighUtilizationService[]>([]);
    const [stats, setStats] = useState({
        highCpu: 0,
        highMemory: 0,
        highDisk: 0,
        warningCpu: 0,
        warningMemory: 0,
        warningDisk: 0,
        totalIssues: 0
    });
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);

    const fetchHighUtilizationServices = useCallback(async () => {
        try {
            // First, get all pollers
            const pollersResponse = await fetch('/api/pollers', {
                headers: {
                    'Content-Type': 'application/json',
                    ...(token && { Authorization: `Bearer ${token}` }),
                },
            });
            
            if (!pollersResponse.ok) {
                throw new Error('Failed to fetch pollers');
            }
            
            const pollers = await pollersResponse.json();
            
            // For each poller, fetch sysmon data
            const endTime = new Date();
            const startTime = new Date(endTime.getTime() - 5 * 60 * 1000); // Last 5 minutes for more recent data
            
            const sysmonPromises = pollers.map(async (poller: Poller) => {
                const [cpuResponse, memoryResponse, diskResponse] = await Promise.all([
                    fetch(`/api/pollers/${poller.poller_id}/sysmon/cpu?start=${startTime.toISOString()}&end=${endTime.toISOString()}`, {
                        headers: {
                            'Content-Type': 'application/json',
                            ...(token && { Authorization: `Bearer ${token}` })
                        }
                    }),
                    fetch(`/api/pollers/${poller.poller_id}/sysmon/memory?start=${startTime.toISOString()}&end=${endTime.toISOString()}`, {
                        headers: {
                            'Content-Type': 'application/json',
                            ...(token && { Authorization: `Bearer ${token}` })
                        }
                    }),
                    fetch(`/api/pollers/${poller.poller_id}/sysmon/disk?start=${startTime.toISOString()}&end=${endTime.toISOString()}`, {
                        headers: {
                            'Content-Type': 'application/json',
                            ...(token && { Authorization: `Bearer ${token}` })
                        }
                    })
                ]);
                
                const cpuData = cpuResponse.ok ? await cpuResponse.json() : [];
                const memoryData = memoryResponse.ok ? await memoryResponse.json() : [];
                const diskData = diskResponse.ok ? await diskResponse.json() : [];
                
                return { pollerId: poller.poller_id, cpuData, memoryData, diskData } as SysmonPollerData;
            });
            
            const allSysmonData = await Promise.all(sysmonPromises);

            // Process and combine the results
            const highUtilizationServices: HighUtilizationService[] = [];
            let criticalCpuCount = 0;
            let criticalMemoryCount = 0;
            let criticalDiskCount = 0;
            let warningCpuCount = 0;
            let warningMemoryCount = 0;
            let warningDiskCount = 0;
            
            allSysmonData.forEach(({ pollerId, cpuData, memoryData, diskData }) => {
                // Process CPU data
                if (cpuData.length > 0) {
                    const latestCpu = cpuData[cpuData.length - 1];
                    if (latestCpu?.cpus && latestCpu.cpus.length > 0) {
                        const avgCpuUsage = latestCpu.cpus.reduce((sum: number, core: CpuCore) => sum + core.usage_percent, 0) / latestCpu.cpus.length;
                        const agentInfo = latestCpu.cpus[0];
                        
                        if (avgCpuUsage > 90) {
                            criticalCpuCount++;
                            highUtilizationServices.push({
                                host_id: agentInfo.host_id || pollerId,
                                agent_id: agentInfo.agent_id || 'unknown',
                                poller_id: pollerId,
                                timestamp: latestCpu.timestamp,
                                cpuUsage: avgCpuUsage,
                                metric_type: 'cpu',
                                severity: 'critical'
                            });
                        } else if (avgCpuUsage > 75) {
                            warningCpuCount++;
                            highUtilizationServices.push({
                                host_id: agentInfo.host_id || pollerId,
                                agent_id: agentInfo.agent_id || 'unknown',
                                poller_id: pollerId,
                                timestamp: latestCpu.timestamp,
                                cpuUsage: avgCpuUsage,
                                metric_type: 'cpu',
                                severity: 'warning'
                            });
                        }
                    }
                }
                
                // Process Memory data
                if (memoryData.length > 0) {
                    const latestMemory = memoryData[memoryData.length - 1];
                    if (latestMemory?.memory) {
                        const memoryUsagePercent = (latestMemory.memory.used_bytes / latestMemory.memory.total_bytes) * 100;
                        const existingService = highUtilizationServices.find(s => s.host_id === (latestMemory.memory.host_id || pollerId));
                        
                        if (!existingService) {
                            if (memoryUsagePercent > 90) {
                                criticalMemoryCount++;
                                highUtilizationServices.push({
                                    host_id: latestMemory.memory.host_id || pollerId,
                                    agent_id: latestMemory.memory.agent_id || 'unknown',
                                    poller_id: pollerId,
                                    timestamp: latestMemory.timestamp,
                                    memoryUsage: memoryUsagePercent,
                                    metric_type: 'memory',
                                    severity: 'critical'
                                });
                            } else if (memoryUsagePercent > 75) {
                                warningMemoryCount++;
                                highUtilizationServices.push({
                                    host_id: latestMemory.memory.host_id || pollerId,
                                    agent_id: latestMemory.memory.agent_id || 'unknown',
                                    poller_id: pollerId,
                                    timestamp: latestMemory.timestamp,
                                    memoryUsage: memoryUsagePercent,
                                    metric_type: 'memory',
                                    severity: 'warning'
                                });
                            }
                        }
                    }
                }
                
                // Process Disk data
                if (diskData.length > 0) {
                    const latestDisk = diskData[diskData.length - 1];
                    
                    // Check both possible data structures: disks array or single disk
                    const disks = latestDisk?.disks || (latestDisk?.disk ? [latestDisk.disk] : []);
                    
                    if (disks.length > 0) {
                        // Process each disk and find the one with highest usage
                        disks.forEach((disk: DiskInfo) => {
                            const diskUsagePercent = (disk.used_bytes / disk.total_bytes) * 100;
                            
                            const existingService = highUtilizationServices.find(s => 
                                s.host_id === (disk.host_id || pollerId) && 
                                s.metric_type === 'disk'
                            );
                            
                            if (!existingService) {
                                if (diskUsagePercent > 85) {
                                    criticalDiskCount++;
                                    highUtilizationServices.push({
                                        host_id: disk.host_id || pollerId,
                                        agent_id: disk.agent_id || 'unknown',
                                        poller_id: pollerId,
                                        timestamp: latestDisk.timestamp,
                                        diskUsage: diskUsagePercent,
                                        metric_type: 'disk',
                                        severity: 'critical'
                                    });
                                } else if (diskUsagePercent > 75) {
                                    warningDiskCount++;
                                    highUtilizationServices.push({
                                        host_id: disk.host_id || pollerId,
                                        agent_id: disk.agent_id || 'unknown',
                                        poller_id: pollerId,
                                        timestamp: latestDisk.timestamp,
                                        diskUsage: diskUsagePercent,
                                        metric_type: 'disk',
                                        severity: 'warning'
                                    });
                                }
                            }
                        });
                    }
                }
            });

            // Sort by severity (critical first) then by timestamp
            const sortedServices = highUtilizationServices
                .sort((a, b) => {
                    if (a.severity !== b.severity) {
                        return a.severity === 'critical' ? -1 : 1;
                    }
                    return new Date(b.timestamp).getTime() - new Date(a.timestamp).getTime();
                })
                .slice(0, 5);

            setServices(sortedServices);
            
            // Calculate stats
            setStats({
                highCpu: criticalCpuCount,
                highMemory: criticalMemoryCount,
                highDisk: criticalDiskCount,
                warningCpu: warningCpuCount,
                warningMemory: warningMemoryCount,
                warningDisk: warningDiskCount,
                totalIssues: highUtilizationServices.length
            });

        } catch (err) {
            console.error('Error fetching high utilization services:', err);
            setError(err instanceof Error ? err.message : 'Unknown error');
        } finally {
            setLoading(false);
        }
    }, [token]);

    useEffect(() => {
        fetchHighUtilizationServices();
        const interval = setInterval(fetchHighUtilizationServices, 60000); // Refresh every minute
        return () => clearInterval(interval);
    }, [fetchHighUtilizationServices]);

    const getMetricIcon = (type: 'cpu' | 'memory' | 'disk') => {
        switch (type) {
            case 'cpu':
                return <Cpu size={14} />;
            case 'memory':
                return <MemoryStick size={14} />;
            case 'disk':
                return <HardDrive size={14} />;
        }
    };

    const getMetricValue = (service: HighUtilizationService) => {
        if (service.cpuUsage !== undefined) {
            return `CPU: ${service.cpuUsage.toFixed(1)}%`;
        }
        if (service.memoryUsage !== undefined) {
            return `Memory: ${service.memoryUsage.toFixed(1)}%`;
        }
        if (service.diskUsage !== undefined) {
            return `Disk: ${service.diskUsage.toFixed(1)}%`;
        }
        return 'N/A';
    };

    const getMetricColor = (service: HighUtilizationService) => {
        if (service.severity === 'critical') {
            return 'text-red-600 dark:text-red-400';
        }
        return 'text-yellow-600 dark:text-yellow-400';
    };

    if (loading) {
        return (
            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 flex flex-col h-[320px]">
                <div className="flex justify-between items-start mb-4">
                    <h3 className="font-semibold text-gray-900 dark:text-white">High Utilization Services</h3>
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
                    <h3 className="font-semibold text-gray-900 dark:text-white">High Utilization Services</h3>
                </div>
                <div className="flex-1 flex items-center justify-center">
                    <div className="text-center text-red-500 dark:text-red-400">
                        <AlertTriangle className="h-8 w-8 mx-auto mb-2" />
                        <p className="text-sm">Failed to load utilization data</p>
                    </div>
                </div>
            </div>
        );
    }

    return (
        <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 flex flex-col h-[320px]">
            <div className="flex justify-between items-start mb-4">
                <h3 className="font-semibold text-gray-900 dark:text-white">High Utilization Services</h3>
                {services.length > 0 && (
                    <Link 
                        href={`/metrics?pollerId=${encodeURIComponent(services[0].poller_id)}&agentId=${encodeURIComponent(services[0].agent_id)}`}
                        className="text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
                    >
                        <ExternalLink size={16} />
                    </Link>
                )}
            </div>
            
            <div className="flex-1">
                {/* Stats Summary Table */}
                <div className="mb-4">
                    <table className="w-full text-sm">
                        <thead>
                            <tr className="border-b border-gray-200 dark:border-gray-700">
                                <th className="text-left text-xs font-medium text-gray-600 dark:text-gray-400 py-1">Metric</th>
                                <th className="text-center text-xs font-medium text-yellow-600 dark:text-yellow-400 py-1">Warning</th>
                                <th className="text-center text-xs font-medium text-red-600 dark:text-red-400 py-1">Critical</th>
                            </tr>
                        </thead>
                        <tbody>
                            <tr className="border-b border-gray-100 dark:border-gray-800">
                                <td className="py-1 text-gray-900 dark:text-white">CPU</td>
                                <td className="text-center text-yellow-600 dark:text-yellow-400 font-bold">{stats.warningCpu}</td>
                                <td className="text-center text-red-600 dark:text-red-400 font-bold">{stats.highCpu}</td>
                            </tr>
                            <tr className="border-b border-gray-100 dark:border-gray-800">
                                <td className="py-1 text-gray-900 dark:text-white">Memory</td>
                                <td className="text-center text-yellow-600 dark:text-yellow-400 font-bold">{stats.warningMemory}</td>
                                <td className="text-center text-red-600 dark:text-red-400 font-bold">{stats.highMemory}</td>
                            </tr>
                            <tr>
                                <td className="py-1 text-gray-900 dark:text-white">Disk</td>
                                <td className="text-center text-yellow-600 dark:text-yellow-400 font-bold">{stats.warningDisk}</td>
                                <td className="text-center text-red-600 dark:text-red-400 font-bold">{stats.highDisk}</td>
                            </tr>
                        </tbody>
                    </table>
                </div>

                {/* Service List */}
                {services.length > 0 ? (
                    <div className="space-y-2 max-h-40 overflow-y-auto">
                        {services.map((service, index) => (
                            <div key={`${service.host_id}-${index}`} className="flex items-center justify-between p-2 bg-gray-50 dark:bg-gray-700/50 rounded">
                                <div className="flex items-center space-x-2">
                                    <div className={getMetricColor(service)}>
                                        {getMetricIcon(service.metric_type)}
                                    </div>
                                    <div>
                                        <div className="text-sm font-medium text-gray-900 dark:text-white">
                                            {service.host_id}
                                        </div>
                                        <div className={`text-xs ${getMetricColor(service)}`}>
                                            {getMetricValue(service)}
                                        </div>
                                    </div>
                                </div>
                                <Link 
                                    href={`/metrics?pollerId=${encodeURIComponent(service.poller_id)}&agentId=${encodeURIComponent(service.agent_id)}`}
                                    className="text-blue-600 dark:text-blue-400 hover:text-blue-800 dark:hover:text-blue-200"
                                    title={`View metrics for ${service.host_id}`}
                                >
                                    <ExternalLink size={14} />
                                </Link>
                            </div>
                        ))}
                    </div>
                ) : (
                    <div className="flex-1 flex items-center justify-center text-center text-gray-600 dark:text-gray-400">
                        <div>
                            <AlertTriangle className="h-8 w-8 mx-auto mb-2 text-green-600 dark:text-green-400" />
                            <p className="text-sm">No services with high utilization</p>
                            <p className="text-xs mt-1">All systems operating normally</p>
                        </div>
                    </div>
                )}
            </div>
        </div>
    );
};

export default HighUtilizationWidget;