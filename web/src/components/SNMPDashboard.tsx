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

import React, { useCallback, useState, useEffect, useMemo } from 'react';
import { CartesianGrid, Legend, Area, AreaChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import { useRouter, useSearchParams } from 'next/navigation';
import { SnmpDataPoint } from '@/types/snmp';
import { useAuth } from '@/components/AuthProvider';

// Define props interface
interface SNMPDashboardProps {
    nodeId: string;
    serviceName: string;
    initialData?: SnmpDataPoint[];
    initialTimeRange?: string;
}

// Define types for processed data
interface ProcessedSnmpDataPoint extends SnmpDataPoint {
    rate: number;
}

// Define type for combined data
interface CombinedDataPoint {
    timestamp: number;
    [key: string]: number; // Dynamic metric keys with rate values
}

// Define type for metric group
interface MetricGroup {
    baseKey: string;
    metrics: string[];
    hasPair: boolean;
}

const REFRESH_INTERVAL = 10000; // 10 seconds, matching other components

const SNMPDashboard: React.FC<SNMPDashboardProps> = ({
                                                         nodeId,
                                                         serviceName,
                                                         initialData = [],
                                                         initialTimeRange = '1h',
                                                     }) => {
    const router = useRouter();
    const searchParams = useSearchParams();
    const { token } = useAuth(); // Get authentication token from AuthProvider
    const [snmpData, setSNMPData] = useState<SnmpDataPoint[]>(initialData);
    const [processedData, setProcessedData] = useState<ProcessedSnmpDataPoint[]>([]);
    const [combinedData, setCombinedData] = useState<CombinedDataPoint[]>([]);
    const [timeRange, setTimeRange] = useState<string>(searchParams.get('timeRange') || initialTimeRange);
    const [selectedMetric, setSelectedMetric] = useState<string | null>(null);
    const [availableMetrics, setAvailableMetrics] = useState<string[]>([]);
    const [chartHeight, setChartHeight] = useState<number>(384); // Default height
    const [viewMode, setViewMode] = useState<'combined' | 'single'>('combined'); // Default to combined view

    // Improved metric label formatting
    const getMetricLabel = useCallback((metric: string): string => {
        const ifMatch = metric.match(/(if)(In|Out)(Octets|Errors|Discards|Packets)_(\d+)/i);
        if (ifMatch) {
            const [, , direction, type] = ifMatch;
            return `${direction === 'In' ? '↓ Inbound' : '↑ Outbound'} ${type}`;
        }
        return metric;
    }, []);

    // Analyze the metrics to discover related pairs
    const metricGroups = useMemo((): MetricGroup[] => {
        if (!availableMetrics.length) return [];

        const groups: { [key: string]: string[] } = {};

        availableMetrics.forEach((metric) => {
            const match = metric.match(/(if)(In|Out)(Octets|Errors|Discards|Packets)_(\d+)/i);
            if (match) {
                const [, prefix, , type, interface_id] = match;
                const baseKey = `${prefix}${type}_${interface_id}`;
                if (!groups[baseKey]) {
                    groups[baseKey] = [];
                }
                groups[baseKey].push(metric);
                return;
            }

            if (!Object.values(groups).flat().includes(metric)) {
                groups[metric] = [metric];
            }
        });

        return Object.entries(groups)
            .map(([baseKey, metrics]) => ({
                baseKey,
                metrics,
                hasPair: metrics.length > 1,
            }))
            .sort((a, b) => (b.hasPair ? 1 : 0) - (a.hasPair ? 1 : 0));
    }, [availableMetrics]);

    // Adjust chart height based on screen size
    useEffect(() => {
        const handleResize = () => {
            const width = window.innerWidth;
            if (width < 640) {
                setChartHeight(250);
            } else if (width < 1024) {
                setChartHeight(300);
            } else {
                setChartHeight(384);
            }
        };

        handleResize();
        window.addEventListener('resize', handleResize);
        return () => window.removeEventListener('resize', handleResize);
    }, []);

    // Set up periodic data refresh
    useEffect(() => {
        const fetchUpdatedData = async () => {
            try {
                const end = new Date();
                const start = new Date();

                switch (timeRange) {
                    case '1h':
                        start.setHours(end.getHours() - 1);
                        break;
                    case '6h':
                        start.setHours(end.getHours() - 6);
                        break;
                    case '24h':
                        start.setHours(end.getHours() - 24);
                        break;
                    default:
                        start.setHours(end.getHours() - 1);
                }

                // Use the Next.js API routes instead of direct calls
                const snmpUrl = `/api/nodes/${nodeId}/snmp?start=${start.toISOString()}&end=${end.toISOString()}`;

                // Include the authorization token
                const headers: HeadersInit = {
                    'Content-Type': 'application/json',
                };

                if (token) {
                    headers['Authorization'] = `Bearer ${token}`;
                }

                const response = await fetch(snmpUrl, {
                    headers,
                    cache: 'no-store',
                });

                if (response.ok) {
                    const newData: SnmpDataPoint[] = await response.json();
                    if (Array.isArray(newData)) {
                        setSNMPData(newData);
                    }
                } else {
                    console.warn('Failed to refresh SNMP data:', response.status, response.statusText);
                }
            } catch (error) {
                console.error('Error refreshing SNMP data:', error);
            }
        };

        if (snmpData.length === 0) {
            fetchUpdatedData();
        }

        const interval = setInterval(fetchUpdatedData, REFRESH_INTERVAL);
        return () => clearInterval(interval);
    }, [nodeId, timeRange, snmpData.length, token]);

    // Update SNMP data when initialData changes from server
    useEffect(() => {
        if (initialData && initialData.length > 0) {
            setSNMPData(initialData);
        }
    }, [initialData]);

    // Process SNMP counter data to show rates instead of raw values
    const processCounterData = useCallback((data: SnmpDataPoint[]): ProcessedSnmpDataPoint[] => {
        if (!data || data.length < 2) return data as ProcessedSnmpDataPoint[] || [];

        try {
            return data.map((point, index) => {
                if (index === 0) return { ...point, rate: 0 };

                const prevPoint = data[index - 1];
                const timeDiff = (new Date(point.timestamp).getTime() - new Date(prevPoint.timestamp).getTime()) / 1000;
                if (timeDiff <= 0) return { ...point, rate: 0 };

                const currentValue = parseFloat(point.value as string) || 0;
                const prevValue = parseFloat(prevPoint.value as string) || 0;

                let rate = 0;
                if (currentValue >= prevValue) {
                    rate = (currentValue - prevValue) / timeDiff;
                } else {
                    const is32Bit = prevValue < 4294967295;
                    const maxVal = is32Bit ? 4294967295 : Number.MAX_SAFE_INTEGER;
                    rate = ((maxVal - prevValue) + currentValue) / timeDiff;
                }

                return {
                    ...point,
                    rate,
                };
            });
        } catch (error) {
            console.error("Error processing counter data:", error);
            return data as ProcessedSnmpDataPoint[];
        }
    }, []);

    // Initialize metrics and selection
    useEffect(() => {
        if (snmpData.length > 0) {
            const metrics = [...new Set(snmpData.map(item => item.oid_name))];
            setAvailableMetrics(metrics);

            if (!selectedMetric && metrics.length > 0) {
                setSelectedMetric(metrics[0]);
            }
        }
    }, [snmpData, selectedMetric]);

    // Process data for single metric view
    useEffect(() => {
        if (snmpData.length > 0 && selectedMetric && viewMode === 'single') {
            try {
                const end = new Date();
                const start = new Date();
                switch (timeRange) {
                    case '1h':
                        start.setHours(end.getHours() - 1);
                        break;
                    case '6h':
                        start.setHours(end.getHours() - 6);
                        break;
                    case '24h':
                        start.setHours(end.getHours() - 24);
                        break;
                    default:
                        start.setHours(end.getHours() - 1);
                }

                const timeFilteredData = snmpData.filter(item => {
                    const timestamp = new Date(item.timestamp);
                    return timestamp >= start && timestamp <= end;
                });

                const metricData = timeFilteredData.filter(item => item.oid_name === selectedMetric);
                const processed = processCounterData(metricData);
                setProcessedData(processed);
            } catch (err) {
                console.error('Error processing metric data:', err);
            }
        }
    }, [selectedMetric, snmpData, timeRange, processCounterData, viewMode]);

    // Process data for combined view
    useEffect(() => {
        if (snmpData.length > 0 && viewMode === 'combined' && metricGroups.length > 0) {
            try {
                const end = new Date();
                const start = new Date();
                switch (timeRange) {
                    case '1h':
                        start.setHours(end.getHours() - 1);
                        break;
                    case '6h':
                        start.setHours(end.getHours() - 6);
                        break;
                    case '24h':
                        start.setHours(end.getHours() - 24);
                        break;
                    default:
                        start.setHours(end.getHours() - 1);
                }

                const timeFilteredData = snmpData.filter(item => {
                    const timestamp = new Date(item.timestamp);
                    return timestamp >= start && timestamp <= end;
                });

                const activeGroup = metricGroups[0];
                const metricsToShow = activeGroup.metrics;

                const allMetricsData: { [key: number]: CombinedDataPoint } = {};

                metricsToShow.forEach(metric => {
                    const metricData = timeFilteredData.filter(item => item.oid_name === metric);
                    const processed = processCounterData(metricData);

                    processed.forEach(point => {
                        const timestamp = new Date(point.timestamp).getTime();
                        if (!allMetricsData[timestamp]) {
                            allMetricsData[timestamp] = { timestamp };
                        }
                        allMetricsData[timestamp][metric] = point.rate || 0;
                    });
                });

                const combinedArray = Object.values(allMetricsData)
                    .sort((a, b) => a.timestamp - b.timestamp);

                setCombinedData(combinedArray);

                if (metricsToShow.length > 0 && (!selectedMetric || !metricsToShow.includes(selectedMetric))) {
                    setSelectedMetric(metricsToShow[0]);
                }
            } catch (err) {
                console.error('Error processing combined data:', err);
            }
        }
    }, [snmpData, timeRange, viewMode, processCounterData, metricGroups, selectedMetric]);

    const handleTimeRangeChange = (range: string) => {
        setTimeRange(range);
        const params = new URLSearchParams(searchParams.toString());
        params.set('timeRange', range);
        router.push(`/service/${nodeId}/${serviceName}?${params.toString()}`, { scroll: false });
    };

    const formatRate = (rate: number | undefined | null): string => {
        if (rate === undefined || rate === null || isNaN(rate)) return "N/A";
        const absRate = Math.abs(rate);
        if (absRate >= 1000000000) return `${(rate / 1000000000).toFixed(2)} GB/s`;
        else if (absRate >= 1000000) return `${(rate / 1000000).toFixed(2)} MB/s`;
        else if (absRate >= 1000) return `${(rate / 1000).toFixed(2)} KB/s`;
        else return `${rate.toFixed(2)} B/s`;
    };

    const getMetricColor = (metric: string, index: number): { stroke: string; fill: string } => {
        if (metric.includes('In')) {
            return { stroke: '#4f46e5', fill: '#818cf8' };
        }
        if (metric.includes('Out')) {
            return { stroke: '#22c55e', fill: '#86efac' };
        }

        const colorPalette = [
            { stroke: '#4f46e5', fill: '#818cf8' }, // Indigo
            { stroke: '#22c55e', fill: '#86efac' }, // Green
            { stroke: '#ef4444', fill: '#fca5a5' }, // Red
            { stroke: '#f59e0b', fill: '#fcd34d' }, // Amber
            { stroke: '#06b6d4', fill: '#67e8f9' }, // Cyan
            { stroke: '#8b5cf6', fill: '#c4b5fd' }, // Purple
        ];

        return colorPalette[index % colorPalette.length];
    };

    if (!snmpData.length) {
        return (
            <div className="bg-white dark:bg-gray-800 p-4 sm:p-6 rounded-lg shadow">
                <h3 className="text-lg font-semibold mb-4 text-gray-800 dark:text-gray-200">
                    No SNMP Data Available
                </h3>
                <p className="text-gray-600 dark:text-gray-400">
                    No metrics found for this service.
                </p>
            </div>
        );
    }

    if (viewMode === 'single' && !processedData.length && selectedMetric) {
        return (
            <div className="bg-white dark:bg-gray-800 p-4 sm:p-6 rounded-lg shadow">
                <h3 className="text-lg font-semibold mb-4 text-gray-800 dark:text-gray-200">
                    No Data Available
                </h3>
                <p className="text-gray-600 dark:text-gray-400">
                    No metrics found for the selected time range and OID.
                </p>
                <div className="mt-4">
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
                        Select Time Range
                    </label>
                    <div className="flex gap-2">
                        {['1h', '6h', '24h'].map((range) => (
                            <button
                                key={range}
                                onClick={() => handleTimeRangeChange(range)}
                                className={`px-3 py-1 rounded transition-colors ${
                                    timeRange === range
                                        ? 'bg-blue-500 text-white'
                                        : 'bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-100'
                                }`}
                            >
                                {range}
                            </button>
                        ))}
                    </div>
                </div>
            </div>
        );
    }

    if (viewMode === 'combined' && !combinedData.length && metricGroups.length > 0) {
        return (
            <div className="bg-white dark:bg-gray-800 p-4 sm:p-6 rounded-lg shadow">
                <h3 className="text-lg font-semibold mb-4 text-gray-800 dark:text-gray-200">
                    No Combined Data Available
                </h3>
                <p className="text-gray-600 dark:text-gray-400">
                    No related metrics found for the selected time range.
                </p>
                <div className="mt-4">
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
                        Select Time Range
                    </label>
                    <div className="flex gap-2">
                        {['1h', '6h', '24h'].map((range) => (
                            <button
                                key={range}
                                onClick={() => handleTimeRangeChange(range)}
                                className={`px-3 py-1 rounded transition-colors ${
                                    timeRange === range
                                        ? 'bg-blue-500 text-white'
                                        : 'bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-100'
                                }`}
                            >
                                {range}
                            </button>
                        ))}
                    </div>
                </div>
            </div>
        );
    }

    return (
        <div className="space-y-4 sm:space-y-6">
            <div className="flex flex-row items-center justify-between gap-3 bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                <div className="flex items-center gap-3">
                    <div className="flex items-center">
                        <label className="relative inline-flex items-center cursor-pointer">
                            <input
                                type="checkbox"
                                checked={viewMode === 'combined'}
                                onChange={() => setViewMode(viewMode === 'combined' ? 'single' : 'combined')}
                                className="sr-only peer"
                            />
                            <div className="w-11 h-6 bg-gray-200 peer-focus:outline-none peer-focus:ring-2 peer-focus:ring-blue-300 dark:peer-focus:ring-blue-800 rounded-full peer dark:bg-gray-700 peer-checked:after:translate-x-full peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:border-gray-300 after:border after:rounded-full after:h-5 after:w-5 after:transition-all dark:border-gray-600 peer-checked:bg-blue-500"></div>
                            <span className="ml-2 text-sm font-medium text-gray-800 dark:text-gray-300">
                {viewMode === 'combined' ? 'Combined' : 'Single'}
              </span>
                        </label>
                    </div>

                    {viewMode === 'single' && (
                        <select
                            value={selectedMetric || ''}
                            onChange={(e) => setSelectedMetric(e.target.value)}
                            className="px-3 py-1 border rounded text-sm text-gray-800 dark:text-gray-200 dark:bg-gray-700 dark:border-gray-600"
                        >
                            {availableMetrics.map(metric => (
                                <option key={metric} value={metric}>{getMetricLabel(metric)}</option>
                            ))}
                        </select>
                    )}

                    {viewMode === 'combined' && metricGroups.length > 0 && (
                        <div className="text-xs italic text-gray-500 dark:text-gray-400">
                            {metricGroups[0].metrics.map(metric => getMetricLabel(metric)).join(' + ')}
                        </div>
                    )}
                </div>

                <div className="flex items-center">
                    <div className="bg-gray-100 dark:bg-gray-700 rounded-lg flex text-sm">
                        {['1h', '6h', '24h'].map((range) => (
                            <button
                                key={range}
                                onClick={() => handleTimeRangeChange(range)}
                                className={`px-2 py-1 transition-colors rounded-lg ${
                                    timeRange === range
                                        ? 'bg-blue-500 text-white'
                                        : 'text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600'
                                }`}
                            >
                                {range}
                            </button>
                        ))}
                    </div>
                </div>
            </div>

            {viewMode === 'combined' && combinedData.length > 0 && (
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4">
                    <div style={{ height: `${chartHeight}px` }}>
                        <ResponsiveContainer width="100%" height="100%">
                            <AreaChart data={combinedData}>
                                <CartesianGrid strokeDasharray="3 3" />
                                <XAxis
                                    dataKey="timestamp"
                                    tickFormatter={(ts) => new Date(ts).toLocaleTimeString()}
                                />
                                <YAxis
                                    tickFormatter={(value) => formatRate(value)}
                                    domain={['auto', 'auto']}
                                    scale="linear"
                                />
                                <Tooltip
                                    labelFormatter={(ts) => new Date(ts).toLocaleString()}
                                    formatter={(value: number, name: string) => [
                                        formatRate(value),
                                        getMetricLabel(name),
                                    ]}
                                />
                                <Legend formatter={(value) => getMetricLabel(value)} />
                                {metricGroups[0]?.metrics
                                    .sort((a, b) => (a.includes('In') && !b.includes('In') ? 1 : !a.includes('In') && b.includes('In') ? -1 : 0))
                                    .map((metric, index) => {
                                        const colors = getMetricColor(metric, index);
                                        return (
                                            <Area
                                                key={metric}
                                                type="monotone"
                                                dataKey={metric}
                                                stroke={colors.stroke}
                                                fill={colors.fill}
                                                stackId="1"
                                                name={metric}
                                                isAnimationActive={false}
                                            />
                                        );
                                    })}
                            </AreaChart>
                        </ResponsiveContainer>
                    </div>
                </div>
            )}

            {viewMode === 'single' && processedData.length > 0 && (
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4">
                    <div style={{ height: `${chartHeight}px` }}>
                        <ResponsiveContainer width="100%" height="100%">
                            <AreaChart data={processedData}>
                                <CartesianGrid strokeDasharray="3 3" />
                                <XAxis
                                    dataKey="timestamp"
                                    tickFormatter={(ts) => new Date(ts).toLocaleTimeString()}
                                />
                                <YAxis
                                    tickFormatter={(value) => formatRate(value)}
                                    domain={['auto', 'auto']}
                                    scale="linear"
                                />
                                <Tooltip
                                    labelFormatter={(ts) => new Date(ts).toLocaleString()}
                                    formatter={(value: number, name: string) => [
                                        formatRate(value),
                                        name === 'rate' ? 'Transfer Rate' : name,
                                    ]}
                                />
                                <Legend />
                                <Area
                                    type="monotone"
                                    dataKey="rate"
                                    stroke="#8884d8"
                                    fill="#8884d8"
                                    fillOpacity={0.6}
                                    name="Transfer Rate"
                                    isAnimationActive={false}
                                />
                            </AreaChart>
                        </ResponsiveContainer>
                    </div>
                </div>
            )}

            <div className="bg-white dark:bg-gray-800 rounded-lg shadow overflow-x-auto">
                <div className="p-4 sm:hidden text-gray-700 dark:text-gray-300 text-sm">
                    <p>Swipe left/right to view all metrics data</p>
                </div>
                <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                    <thead className="bg-gray-50 dark:bg-gray-700">
                    <tr>
                        <th className="px-4 sm:px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                            Metric Name
                        </th>
                        <th className="px-4 sm:px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                            Current Rate
                        </th>
                        <th className="px-4 sm:px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                            Last Update
                        </th>
                    </tr>
                    </thead>
                    <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                    {availableMetrics.map(metric => {
                        try {
                            const metricData = processCounterData(snmpData.filter(item => item.oid_name === metric));
                            if (!metricData || !metricData.length) return null;
                            const latestDataPoint = metricData[metricData.length - 1];
                            return latestDataPoint ? (
                                <tr key={metric}>
                                    <td className="px-4 sm:px-6 py-4 whitespace-nowrap text-sm text-gray-800 dark:text-gray-200">
                                        {metric}
                                    </td>
                                    <td className="px-4 sm:px-6 py-4 whitespace-nowrap text-sm text-gray-800 dark:text-gray-200">
                                        {formatRate(latestDataPoint.rate)}
                                    </td>
                                    <td className="px-4 sm:px-6 py-4 whitespace-nowrap text-sm text-gray-800 dark:text-gray-200">
                                        {new Date(latestDataPoint.timestamp).toLocaleString()}
                                    </td>
                                </tr>
                            ) : null;
                        } catch (err) {
                            console.error(`Error processing metric ${metric}:`, err);
                            return null;
                        }
                    })}
                    </tbody>
                </table>
            </div>
        </div>
    );
};

export default SNMPDashboard;