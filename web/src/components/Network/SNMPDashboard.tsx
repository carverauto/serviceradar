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

import React, { useCallback, useState, useEffect, useMemo, startTransition } from 'react';
import { CartesianGrid, Legend, Area, AreaChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import { useRouter, useSearchParams } from 'next/navigation';
import { AlertTriangle } from 'lucide-react';
import { SnmpDataPoint } from '@/types/snmp';
import { useAuth } from '@/components/AuthProvider';

// Define props interface
interface SNMPDashboardProps {
    pollerId: string;
    serviceName: string;
    initialData?: SnmpDataPoint[];
    initialTimeRange?: string;
    useDeviceId?: boolean; // New prop to indicate if pollerId is actually a deviceId
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

// Define type for grouped chart data
interface GroupedChartData {
    group: MetricGroup;
    data: CombinedDataPoint[];
}

// Define type for metric group
interface MetricGroup {
    baseKey: string;
    metrics: string[];
    hasPair: boolean;
}

const REFRESH_INTERVAL = 10000; // 10 seconds, matching other components

const SNMPDashboard: React.FC<SNMPDashboardProps> = ({
                                                         pollerId,
                                                         serviceName,
                                                         initialData = [],
                                                         initialTimeRange = '1h',
                                                         useDeviceId = false,
                                                     }) => {
    const router = useRouter();
    const searchParams = useSearchParams();
    const { token } = useAuth(); // Get authentication token from AuthProvider
    const [snmpData, setSNMPData] = useState<SnmpDataPoint[]>(initialData);
    const [timeRange, setTimeRange] = useState<string>(searchParams.get('timeRange') || initialTimeRange);
    const [selectedMetric, setSelectedMetric] = useState<string | null>(null);
    const [chartHeight, setChartHeight] = useState<number>(384); // Default height
    const [viewMode, setViewMode] = useState<'combined' | 'single'>('combined'); // Default to combined view
    const [selectedGroupIndex, setSelectedGroupIndex] = useState<number>(0); // For interface selection
    const [showAllInterfaces, setShowAllInterfaces] = useState<boolean>(false); // Toggle for showing all vs selected

    const availableMetrics = useMemo((): string[] => {
        if (!snmpData.length) {
            return [];
        }
        const metrics = snmpData
            .map((item) => item.oid_name)
            .filter((name): name is string => Boolean(name));
        return Array.from(new Set(metrics));
    }, [snmpData]);

    // Improved metric label formatting
    const getMetricLabel = useCallback((metric: string): string => {
        const ifMatch = metric.match(/(if)(In|Out)(Octets|Errors|Discards|Packets)_(\d+)/i);
        if (ifMatch) {
            const [, , direction, type] = ifMatch;
            return `${direction === 'In' ? '↓ Inbound' : '↑ Outbound'} ${type}`;
        }
        return metric;
    }, []);

    // Analyze the metrics to discover related pairs (reverted to original logic)
    const metricGroups = useMemo((): MetricGroup[] => {
        if (!availableMetrics.length) return [];

        const groups: { [key: string]: { metrics: string[]; isInterfaceType: boolean } } = {};
        const processedMetrics = new Set<string>();

        // Pass 1: Specifically look for global "ifInOctets" and "ifOutOctets"
        if (availableMetrics.includes("ifInOctets") && availableMetrics.includes("ifOutOctets")) {
            const baseKey = "ifOctets_global";
            groups[baseKey] = { metrics: ["ifInOctets", "ifOutOctets"].sort(), isInterfaceType: true };
            processedMetrics.add("ifInOctets");
            processedMetrics.add("ifOutOctets");
        }

        // Pass 2: Handle indexed metrics (e.g., ifInOctets_4, ifOutOctets_4)
        const indexedMetricsMap: { [key: string]: string[] } = {};
        availableMetrics.forEach(metric => {
            if (!metric || processedMetrics.has(metric)) return;

            const match = metric.match(/^(if)(In|Out)(Octets|Errors|Discards|Packets)_(\d+)$/i);
            if (match) {
                const [, prefix, , type, interfaceId] = match;
                const baseKeyForIndexed = `${prefix}${type}_${interfaceId}`;
                if (!indexedMetricsMap[baseKeyForIndexed]) {
                    indexedMetricsMap[baseKeyForIndexed] = [];
                }
                indexedMetricsMap[baseKeyForIndexed].push(metric);
                processedMetrics.add(metric);
            }
        });

        for (const [baseKey, metricsForInterface] of Object.entries(indexedMetricsMap)) {
            if (metricsForInterface.length > 0) {
                if (!groups[baseKey]) {
                    groups[baseKey] = { metrics: metricsForInterface.sort(), isInterfaceType: true };
                }
            }
        }

        // Pass 3: Add any remaining metrics as individual groups
        availableMetrics.forEach(metric => {
            if (!metric || !processedMetrics.has(metric)) {
                let alreadyGrouped = false;
                for(const groupData of Object.values(groups)){
                    if(groupData.metrics.includes(metric)){
                        alreadyGrouped = true;
                        break;
                    }
                }
                if(!alreadyGrouped){
                    groups[metric] = { metrics: [metric], isInterfaceType: false };
                }
            }
        });

        return Object.entries(groups)
            .map(([baseKey, data]) => ({
                baseKey,
                metrics: data.metrics,
                hasPair: (baseKey === "ifOctets_global" && data.metrics.length === 2) ||
                    (data.isInterfaceType && data.metrics.length >= 2 &&
                        data.metrics.some(m => m.toLowerCase().includes("in")) &&
                        data.metrics.some(m => m.toLowerCase().includes("out"))),
            }))
            .sort((a, b) => {
                const isAMainOctets = a.baseKey === "ifOctets_global";
                const isBMainOctets = b.baseKey === "ifOctets_global";
                if (isAMainOctets && !isBMainOctets) return -1;
                if (!isAMainOctets && isBMainOctets) return 1;

                const isAOctetsPair = a.baseKey.toLowerCase().includes("ifoctets") && a.hasPair;
                const isBOctetsPair = b.baseKey.toLowerCase().includes("ifoctets") && b.hasPair;
                if (isAOctetsPair && !isBOctetsPair) return -1;
                if (!isAOctetsPair && isBOctetsPair) return 1;

                if (a.hasPair && !b.hasPair) return -1;
                if (!a.hasPair && b.hasPair) return 1;

                return a.baseKey.localeCompare(b.baseKey);
            });
    }, [availableMetrics]);

    // Process SNMP counter data to show rates instead of raw values
    const processCounterData = useCallback((data: SnmpDataPoint[]): ProcessedSnmpDataPoint[] => {
        console.log('processCounterData: Input data length:', data?.length || 0);
        console.log('processCounterData: Sample data points:', data?.slice(0, 3));

        if (!data || data.length === 0) {
            console.log('processCounterData: No data provided');
            return [];
        }

        const sortedData = [...data].sort((a, b) => new Date(a.timestamp).getTime() - new Date(b.timestamp).getTime());
        console.log('processCounterData: Sorted data timestamps:', sortedData.map(p => p.timestamp));

        if (sortedData.length < 2) {
            console.log('processCounterData: Not enough data points for rate calculation, showing raw values');
            const processedRaw = sortedData.map(point => ({
                ...point,
                rate: parseFloat(point.value as string) || 0,
            }));
            console.log('processCounterData: Raw values output:', processedRaw);
            return processedRaw;
        }

        try {
            const processed = sortedData.map((point, index) => {
                if (index === 0) return { ...point, rate: 0 };

                const prevPoint = sortedData[index - 1];
                const timeDiff = (new Date(point.timestamp).getTime() - new Date(prevPoint.timestamp).getTime()) / 1000;
                console.log(`processCounterData: Point ${index} - timeDiff: ${timeDiff}s`);

                if (timeDiff <= 0) return { ...point, rate: 0 };

                const currentValue = parseFloat(point.value as string) || 0;
                const prevValue = parseFloat(prevPoint.value as string) || 0;
                console.log(`processCounterData: Point ${index} - currentValue: ${currentValue}, prevValue: ${prevValue}`);
                console.log(`processCounterData: Point ${index} - raw values: "${point.value}" -> ${currentValue}, "${prevPoint.value}" -> ${prevValue}`);

                let rate = 0;
                if (currentValue >= prevValue) {
                    rate = (currentValue - prevValue) / timeDiff;
                    console.log(`processCounterData: Point ${index} - calculated rate: ${rate}`);
                } else {
                    const is32Bit = prevValue <= 4294967295;
                    const maxVal = is32Bit ? 4294967295 : 18446744073709551615;
                    if (currentValue < prevValue && (maxVal - prevValue) > 0) {
                        rate = ((maxVal - prevValue) + currentValue) / timeDiff;
                        console.log(`processCounterData: Point ${index} - rollover rate: ${rate}`);
                    } else {
                        rate = 0;
                        console.log(`processCounterData: Point ${index} - reset detected, rate: 0`);
                    }
                }

                console.log(`processCounterData: Point ${index} - actual calculated rate: ${rate} B/s`);

                if (rate > 10000000) {
                    console.warn(`Unrealistic rate detected: ${rate} B/s at ${point.timestamp}`);
                    rate = 0;
                }

                return {
                    ...point,
                    rate,
                };
            });

            console.log('processCounterData: Final processed data sample:', processed.slice(0, 3));
            return processed;
        } catch (error) {
            console.error("Error processing counter data:", error);
            return sortedData as ProcessedSnmpDataPoint[];
        }
    }, []);

    const defaultMetric = metricGroups.length > 0 ? metricGroups[0].metrics[0] ?? null : null;

    const activeMetric = useMemo(() => {
        if (selectedMetric && availableMetrics.includes(selectedMetric)) {
            return selectedMetric;
        }
        return defaultMetric;
    }, [selectedMetric, availableMetrics, defaultMetric]);

    const timeWindowMs = useMemo(() => {
        const ranges: Record<string, number> = {
            '1h': 60 * 60 * 1000,
            '6h': 6 * 60 * 60 * 1000,
            '24h': 24 * 60 * 60 * 1000,
        };
        return ranges[timeRange] ?? 60 * 60 * 1000;
    }, [timeRange]);

    const latestTimestamp = useMemo(() => {
        if (!snmpData.length) {
            return null;
        }
        return snmpData.reduce<number | null>((latest, item) => {
            const ts = new Date(item.timestamp).getTime();
            if (!Number.isFinite(ts)) {
                return latest;
            }
            if (latest === null || ts > latest) {
                return ts;
            }
            return latest;
        }, null);
    }, [snmpData]);

    const timeFilteredData = useMemo(() => {
        if (!snmpData.length || latestTimestamp === null) {
            return snmpData;
        }
        const windowStart = latestTimestamp - timeWindowMs;
        return snmpData.filter((item) => {
            const ts = new Date(item.timestamp).getTime();
            return Number.isFinite(ts) && ts >= windowStart && ts <= latestTimestamp;
        });
    }, [snmpData, latestTimestamp, timeWindowMs]);

    const processedData = useMemo(() => {
        if (!activeMetric) {
            return [];
        }
        const metricData = timeFilteredData.filter((item) => item.oid_name === activeMetric);
        return processCounterData(metricData);
    }, [activeMetric, timeFilteredData, processCounterData]);

    const combinedData = useMemo(() => {
        if (!metricGroups.length) {
            return [];
        }
        return metricGroups.map((group) => {
            const allMetricsData: { [key: number]: CombinedDataPoint } = {};

            group.metrics.forEach((metric) => {
                const metricData = timeFilteredData.filter((item) => item.oid_name === metric);
                const processed = processCounterData(metricData);

                processed.forEach((point) => {
                    const timestamp = new Date(point.timestamp).getTime();
                    const roundedTimestamp = Math.round(timestamp / 10000) * 10000;
                    if (!allMetricsData[roundedTimestamp]) {
                        allMetricsData[roundedTimestamp] = { timestamp: roundedTimestamp };
                    }
                    allMetricsData[roundedTimestamp][metric] = point.rate || 0;
                });
            });

            return {
                group,
                data: Object.values(allMetricsData).sort((a, b) => a.timestamp - b.timestamp),
            };
        });
    }, [metricGroups, timeFilteredData, processCounterData]);

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

                const snmpUrl = useDeviceId 
                    ? `/api/devices/${pollerId}/metrics?type=snmp&start=${start.toISOString()}&end=${end.toISOString()}`
                    : `/api/pollers/${pollerId}/snmp?start=${start.toISOString()}&end=${end.toISOString()}`;
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
                    const rawData = await response.json();
                    if (Array.isArray(rawData)) {
                        // Transform device metrics data to match expected format if using device endpoint
                        const transformedData = useDeviceId ? rawData.map(item => ({
                            ...item,
                            oid_name: item.if_index !== undefined ? `${item.name}_${item.if_index}` : item.name
                        })) : rawData;
                        setSNMPData(transformedData);
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
    }, [pollerId, timeRange, snmpData.length, token, useDeviceId]);

    // Update SNMP data when initialData changes from server
    useEffect(() => {
        if (initialData && initialData.length > 0) {
            startTransition(() => {
                setSNMPData(initialData);
            });
        }
    }, [initialData]);

    const handleTimeRangeChange = (range: string) => {
        setTimeRange(range);
        const params = new URLSearchParams(searchParams.toString());
        params.set('timeRange', range);
        router.push(`/service/${pollerId}/${serviceName}?${params.toString()}`, { scroll: false });
    };

    const formatRate = (rate: number | undefined | null): string => {
        if (rate === undefined || rate === null || isNaN(rate)) return "N/A";
        const absRate = Math.abs(rate);
        if (absRate >= 1000000000) return `${(rate / 1000000000).toFixed(2)} GB/s`;
        else if (absRate >= 1000000) return `${(rate / 1000000).toFixed(2)} MB/s`;
        else if (absRate >= 1000) return `${(rate / 1000).toFixed(2)} KB/s`;
        else if (absRate >= 1) return `${rate.toFixed(2)} B/s`;
        else if (absRate > 0) return `${(rate * 1000000).toFixed(0)} (scaled)`;
        else return "0.00 B/s";
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

    if (viewMode === 'single' && !processedData.length && activeMetric) {
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
                            value={activeMetric || ''}
                            onChange={(e) => setSelectedMetric(e.target.value)}
                            className="px-3 py-1 border rounded text-sm text-gray-800 dark:text-gray-200 dark:bg-gray-700 dark:border-gray-600"
                        >
                            {availableMetrics.map(metric => (
                                <option key={metric} value={metric}>{getMetricLabel(metric)}</option>
                            ))}
                        </select>
                    )}

                    {viewMode === 'combined' && metricGroups.length > 0 && (
                        <div className="flex items-center gap-4">
                            <div className="text-xs italic text-gray-500 dark:text-gray-400">
                                {metricGroups.length} interface{metricGroups.length > 1 ? 's' : ''} available
                            </div>
                            
                            {metricGroups.length > 1 && (
                                <div className="flex items-center gap-2">
                                    <label className="text-xs text-gray-600 dark:text-gray-400">
                                        Show:
                                    </label>
                                    <select
                                        value={showAllInterfaces ? 'all' : selectedGroupIndex.toString()}
                                        onChange={(e) => {
                                            if (e.target.value === 'all') {
                                                setShowAllInterfaces(true);
                                            } else {
                                                setShowAllInterfaces(false);
                                                setSelectedGroupIndex(parseInt(e.target.value));
                                            }
                                        }}
                                        className="px-2 py-1 border rounded text-xs text-gray-800 dark:text-gray-200 dark:bg-gray-700 dark:border-gray-600"
                                    >
                                        <option value="all">All Interfaces (first {Math.min(5, metricGroups.length)})</option>
                                        {metricGroups.map((group, index) => (
                                            <option key={index} value={index.toString()}>
                                                {group.baseKey === "ifOctets_global" ? "Global Interface" : 
                                                 group.baseKey.includes("ifOctets") ? `Interface ${group.baseKey.split('_')[1]}` :
                                                 group.baseKey}
                                            </option>
                                        ))}
                                    </select>
                                </div>
                            )}
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
                <div className="space-y-4">
                    {/* Show warning if there are many interfaces */}
                    {metricGroups.length > 50 && showAllInterfaces && (
                        <div className="bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg p-4">
                            <div className="flex items-center gap-2">
                                <AlertTriangle className="h-5 w-5 text-yellow-600 dark:text-yellow-400" />
                                <div className="text-sm text-yellow-800 dark:text-yellow-200">
                                    <p className="font-medium">Performance Warning</p>
                                    <p>Showing {metricGroups.length} interfaces. Consider selecting a specific interface for better performance.</p>
                                </div>
                            </div>
                        </div>
                    )}
                    
                    {/* Render charts based on selection */}
                    {(() => {
                        if (showAllInterfaces) {
                            // Limit to first 5 interfaces for performance
                            const limitedData = combinedData.slice(0, 5);
                            return limitedData.map((groupData) => (
                                <div key={groupData.group.baseKey} className="bg-white dark:bg-gray-800 rounded-lg shadow p-4">
                                    <div className="mb-3">
                                        <h4 className="text-lg font-medium text-gray-800 dark:text-gray-200">
                                            {groupData.group.baseKey === "ifOctets_global" ? "Global Interface Metrics" : 
                                             groupData.group.baseKey.includes("ifOctets") ? `Interface ${groupData.group.baseKey.split('_')[1]} Metrics` :
                                             groupData.group.baseKey}
                                        </h4>
                                        <p className="text-sm text-gray-600 dark:text-gray-400">
                                            {groupData.group.metrics.map(metric => getMetricLabel(metric)).join(' + ')}
                                        </p>
                                    </div>
                                    <div style={{ height: `${chartHeight}px` }}>
                                        <ResponsiveContainer width="100%" height="100%">
                                            <AreaChart data={groupData.data}>
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
                                                {groupData.group.metrics
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
                                                                connectNulls={true} // Smooth out gaps
                                                            />
                                                        );
                                                    })}
                                            </AreaChart>
                                        </ResponsiveContainer>
                                    </div>
                                </div>
                            ));
                        } else {
                            // Show only selected interface
                            const selectedGroupData = combinedData[selectedGroupIndex];
                            if (!selectedGroupData) return null;
                            
                            return (
                                <div key={selectedGroupData.group.baseKey} className="bg-white dark:bg-gray-800 rounded-lg shadow p-4">
                                    <div className="mb-3">
                                        <h4 className="text-lg font-medium text-gray-800 dark:text-gray-200">
                                            {selectedGroupData.group.baseKey === "ifOctets_global" ? "Global Interface Metrics" : 
                                             selectedGroupData.group.baseKey.includes("ifOctets") ? `Interface ${selectedGroupData.group.baseKey.split('_')[1]} Metrics` :
                                             selectedGroupData.group.baseKey}
                                        </h4>
                                        <p className="text-sm text-gray-600 dark:text-gray-400">
                                            {selectedGroupData.group.metrics.map(metric => getMetricLabel(metric)).join(' + ')}
                                        </p>
                                    </div>
                                    <div style={{ height: `${chartHeight}px` }}>
                                        <ResponsiveContainer width="100%" height="100%">
                                            <AreaChart data={selectedGroupData.data}>
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
                                                {selectedGroupData.group.metrics
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
                                                                connectNulls={true} // Smooth out gaps
                                                            />
                                                        );
                                                    })}
                                            </AreaChart>
                                        </ResponsiveContainer>
                                    </div>
                                </div>
                            );
                        }
                    })()}
                    
                    {/* Show pagination info if there are more interfaces */}
                    {showAllInterfaces && metricGroups.length > 5 && (
                        <div className="bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg p-4">
                            <div className="text-sm text-blue-800 dark:text-blue-200">
                                <p className="font-medium">Showing first 5 of {metricGroups.length} interfaces</p>
                                <p>Use the interface selector above to view specific interfaces, or consider filtering your data source.</p>
                            </div>
                        </div>
                    )}
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
