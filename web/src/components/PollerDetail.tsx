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

// src/components/PollerDetail.tsx
import React, { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import {
    ArrowLeft,
    Server,
    Activity,
    CheckCircle,
    XCircle,
    RefreshCw,
    Clock,
    AlertCircle,
    ChevronDown,
    ChevronUp,
    Filter
} from 'lucide-react';
import {
    XAxis,
    YAxis,
    CartesianGrid,
    Tooltip,
    Legend,
    ResponsiveContainer,
    AreaChart,
    Area
} from 'recharts';
import { Poller, ServiceMetric } from "@/types/types";
import ServiceSparkline from "./ServiceSparkline";

import { PingStatus } from "./NetworkStatus";
import PollerTimeline from "./PollerTimeline";
import { PollerHistoryEntry } from "@/components/PollerTimeline";

interface ResponseTimeDataPoint {
    timestamp: number;
    [key: string]: number;
}

interface PollerDetailProps {
    poller?: Poller;
    metrics?: ServiceMetric[];
    history?: PollerHistoryEntry[];
    error?: string;
}

const PollerDetail: React.FC<PollerDetailProps> = ({
                                                   poller,
                                                   metrics = [],
                                                   history = [],
                                                   error
                                               }) => {
    const router = useRouter();
    const [showFilter, setShowFilter] = useState(false);
    const [searchTerm, setSearchTerm] = useState('');
    const [expandedService, setExpandedService] = useState<string | null>(null);
    const [selectedCategory, setSelectedCategory] = useState<string>('all');
    const [lastUpdated, setLastUpdated] = useState<Date>(new Date());
    const [isRefreshing, setIsRefreshing] = useState(false);

    // Auto-refresh setup
    useEffect(() => {
        const intervalId = setInterval(() => {
            router.refresh();
            setLastUpdated(new Date());
        }, 10000);

        return () => clearInterval(intervalId);
    }, [router]);

    // Handle manual refresh
    const handleRefresh = () => {
        setIsRefreshing(true);
        router.refresh();
        setTimeout(() => {
            setIsRefreshing(false);
            setLastUpdated(new Date());
        }, 1000);
    };

    // Handle back button
    const handleBack = () => {
        router.push("/pollers");
    };

    // Handle service expansion
    const toggleServiceExpand = (serviceName: string) => {
        if (expandedService === serviceName) {
            setExpandedService(null);
        } else {
            setExpandedService(serviceName);
        }
    };

    // Handle service click to navigate to service detail page
    const handleServiceClick = (serviceName: string) => {
        router.push(`/service/${poller?.poller_id}/${serviceName}`);
    };

    // Error state
    if (error) {
        return (
            <div className="bg-red-50 dark:bg-red-900/20 p-6 rounded-lg shadow">
                <div className="flex items-center mb-4">
                    <AlertCircle className="h-6 w-6 text-red-500 mr-2" />
                    <h2 className="text-xl font-bold text-red-700 dark:text-red-400">Error Loading Poller</h2>
                </div>
                <p className="text-red-600 dark:text-red-300 mb-4">{error}</p>
                <button
                    onClick={handleBack}
                    className="px-4 py-2 bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-600
                   rounded-lg shadow-sm text-gray-700 dark:text-gray-300 hover:bg-gray-50
                   dark:hover:bg-gray-700 transition-colors flex items-center"
                >
                    <ArrowLeft className="h-4 w-4 mr-2" />
                    Back to Pollers
                </button>
            </div>
        );
    }

    // Loading state if no poller data
    if (!poller) {
        return (
            <div className="flex justify-center items-center h-96">
                <div className="text-center">
                    <RefreshCw className="h-8 w-8 text-blue-500 animate-spin mx-auto mb-4" />
                    <div className="text-lg text-gray-600 dark:text-gray-300">Loading poller data...</div>
                </div>
            </div>
        );
    }

    // Categorize services
    const serviceCategories = {
        all: poller.services || [],
        network: (poller.services || []).filter(s => ['icmp', 'sweep', 'network_sweep'].includes(s.type)),
        monitoring: (poller.services || []).filter(s => ['snmp', 'serviceradar-agent'].includes(s.type) || s.name.includes('agent')),
        applications: (poller.services || []).filter(s => ['dusk', 'rusk', 'grpc', 'rperf-checker'].includes(s.name)),
        security: (poller.services || []).filter(s => ['ssh', 'SSL'].includes(s.name)),
        database: (poller.services || []).filter(s => ['mysql', 'postgres', 'mongodb', 'redis'].includes(s.name.toLowerCase())),
        // Add more categories as needed
    };

    // Filter services based on search and category
    const filteredServices = poller.services?.filter(service => {
        const matchesSearch = service.name.toLowerCase().includes(searchTerm.toLowerCase()) ||
            service.type.toLowerCase().includes(searchTerm.toLowerCase());
        const matchesCategory = selectedCategory === 'all' ||
            serviceCategories[selectedCategory as keyof typeof serviceCategories].includes(service);
        return matchesSearch && matchesCategory;
    }) || [];

    // Group metrics by service for charts
    const serviceMetricsMap: { [key: string]: ServiceMetric[] } = {};

    metrics.forEach(metric => {
        if (!serviceMetricsMap[metric.service_name]) {
            serviceMetricsMap[metric.service_name] = [];
        }
        serviceMetricsMap[metric.service_name].push(metric);
    });

    // Process response time data for the main chart
    const responseTimeData: ResponseTimeDataPoint[] = Object.entries(serviceMetricsMap)
        .map(([serviceName, metrics]) => {
            // Get only the metrics for ICMP services for the main chart
            const service = poller.services?.find(s => s.name === serviceName);
            if (service?.type !== 'icmp') return null;

            return metrics.map(m => ({
                timestamp: new Date(m.timestamp).getTime(),
                [serviceName]: m.response_time / 1000000, // Convert to ms
            }));
        })
        .filter((item): item is ResponseTimeDataPoint[] => item !== null)
        .flat();

    // Sort by timestamp - handle null safety with optional chaining and nullish coalescing
    if (responseTimeData.length > 0) {
        responseTimeData.sort((a, b) => (a?.timestamp ?? 0) - (b?.timestamp ?? 0));
    }

    // Format timestamp for chart labels
    const formatTimestamp = (timestamp: number): string => {
        return new Date(timestamp).toLocaleTimeString();
    };

    return (
        <div className="space-y-6">
            {/* Header with back button */}
            <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4 bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                <div className="flex items-center">
                    <button
                        onClick={handleBack}
                        className="p-2 rounded-full bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300
                     hover:bg-gray-200 dark:hover:bg-gray-600 transition-colors mr-3"
                    >
                        <ArrowLeft className="h-5 w-5" />
                        <span className="sr-only">Back to Pollers</span>
                    </button>
                    <div>
                        <h1 className="text-xl sm:text-2xl font-bold text-gray-900 dark:text-white flex items-center">
                            <Server className="h-6 w-6 mr-2 text-gray-500 dark:text-gray-400" />
                            {poller.poller_id}
                        </h1>
                        <div className="flex items-center mt-1">
                            {poller.is_healthy ? (
                                <div className="flex items-center text-green-600 dark:text-green-400">
                                    <CheckCircle className="h-4 w-4 mr-1" />
                                    <span className="text-sm">Healthy</span>
                                </div>
                            ) : (
                                <div className="flex items-center text-red-600 dark:text-red-400">
                                    <XCircle className="h-4 w-4 mr-1" />
                                    <span className="text-sm">Unhealthy</span>
                                </div>
                            )}
                            <span className="text-xs text-gray-500 dark:text-gray-400 ml-4 flex items-center">
                                <Clock className="h-3 w-3 mr-1" />
                                Last update: {new Date(poller.last_update).toLocaleString()}
                            </span>
                        </div>
                    </div>
                </div>

                <button
                    onClick={handleRefresh}
                    className="px-3 py-2 bg-blue-500 hover:bg-blue-600 text-white rounded-lg flex items-center transition-colors"
                    disabled={isRefreshing}
                >
                    <RefreshCw className={`h-4 w-4 mr-2 ${isRefreshing ? 'animate-spin' : ''}`} />
                    Refresh Data
                </button>
            </div>

            {/* Status Summary Cards */}
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
                {/* Total Services */}
                <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                    <h3 className="text-sm font-medium text-gray-500 dark:text-gray-400 mb-1">Total Services</h3>
                    <div className="text-2xl font-bold text-gray-900 dark:text-white">{poller.services?.length || 0}</div>
                </div>

                {/* Healthy Services */}
                <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                    <h3 className="text-sm font-medium text-gray-500 dark:text-gray-400 mb-1">Healthy Services</h3>
                    <div className="text-2xl font-bold text-green-600 dark:text-green-400">
                        {poller.services?.filter(s => s.available).length || 0}
                    </div>
                </div>

                {/* Unhealthy Services */}
                <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                    <h3 className="text-sm font-medium text-gray-500 dark:text-gray-400 mb-1">Unhealthy Services</h3>
                    <div className="text-2xl font-bold text-red-600 dark:text-red-400">
                        {poller.services?.filter(s => !s.available).length || 0}
                    </div>
                </div>

                {/* Average Response Time */}
                <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                    <h3 className="text-sm font-medium text-gray-500 dark:text-gray-400 mb-1">Avg Response Time</h3>
                    <div className="text-2xl font-bold text-gray-900 dark:text-white">
                        {(() => {
                            const icmpServices = poller.services?.filter(s => s.type === 'icmp') || [];
                            if (icmpServices.length === 0) return 'N/A';

                            const totalResponseTime = icmpServices.reduce((sum, service) => {
                                if (typeof service.details === 'string') {
                                    try {
                                        const details = JSON.parse(service.details);
                                        return sum + (details.response_time || 0);
                                    } catch {
                                        return sum;
                                    }
                                } else if (service.details && service.details.response_time) {
                                    return sum + service.details.response_time;
                                }
                                return sum;
                            }, 0);

                            const avgResponseTime = totalResponseTime / icmpServices.length;
                            return avgResponseTime > 0 ?
                                `${(avgResponseTime / 1000000).toFixed(2)}ms` : 'N/A';
                        })()}
                    </div>
                </div>
            </div>

            {/* Poller Timeline Chart (if you have history data) */}
            {history.length > 0 && (
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow overflow-hidden">
                    <div className="p-4 border-b border-gray-200 dark:border-gray-700">
                        <h2 className="text-lg font-medium text-gray-900 dark:text-white">Poller Availability History</h2>
                    </div>
                    <div className="p-4">
                        <PollerTimeline
                            pollerId={poller.poller_id}
                            initialHistory={history}
                        />
                    </div>
                </div>
            )}

            {/* Response Time Chart (for ICMP services) */}
            {responseTimeData.length > 0 && (
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow overflow-hidden">
                    <div className="p-4 border-b border-gray-200 dark:border-gray-700">
                        <h2 className="text-lg font-medium text-gray-900 dark:text-white">Response Time</h2>
                    </div>
                    <div className="p-4" style={{ height: '300px' }}>
                        <ResponsiveContainer width="100%" height="100%">
                            <AreaChart data={responseTimeData}>
                                <CartesianGrid strokeDasharray="3 3" opacity={0.3} />
                                <XAxis
                                    dataKey="timestamp"
                                    tickFormatter={formatTimestamp}
                                    type="number"
                                    domain={['dataMin', 'dataMax']}
                                />
                                <YAxis
                                    label={{ value: 'Response Time (ms)', angle: -90, position: 'insideLeft' }}
                                />
                                <Tooltip
                                    labelFormatter={(value) => new Date(Number(value)).toLocaleString()}
                                    formatter={(value: number | string) => [
                                        `${typeof value === 'number' ? value.toFixed(2) : parseFloat(value).toFixed(2)}ms`,
                                        'Response Time'
                                    ]}
                                />
                                <Legend />
                                {Object.keys(serviceMetricsMap).map((serviceName, index) => {
                                    const service = poller.services?.find(s => s.name === serviceName);
                                    if (service?.type !== 'icmp') return null;

                                    // Different colors for different services
                                    const colors = [
                                        '#8884d8', '#82ca9d', '#ffc658', '#ff8042', '#0088fe', '#00C49F'
                                    ];

                                    return (
                                        <Area
                                            key={serviceName}
                                            type="monotone"
                                            dataKey={serviceName}
                                            name={serviceName}
                                            stroke={colors[index % colors.length]}
                                            fill={colors[index % colors.length]}
                                            fillOpacity={0.2}
                                            connectNulls
                                        />
                                    );
                                })}
                            </AreaChart>
                        </ResponsiveContainer>
                    </div>
                </div>
            )}

            {/* Service List */}
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow overflow-hidden">
                <div className="p-4 border-b border-gray-200 dark:border-gray-700 flex flex-col sm:flex-row justify-between sm:items-center gap-3">
                    <h2 className="text-lg font-medium text-gray-900 dark:text-white">Services</h2>

                    <div className="flex flex-col sm:flex-row sm:items-center gap-3">
                        {/* Search input */}
                        <div className="relative">
                            <input
                                type="text"
                                placeholder="Search services..."
                                className="w-full sm:w-48 pl-9 pr-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md
                         bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100"
                                value={searchTerm}
                                onChange={(e) => setSearchTerm(e.target.value)}
                            />
                            <div className="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                                <svg className="h-5 w-5 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
                                </svg>
                            </div>
                        </div>

                        {/* Category filter dropdown */}
                        <div className="relative">
                            <button
                                type="button"
                                className="inline-flex items-center px-3 py-2 border border-gray-300 dark:border-gray-600
                        shadow-sm text-sm leading-4 font-medium rounded-md text-gray-700 dark:text-gray-300
                        bg-white dark:bg-gray-800 hover:bg-gray-50 dark:hover:bg-gray-700 focus:outline-none"
                                onClick={() => setShowFilter(!showFilter)}
                            >
                                <Filter className="h-4 w-4 mr-2" />
                                Filter: {selectedCategory.charAt(0).toUpperCase() + selectedCategory.slice(1)}
                                {showFilter ? (
                                    <ChevronUp className="ml-2 h-4 w-4" />
                                ) : (
                                    <ChevronDown className="ml-2 h-4 w-4" />
                                )}
                            </button>

                            {showFilter && (
                                <div className="origin-top-right absolute right-0 mt-2 w-48 rounded-md shadow-lg bg-white dark:bg-gray-800
                              ring-1 ring-black ring-opacity-5 z-10">
                                    <div className="py-1">
                                        {Object.keys(serviceCategories).map((category) => (
                                            <button
                                                key={category}
                                                className={`w-full text-left px-4 py-2 text-sm ${
                                                    selectedCategory === category
                                                        ? 'bg-gray-100 dark:bg-gray-700 text-gray-900 dark:text-white'
                                                        : 'text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700'
                                                }`}
                                                onClick={() => {
                                                    setSelectedCategory(category);
                                                    setShowFilter(false);
                                                }}
                                            >
                                                {category.charAt(0).toUpperCase() + category.slice(1)}
                                                <span className="ml-2 text-xs text-gray-500 dark:text-gray-400">
                          ({serviceCategories[category as keyof typeof serviceCategories].length})
                        </span>
                                            </button>
                                        ))}
                                    </div>
                                </div>
                            )}
                        </div>
                    </div>
                </div>

                {/* Service grid */}
                <div className="p-4">
                    {filteredServices.length === 0 ? (
                        <div className="text-center py-8">
                            <Activity className="h-12 w-12 mx-auto text-gray-400 mb-3" />
                            <h3 className="text-lg font-medium text-gray-900 dark:text-white">No services found</h3>
                            <p className="text-gray-500 dark:text-gray-400">
                                Try adjusting your search or filter criteria
                            </p>
                        </div>
                    ) : (
                        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                            {filteredServices.map((service) => (
                                <div
                                    key={service.name}
                                    className="bg-gray-50 dark:bg-gray-700 rounded-lg p-4"
                                >
                                    <div
                                        className="flex justify-between items-start cursor-pointer"
                                        onClick={() => toggleServiceExpand(service.name)}
                                    >
                                        <div className="flex items-center">
                                            {service.available ? (
                                                <CheckCircle className="h-5 w-5 text-green-500 mr-2" />
                                            ) : (
                                                <XCircle className="h-5 w-5 text-red-500 mr-2" />
                                            )}
                                            <div>
                                                <h3 className="font-medium text-gray-900 dark:text-white">{service.name}</h3>
                                                <span className="text-sm text-gray-500 dark:text-gray-400">{service.type}</span>
                                            </div>
                                        </div>
                                        <div className="flex items-center">
                                            {service.type === 'icmp' && serviceMetricsMap[service.name] && (
                                                <div className="mr-3 hidden sm:block">
                                                    <ServiceSparkline
                                                        pollerId={poller.poller_id}
                                                        serviceName={service.name}
                                                        initialMetrics={serviceMetricsMap[service.name]}
                                                    />
                                                </div>
                                            )}
                                            {expandedService === service.name ? (
                                                <ChevronUp className="h-5 w-5 text-gray-400" />
                                            ) : (
                                                <ChevronDown className="h-5 w-5 text-gray-400" />
                                            )}
                                        </div>
                                    </div>

                                    {/* Expanded service details */}
                                    {expandedService === service.name && (
                                        <div className="mt-4 pt-4 border-t border-gray-200 dark:border-gray-600">
                                            {/* ICMP details */}
                                            {service.type === 'icmp' && service.details && (
                                                <div className="mb-4">
                                                    <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">ICMP Status</h4>
                                                    <PingStatus details={service.details} />
                                                </div>
                                            )}

                                            {/* General service details */}
                                            {service.details && typeof service.details !== 'string' && (
                                                <div className="grid grid-cols-2 gap-3">
                                                    {Object.entries(service.details).map(([key, value]) => (
                                                        <div key={key} className="text-sm">
                              <span className="font-medium text-gray-700 dark:text-gray-300">
                                {key.split('_').map(word => word.charAt(0).toUpperCase() + word.slice(1)).join(' ')}:
                              </span>
                                                            <span className="ml-2 text-gray-900 dark:text-white">
                                {typeof value === 'boolean'
                                    ? value ? 'Yes' : 'No'
                                    : String(value)}
                              </span>
                                                        </div>
                                                    ))}
                                                </div>
                                            )}

                                            {/* JSON string details */}
                                            {service.details && typeof service.details === 'string' && service.type !== 'icmp' && (
                                                <div>
                                                    <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Details</h4>
                                                    <pre className="bg-gray-100 dark:bg-gray-800 p-2 rounded text-xs overflow-auto max-h-40">
                            {(() => {
                                try {
                                    return JSON.stringify(JSON.parse(service.details as string), null, 2);
                                } catch {
                                    return service.details;
                                }
                            })()}
                          </pre>
                                                </div>
                                            )}

                                            {/* View details button */}
                                            <div className="mt-4 flex justify-end">
                                                <button
                                                    className="px-3 py-1 bg-blue-500 hover:bg-blue-600 text-white rounded-md text-sm"
                                                    onClick={(e) => {
                                                        e.stopPropagation();
                                                        handleServiceClick(service.name);
                                                    }}
                                                >
                                                    View Service Dashboard
                                                </button>
                                            </div>
                                        </div>
                                    )}
                                </div>
                            ))}
                        </div>
                    )}
                </div>
            </div>

            {/* Last updated footer */}
            <div className="text-right text-xs text-gray-500 dark:text-gray-400">
                Last refreshed: {lastUpdated.toLocaleString()}
            </div>
        </div>
    );
};

export default PollerDetail;