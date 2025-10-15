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

import React, { useCallback, useMemo } from 'react';
import { AlertTriangle, Cpu, HardDrive, MemoryStick, ExternalLink } from 'lucide-react';
import { useSysmon } from '@/contexts/SysmonContext';
import { useAnalytics } from '@/contexts/AnalyticsContext';
import { useRouter } from 'next/navigation';

interface HighUtilizationService {
    device_id: string;
    hostname?: string;
    ip_address?: string;
    service_type: string;
    service_name: string;
    metric_value: number;
    metric_type: 'cpu' | 'memory' | 'disk';
    severity: 'warning' | 'critical';
    timestamp?: string;
}

const HighUtilizationWidget: React.FC = () => {
    const router = useRouter();
    const { data: sysmonData, loading: sysmonLoading, error: sysmonError } = useSysmon();
    const { data: analyticsData, loading: analyticsLoading } = useAnalytics();
    
    const loading = sysmonLoading || analyticsLoading;
    const error = sysmonError;


    const { services, stats } = useMemo(() => {
        if (!sysmonData || !analyticsData) {
            return {
                services: [],
                stats: {
                    highCpu: 0,
                    highMemory: 0,
                    highDisk: 0,
                    warningCpu: 0,
                    warningMemory: 0,
                    warningDisk: 0,
                    totalIssues: 0
                }
            };
        }

        // Create a map of device info by IP address and hostname
        const devices = analyticsData.devicesLatest as { ip?: string; hostname?: string; device_id: string }[];
        const deviceMap = new Map();
        devices.forEach((device) => {
            if (device.ip) {
                deviceMap.set(device.ip, device);
            }
            if (device.hostname) {
                deviceMap.set(device.hostname, device);
            }
            if (device.device_id) {
                deviceMap.set(device.device_id, device);
            }
        });

        // Process and combine the results
        const highUtilizationServices: HighUtilizationService[] = [];
        let criticalCpuCount = 0;
        let criticalMemoryCount = 0;
        let criticalDiskCount = 0;
        let warningCpuCount = 0;
        let warningMemoryCount = 0;
        let warningDiskCount = 0;
        
        sysmonData.forEach((summary) => {
            const hostKey =
                summary.hostId ??
                (summary.deviceId && summary.deviceId.includes(':')
                    ? summary.deviceId.split(':')[1]
                    : undefined) ??
                summary.agentId ??
                summary.pollerId ??
                'unknown';
            const device =
                (summary.deviceId ? deviceMap.get(summary.deviceId) : undefined) ||
                (summary.hostId ? deviceMap.get(summary.hostId) : undefined) ||
                (summary.agentId ? deviceMap.get(summary.agentId) : undefined);

            const timestamp = summary.lastTimestamp ?? undefined;
            const ipAddress =
                device?.ip ??
                (summary.deviceId && summary.deviceId.includes(':')
                    ? summary.deviceId.split(':')[1]
                    : undefined) ??
                hostKey;

            if (summary.avgCpuUsage !== undefined) {
                if (summary.avgCpuUsage > 90) {
                    criticalCpuCount++;
                    highUtilizationServices.push({
                        device_id:
                            device?.device_id ||
                            summary.deviceId ||
                            (summary.pollerId ? `${summary.pollerId}:${hostKey}` : hostKey),
                        hostname: device?.hostname || summary.hostId || summary.pollerId,
                        ip_address: ipAddress,
                        service_type: 'grpc',
                        service_name: 'sysmon',
                        metric_value: summary.avgCpuUsage,
                        metric_type: 'cpu',
                        severity: 'critical',
                        timestamp
                    });
                } else if (summary.avgCpuUsage > 75) {
                    warningCpuCount++;
                    highUtilizationServices.push({
                        device_id:
                            device?.device_id ||
                            summary.deviceId ||
                            (summary.pollerId ? `${summary.pollerId}:${hostKey}` : hostKey),
                        hostname: device?.hostname || summary.hostId || summary.pollerId,
                        ip_address: ipAddress,
                        service_type: 'grpc',
                        service_name: 'sysmon',
                        metric_value: summary.avgCpuUsage,
                        metric_type: 'cpu',
                        severity: 'warning',
                        timestamp
                    });
                }
            }

            if (summary.memoryUsagePercent !== undefined) {
                if (summary.memoryUsagePercent > 90) {
                    criticalMemoryCount++;
                    highUtilizationServices.push({
                        device_id:
                            device?.device_id ||
                            summary.deviceId ||
                            (summary.pollerId ? `${summary.pollerId}:${hostKey}` : hostKey),
                        hostname: device?.hostname || summary.hostId || summary.pollerId,
                        ip_address: ipAddress,
                        service_type: 'grpc',
                        service_name: 'sysmon',
                        metric_value: summary.memoryUsagePercent,
                        metric_type: 'memory',
                        severity: 'critical',
                        timestamp
                    });
                } else if (summary.memoryUsagePercent > 75) {
                    warningMemoryCount++;
                    highUtilizationServices.push({
                        device_id:
                            device?.device_id ||
                            summary.deviceId ||
                            (summary.pollerId ? `${summary.pollerId}:${hostKey}` : hostKey),
                        hostname: device?.hostname || summary.hostId || summary.pollerId,
                        ip_address: ipAddress,
                        service_type: 'grpc',
                        service_name: 'sysmon',
                        metric_value: summary.memoryUsagePercent,
                        metric_type: 'memory',
                        severity: 'warning',
                        timestamp
                    });
                }
            }

            summary.disks.forEach((disk) => {
                if (disk.usagePercent === undefined) {
                    return;
                }
                if (disk.usagePercent > 85) {
                    criticalDiskCount++;
                    highUtilizationServices.push({
                        device_id:
                            device?.device_id ||
                            summary.deviceId ||
                            (summary.pollerId ? `${summary.pollerId}:${hostKey}` : hostKey),
                        hostname: device?.hostname || summary.hostId || summary.pollerId,
                        ip_address: ipAddress,
                        service_type: 'grpc',
                        service_name: `sysmon:${disk.mountPoint}`,
                        metric_value: disk.usagePercent,
                        metric_type: 'disk',
                        severity: 'critical',
                        timestamp: disk.lastTimestamp ?? timestamp
                    });
                } else if (disk.usagePercent > 75) {
                    warningDiskCount++;
                    highUtilizationServices.push({
                        device_id:
                            device?.device_id ||
                            summary.deviceId ||
                            (summary.pollerId ? `${summary.pollerId}:${hostKey}` : hostKey),
                        hostname: device?.hostname || summary.hostId || summary.pollerId,
                        ip_address: ipAddress,
                        service_type: 'grpc',
                        service_name: `sysmon:${disk.mountPoint}`,
                        metric_value: disk.usagePercent,
                        metric_type: 'disk',
                        severity: 'warning',
                        timestamp: disk.lastTimestamp ?? timestamp
                    });
                }
            });
        });

        // Sort by severity (critical first) then by metric value
        const sortedServices = highUtilizationServices
            .sort((a, b) => {
                if (a.severity !== b.severity) {
                    return a.severity === 'critical' ? -1 : 1;
                }
                return b.metric_value - a.metric_value;
            })
            .slice(0, 5);

        const stats = {
            highCpu: criticalCpuCount,
            highMemory: criticalMemoryCount,
            highDisk: criticalDiskCount,
            warningCpu: warningCpuCount,
            warningMemory: warningMemoryCount,
            warningDisk: warningDiskCount,
            totalIssues: highUtilizationServices.length
        };

        return { services: sortedServices, stats };
    }, [sysmonData, analyticsData]);

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
        const metricType = service.metric_type.charAt(0).toUpperCase() + service.metric_type.slice(1);
        return `${metricType}: ${service.metric_value.toFixed(1)}%`;
    };

    const getMetricColor = (service: HighUtilizationService) => {
        if (service.severity === 'critical') {
            return 'text-red-600 dark:text-red-400';
        }
        return 'text-yellow-600 dark:text-yellow-400';
    };

    const handleUtilizationClick = useCallback(() => {
        // For sysmon metrics, navigate to the metrics page instead of SRQL queries
        // If we have services, use the first one as an example, otherwise go to general metrics page
        if (services.length > 0) {
            const firstService = services[0];
            // Use the device_id directly from SRQL
            router.push(`/metrics?deviceId=${encodeURIComponent(firstService.device_id)}`);
        } else {
            // Fallback to general metrics page
            router.push('/metrics');
        }
    }, [router, services]);

    const handleServiceClick = useCallback((service: HighUtilizationService) => {
        // Navigate to the metrics page using the device_id from SRQL
        router.push(`/metrics?deviceId=${encodeURIComponent(service.device_id)}`);
    }, [router]);

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
                <h3 
                    className="font-semibold text-gray-900 dark:text-white cursor-pointer hover:text-blue-600 dark:hover:text-blue-400 transition-colors"
                    onClick={handleUtilizationClick}
                    title="Click to view system metrics"
                >
                    High Utilization Services
                </h3>
                <button
                    onClick={() => {
                        // Navigate to metrics page instead of SRQL query
                        if (services.length > 0) {
                            const firstService = services[0];
                            router.push(`/metrics?deviceId=${encodeURIComponent(firstService.device_id)}`);
                        } else {
                            router.push('/metrics');
                        }
                    }}
                    className="text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
                    title="View system metrics"
                >
                    <ExternalLink size={16} />
                </button>
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
                            <tr 
                                className="border-b border-gray-100 dark:border-gray-800 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors"
                                onClick={handleUtilizationClick}
                                title="Click to view CPU-related sysmon services"
                            >
                                <td className="py-1 text-gray-900 dark:text-white">CPU</td>
                                <td 
                                    className="text-center text-yellow-600 dark:text-yellow-400 font-bold cursor-pointer hover:bg-yellow-50 dark:hover:bg-yellow-900/10"
                                    onClick={(e) => {
                                        e.stopPropagation();
                                        handleUtilizationClick();
                                    }}
                                    title="Click to view warning CPU services"
                                >
                                    {stats.warningCpu}
                                </td>
                                <td 
                                    className="text-center text-red-600 dark:text-red-400 font-bold cursor-pointer hover:bg-red-50 dark:hover:bg-red-900/10"
                                    onClick={(e) => {
                                        e.stopPropagation();
                                        handleUtilizationClick();
                                    }}
                                    title="Click to view critical CPU services"
                                >
                                    {stats.highCpu}
                                </td>
                            </tr>
                            <tr 
                                className="border-b border-gray-100 dark:border-gray-800 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors"
                                onClick={handleUtilizationClick}
                                title="Click to view Memory-related sysmon services"
                            >
                                <td className="py-1 text-gray-900 dark:text-white">Memory</td>
                                <td 
                                    className="text-center text-yellow-600 dark:text-yellow-400 font-bold cursor-pointer hover:bg-yellow-50 dark:hover:bg-yellow-900/10"
                                    onClick={(e) => {
                                        e.stopPropagation();
                                        handleUtilizationClick();
                                    }}
                                    title="Click to view warning Memory services"
                                >
                                    {stats.warningMemory}
                                </td>
                                <td 
                                    className="text-center text-red-600 dark:text-red-400 font-bold cursor-pointer hover:bg-red-50 dark:hover:bg-red-900/10"
                                    onClick={(e) => {
                                        e.stopPropagation();
                                        handleUtilizationClick();
                                    }}
                                    title="Click to view critical Memory services"
                                >
                                    {stats.highMemory}
                                </td>
                            </tr>
                            <tr 
                                className="cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors"
                                onClick={handleUtilizationClick}
                                title="Click to view Disk-related sysmon services"
                            >
                                <td className="py-1 text-gray-900 dark:text-white">Disk</td>
                                <td 
                                    className="text-center text-yellow-600 dark:text-yellow-400 font-bold cursor-pointer hover:bg-yellow-50 dark:hover:bg-yellow-900/10"
                                    onClick={(e) => {
                                        e.stopPropagation();
                                        handleUtilizationClick();
                                    }}
                                    title="Click to view warning Disk services"
                                >
                                    {stats.warningDisk}
                                </td>
                                <td 
                                    className="text-center text-red-600 dark:text-red-400 font-bold cursor-pointer hover:bg-red-50 dark:hover:bg-red-900/10"
                                    onClick={(e) => {
                                        e.stopPropagation();
                                        handleUtilizationClick();
                                    }}
                                    title="Click to view critical Disk services"
                                >
                                    {stats.highDisk}
                                </td>
                            </tr>
                        </tbody>
                    </table>
                </div>

                {/* Service List */}
                {services.length > 0 ? (
                    <div className="space-y-2 max-h-40 overflow-y-auto">
                        {services.map((service, index) => (
                            <div 
                                key={`${service.device_id}-${index}`} 
                                className="flex items-center justify-between p-2 bg-gray-50 dark:bg-gray-700/50 rounded cursor-pointer hover:bg-gray-100 dark:hover:bg-gray-600/50 transition-colors"
                                onClick={() => handleServiceClick(service)}
                                title={`Click to view metrics for ${service.hostname || service.device_id}`}
                            >
                                <div className="flex items-center space-x-2">
                                    <div className={getMetricColor(service)}>
                                        {getMetricIcon(service.metric_type)}
                                    </div>
                                    <div>
                                        <div className="text-sm font-medium text-gray-900 dark:text-white">
                                            {service.hostname || service.device_id}
                                        </div>
                                        <div className={`text-xs ${getMetricColor(service)}`}>
                                            {getMetricValue(service)} • {service.severity}
                                        </div>
                                    </div>
                                </div>
                                <div className="flex-shrink-0 text-blue-600 dark:text-blue-400 opacity-70">
                                    <ExternalLink size={14} />
                                </div>
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
