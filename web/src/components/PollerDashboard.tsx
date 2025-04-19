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

// src/components/PollerDashboard.tsx
'use client';

import React, { useState, useEffect, useMemo, useCallback } from 'react';
import {
    Server, AlertCircle, CheckCircle, ChevronDown, ChevronUp,
    AlertTriangle, Clock, Zap, Search, Layers, Settings
} from 'lucide-react';
import { useRouter } from 'next/navigation';
import { Poller, ServiceMetric, Service, GenericServiceDetails } from "@/types/types";

interface PollerDashboardProps {
    initialPollers: Poller[];
    serviceMetrics: { [key: string]: ServiceMetric[] };
}

interface TransformedPoller {
    id: string;
    name: string;
    status: 'healthy' | 'warning' | 'critical';
    lastUpdate: string;
    responseTrend: number[];
    responseTrendRaw: ServiceMetric[];
    servicesCount: { total: number; healthy: number; warning: number; critical: number };
    serviceGroups: { name: string; count: number; healthy: number; services: Service[] }[];
    services: Service[];
    tags: string[];
    rawPoller: Poller;
}

const PollerDashboard: React.FC<PollerDashboardProps> = ({
                                                             initialPollers = [],
                                                             serviceMetrics = {}
                                                         }) => {
    const [pollers, setPollers] = useState<Poller[]>([]);
    const [expandedPoller, setExpandedPoller] = useState<string | null>(null);
    const [searchTerm, setSearchTerm] = useState<string>('');
    const [filterStatus, setFilterStatus] = useState<string>('all');
    const router = useRouter();

    // Define groupServicesByType before it's used
    const groupServicesByType = (services: Service[] = []): { [key: string]: Service[] } => {
        const groups: { [key: string]: Service[] } = {};
        services.forEach((service: Service) => {
            let groupName = 'Other';
            if (['icmp', 'sweep', 'network_sweep'].includes(service.type)) groupName = 'Network';
            else if (['mysql', 'postgres', 'mongodb', 'redis'].includes(service.name.toLowerCase())) groupName = 'Databases';
            else if (['snmp', 'serviceradar-agent'].includes(service.type) || service.name.includes('agent')) groupName = 'Monitoring';
            else if (['dusk', 'rusk', 'grpc', 'rperf-checker'].includes(service.name)) groupName = 'Applications';
            else if (['ssh', 'SSL'].includes(service.name)) groupName = 'Security';
            if (!groups[groupName]) groups[groupName] = [];
            groups[groupName].push(service);
        });
        return groups;
    };

    // Update pollers with alphabetical sorting on initial load or refresh
    useEffect(() => {
        const sortedPollers = [...initialPollers].sort((a: Poller, b: Poller) =>
            a.poller_id.localeCompare(b.poller_id)
        );
        setPollers(sortedPollers);
    }, [initialPollers]);

    // Auto-refresh every 10 seconds
    useEffect(() => {
        const refreshInterval = 10000;
        const timer = setInterval(() => {
            router.refresh();
        }, refreshInterval);
        return () => clearInterval(timer);
    }, [router]);

    // Transform pollers data, maintaining alphabetical order
    const transformedPollers = useMemo((): TransformedPoller[] => {
        return pollers.map((poller: Poller) => {
            const totalServices = poller.services?.length || 0;
            const healthyServices = poller.services?.filter((s: Service) => s.available).length || 0;
            let warningServices = 0;
            let criticalServices = 0;

            poller.services?.forEach((service: Service) => {
                if (!service.available) {
                    criticalServices++;
                } else if (service.details && typeof service.details !== 'string') {
                    const details = service.details as GenericServiceDetails;
                    if ('response_time' in details &&
                        typeof details.response_time === 'number' &&
                        details.response_time > 100000000 &&
                        service.available) {
                        warningServices++;
                    }
                }
            });

            const status: 'healthy' | 'warning' | 'critical' =
                criticalServices > 0 ? 'critical' :
                    warningServices > 0 ? 'warning' : 'healthy';

            let icmpMetrics: ServiceMetric[] = [];
            let responseTrend: number[] = Array(10).fill(0);
            const icmpService = poller.services?.find((s: Service) => s.type === 'icmp');
            if (icmpService) {
                const metricKey = `${poller.poller_id}-${icmpService.name}`;
                if (serviceMetrics[metricKey]) {
                    icmpMetrics = serviceMetrics[metricKey];
                    responseTrend = icmpMetrics
                        .slice(Math.max(0, icmpMetrics.length - 10))
                        .map((m: ServiceMetric) => m.response_time / 1000000)
                        .concat(Array(10 - Math.min(10, icmpMetrics.length)).fill(0));
                }
            }

            const servicesByType = groupServicesByType(poller.services);
            const serviceGroups = Object.entries(servicesByType)
                .map(([name, services]) => ({
                    name,
                    count: services.length,
                    healthy: services.filter((s: Service) => s.available).length,
                    services: services.sort((a: Service, b: Service) => a.name.localeCompare(b.name)) // Sort services within each group
                }))
                .sort((a, b) => a.name.localeCompare(b.name)); // Sort service groups alphabetically

            const tags: string[] = [
                poller.is_healthy ? 'healthy' : 'unhealthy',
                ...(servicesByType['Network'] ? ['network-services'] : []),
                ...(servicesByType['Databases'] ? ['database-services'] : []),
                ...(servicesByType['Applications'] ? ['applications'] : []),
                ...(poller.poller_id.includes('dev') ? ['development'] : []),
                ...(poller.poller_id.includes('prod') ? ['production'] : []),
                ...(poller.poller_id.includes('east') ? ['east-region'] : []),
                ...(poller.poller_id.includes('west') ? ['west-region'] : [])
            ];

            return {
                id: poller.poller_id,
                name: poller.poller_id,
                status,
                lastUpdate: new Date(poller.last_update).toLocaleString(),
                responseTrend,
                responseTrendRaw: icmpMetrics,
                servicesCount: { total: totalServices, healthy: healthyServices, warning: warningServices, critical: criticalServices },
                serviceGroups,
                services: (poller.services || []).sort((a: Service, b: Service) => a.name.localeCompare(b.name)), // Sort services in the "Services" section
                tags,
                rawPoller: poller
            };
        }).sort((a: TransformedPoller, b: TransformedPoller) =>
            a.name.localeCompare(b.name)
        );
    }, [pollers, serviceMetrics]);

    // Filter pollers based on search and status
    const filteredPollers = useMemo(() => {
        return transformedPollers.filter((poller: TransformedPoller) => {
            const matchesSearch =
                poller.name.toLowerCase().includes(searchTerm.toLowerCase()) ||
                poller.tags.some((tag: string) => tag.toLowerCase().includes(searchTerm.toLowerCase())) ||
                poller.services.some((service: Service) => service.name.toLowerCase().includes(searchTerm.toLowerCase()));
            const matchesStatus =
                filterStatus === 'all' || filterStatus === poller.status;
            return matchesSearch && matchesStatus;
        });
    }, [transformedPollers, searchTerm, filterStatus]);

    const toggleExpand = useCallback((pollerId: string) => {
        setExpandedPoller(prev => prev === pollerId ? null : pollerId);
    }, []);

    const getStatusIcon = (status: string) => {
        switch (status) {
            case 'healthy': return <CheckCircle className="h-5 w-5 text-green-500" />;
            case 'warning': return <AlertTriangle className="h-5 w-5 text-yellow-500" />;
            case 'critical': return <AlertCircle className="h-5 w-5 text-red-500" />;
            default: return <AlertCircle className="h-5 w-5 text-gray-500" />;
        }
    };

    const handleServiceClick = useCallback((pollerId: string, serviceName: string) => {
        if (serviceName.toLowerCase() === 'sysmon') {
            router.push(`/metrics?pollerId=${pollerId}`);
        } else {
            router.push(`/service/${pollerId}/${serviceName}`);
        }
    }, [router]);

    const viewDetailedDashboard = useCallback((pollerId: string) => {
        router.push(`/pollers/${pollerId}`);
    }, [router]);

    const SimpleSparkline = ({ data, status }: { data: number[]; status: string }) => {
        if (!data.length || data.every(d => d === 0)) {
            return <div className="text-xs text-gray-500">No data</div>;
        }
        const max = Math.max(...data);
        const min = Math.min(...data);
        const range = max - min || 1;
        const height = 30;
        const width = 100;
        const strokeColor = status === 'healthy' ? "#4ADE80" : status === 'warning' ? "#FACC15" : "#EF4444";
        const points = data.map((value: number, index: number) => {
            const x = (index / (data.length - 1)) * width;
            const normalizedValue = (value - min) / range;
            const y = height - (normalizedValue * height * 0.8) - (height * 0.1);
            return `${x},${y}`;
        }).join(' ');
        return (
            <svg width={width} height={height} className="overflow-visible">
                <polyline points={points} fill="none" stroke={strokeColor} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
                {data.map((value: number, index: number) => {
                    const x = (index / (data.length - 1)) * width;
                    const normalizedValue = (value - min) / range;
                    const y = height - (normalizedValue * height * 0.8) - (height * 0.1);
                    return <circle key={index} cx={x} cy={y} r="1.5" fill={strokeColor} />;
                })}
            </svg>
        );
    };

    return (
        <div className="p-4 bg-gray-50 dark:bg-gray-900">
            <div className="max-w-7xl mx-auto">
                <div className="flex flex-col md:flex-row justify-between items-start md:items-center mb-6 gap-3">
                    <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Pollers ({filteredPollers.length})</h1>
                    <div className="flex flex-col md:flex-row items-start md:items-center gap-3">
                        <div className="relative">
                            <input
                                type="text"
                                placeholder="Search pollers or services..."
                                className="pl-10 pr-4 py-2 border border-gray-300 dark:border-gray-700 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100 focus:ring-blue-500 focus:border-blue-500 w-full md:w-auto"
                                value={searchTerm}
                                onChange={(e: React.ChangeEvent<HTMLInputElement>) => setSearchTerm(e.target.value)}
                            />
                            <Search className="absolute left-3 top-2.5 h-5 w-5 text-gray-400" />
                        </div>
                        <select
                            value={filterStatus}
                            onChange={(e: React.ChangeEvent<HTMLSelectElement>) => setFilterStatus(e.target.value)}
                            className="border border-gray-300 dark:border-gray-700 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100 px-3 py-2 focus:ring-blue-500 focus:border-blue-500"
                        >
                            <option value="all">All Status</option>
                            <option value="healthy">Healthy</option>
                            <option value="warning">Warning</option>
                            <option value="critical">Critical</option>
                        </select>
                    </div>
                </div>

                <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                    {filteredPollers.map((poller: TransformedPoller) => (
                        <div
                            key={poller.id}
                            className={`bg-white dark:bg-gray-800 rounded-lg shadow-md overflow-hidden transition-all duration-200 ${
                                expandedPoller === poller.id ? 'ring-2 ring-blue-500' : ''
                            }`}
                        >
                            <div className="p-4 flex justify-between items-center cursor-pointer" onClick={() => toggleExpand(poller.id)}>
                                <div className="flex items-center">
                                    {getStatusIcon(poller.status)}
                                    <h3 className="ml-2 font-semibold text-gray-900 dark:text-white truncate">{poller.name}</h3>
                                </div>
                                <div className="flex items-center space-x-2">
                                    <span className="text-sm text-gray-500 dark:text-gray-400 hidden md:inline-block">
                                        {poller.servicesCount.healthy} / {poller.servicesCount.total} Services Healthy
                                    </span>
                                    {expandedPoller === poller.id ? <ChevronUp className="h-5 w-5 text-gray-500" /> : <ChevronDown className="h-5 w-5 text-gray-500" />}
                                </div>
                            </div>
                            <div className="px-4 pb-4 pt-0 grid grid-cols-1 sm:grid-cols-3 gap-4">
                                <div className="flex flex-col">
                                    <span className="text-xs text-gray-500 dark:text-gray-400">Response Time Trend</span>
                                    <div className="flex items-center mt-1">
                                        <SimpleSparkline data={poller.responseTrend} status={poller.status} />
                                        <span className="ml-2 text-sm font-medium text-gray-900 dark:text-gray-100">
                                            {poller.responseTrend.length > 0 && poller.responseTrend[poller.responseTrend.length - 1] !== 0
                                                ? `${poller.responseTrend[poller.responseTrend.length - 1].toFixed(1)}ms`
                                                : 'N/A'}
                                        </span>
                                    </div>
                                </div>
                                <div className="flex flex-col">
                                    <span className="text-xs text-gray-500 dark:text-gray-400">Services Status</span>
                                    <div className="flex items-center mt-1 space-x-2">
                                        <div className="flex items-center"><div className="h-3 w-3 rounded-full bg-green-500 mr-1"></div><span className="text-xs">{poller.servicesCount.healthy}</span></div>
                                        <div className="flex items-center"><div className="h-3 w-3 rounded-full bg-yellow-500 mr-1"></div><span className="text-xs">{poller.servicesCount.warning}</span></div>
                                        <div className="flex items-center"><div className="h-3 w-3 rounded-full bg-red-500 mr-1"></div><span className="text-xs">{poller.servicesCount.critical}</span></div>
                                    </div>
                                </div>
                                <div className="flex flex-col">
                                    <span className="text-xs text-gray-500 dark:text-gray-400">Last Updated</span>
                                    <div className="flex items-center mt-1">
                                        <Clock className="h-4 w-4 text-gray-500 mr-1" />
                                        <span className="text-xs text-gray-900 dark:text-gray-100">{poller.lastUpdate}</span>
                                    </div>
                                </div>
                            </div>
                            <div className="px-4 pb-4">
                                <div className="flex flex-wrap gap-2">
                                    {poller.tags.map((tag: string) => (
                                        <span key={tag} className="px-2 py-1 text-xs rounded-full bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200">{tag}</span>
                                    ))}
                                </div>
                            </div>
                            {expandedPoller === poller.id && (
                                <div className="px-4 py-4 border-t border-gray-200 dark:border-gray-700">
                                    {poller.serviceGroups.length > 0 && (
                                        <div>
                                            <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-3 flex items-center">
                                                <Layers className="h-4 w-4 mr-1" /> Service Groups
                                            </h4>
                                            <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mb-4">
                                                {poller.serviceGroups.map((group) => (
                                                    <div key={group.name} className="bg-gray-50 dark:bg-gray-700 p-3 rounded-lg">
                                                        <div className="flex justify-between items-center mb-2">
                                                            <h5 className="font-medium text-gray-900 dark:text-gray-100">{group.name}</h5>
                                                            <span className="text-sm text-gray-500 dark:text-gray-400">{group.healthy} / {group.count} healthy</span>
                                                        </div>
                                                        <div className="w-full bg-gray-200 dark:bg-gray-600 rounded-full h-2 mb-2">
                                                            <div className="bg-green-500 h-2 rounded-full" style={{ width: `${(group.healthy / (group.count || 1)) * 100}%` }}></div>
                                                        </div>
                                                        <div className="flex flex-wrap gap-1 mt-2">
                                                            {group.services.map((service: Service) => (
                                                                <div
                                                                    key={service.name}
                                                                    onClick={() => handleServiceClick(poller.id, service.name)}
                                                                    className={`px-2 py-1 text-xs rounded cursor-pointer flex items-center ${
                                                                        service.available ? 'bg-green-100 dark:bg-green-900 text-green-800 dark:text-green-200' :
                                                                            'bg-red-100 dark:bg-red-900 text-red-800 dark:text-red-200'
                                                                    }`}
                                                                >
                                                                    {service.available ? <CheckCircle className="h-3 w-3 mr-1" /> : <AlertCircle className="h-3 w-3 mr-1" />}
                                                                    {service.name}
                                                                </div>
                                                            ))}
                                                        </div>
                                                    </div>
                                                ))}
                                            </div>
                                        </div>
                                    )}
                                    <div>
                                        <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-3 flex items-center">
                                            <Settings className="h-4 w-4 mr-1" /> Services
                                        </h4>
                                        <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-2">
                                            {poller.services.map((service: Service) => (
                                                <div
                                                    key={service.name}
                                                    onClick={() => handleServiceClick(poller.id, service.name)}
                                                    className="bg-gray-50 dark:bg-gray-700 p-2 rounded cursor-pointer hover:bg-gray-100 dark:hover:bg-gray-600 transition-colors"
                                                >
                                                    <div className="flex items-center justify-between mb-1">
                                                        <span className="font-medium text-sm text-gray-900 dark:text-gray-100 truncate">{service.name}</span>
                                                        {service.available ? <CheckCircle className="h-4 w-4 text-green-500 flex-shrink-0" /> : <AlertCircle className="h-4 w-4 text-red-500 flex-shrink-0" />}
                                                    </div>
                                                    <span className="text-xs text-gray-500 dark:text-gray-400">{service.type}</span>
                                                </div>
                                            ))}
                                        </div>
                                    </div>
                                    <div className="mt-4 flex justify-end">
                                        <button
                                            className="px-4 py-2 bg-blue-500 hover:bg-blue-600 text-white rounded-lg flex items-center transition-colors"
                                            onClick={(e) => { e.stopPropagation(); viewDetailedDashboard(poller.id); }}
                                        >
                                            <Zap className="h-4 w-4 mr-2" /> View Detailed Dashboard
                                        </button>
                                    </div>
                                </div>
                            )}
                        </div>
                    ))}
                </div>
                {filteredPollers.length === 0 && (
                    <div className="text-center py-12 bg-white dark:bg-gray-800 rounded-lg shadow-md">
                        <Server className="h-12 w-12 mx-auto text-gray-400" />
                        <h3 className="mt-2 text-lg font-medium text-gray-900 dark:text-white">No pollers found</h3>
                        <p className="mt-1 text-gray-500 dark:text-gray-400">Try adjusting your search or filters</p>
                    </div>
                )}
            </div>
        </div>
    );
};

export default PollerDashboard;