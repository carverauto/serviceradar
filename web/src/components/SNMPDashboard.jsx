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

import React, { useCallback, useState, useEffect } from 'react';
import { CartesianGrid, Legend, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import { useRouter, useSearchParams } from 'next/navigation';

const REFRESH_INTERVAL = 10000; // 10 seconds, matching other components

const SNMPDashboard = ({ nodeId, serviceName, initialData = [], initialTimeRange = '1h' }) => {
    const router = useRouter();
    const searchParams = useSearchParams();
    const [snmpData, setSNMPData] = useState(initialData);
    const [processedData, setProcessedData] = useState([]);
    const [timeRange, setTimeRange] = useState(searchParams.get('timeRange') || initialTimeRange);
    const [selectedMetric, setSelectedMetric] = useState(null);
    const [availableMetrics, setAvailableMetrics] = useState([]);
    const [chartHeight, setChartHeight] = useState(384); // Default height

    // Adjust chart height based on screen size
    useEffect(() => {
        const handleResize = () => {
            const width = window.innerWidth;
            if (width < 640) { // small screens
                setChartHeight(250);
            } else if (width < 1024) { // medium screens
                setChartHeight(300);
            } else { // large screens
                setChartHeight(384);
            }
        };

        handleResize(); // Initial call
        window.addEventListener('resize', handleResize);
        return () => window.removeEventListener('resize', handleResize);
    }, []);

    // Set up periodic data refresh without hard refreshes
    useEffect(() => {
        const fetchUpdatedData = async () => {
            try {
                // Use relative URL to respect Next.js API routes which handle proxying
                const end = new Date();
                const start = new Date();

                // Adjust start time based on current timeRange
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

                // Use relative URL to leverage Next.js API routes and rewrites
                const snmpUrl = `/api/nodes/${nodeId}/snmp?start=${start.toISOString()}&end=${end.toISOString()}`;

                console.log('Fetching SNMP data from:', snmpUrl);

                const response = await fetch(snmpUrl);

                if (response.ok) {
                    const newData = await response.json();
                    if (newData && Array.isArray(newData)) {
                        setSNMPData(newData);
                        console.log(`Updated SNMP data with ${newData.length} records`);
                    }
                } else {
                    console.warn('Failed to refresh SNMP data:', response.status, response.statusText);
                }
            } catch (error) {
                console.error('Error refreshing SNMP data:', error);
                // Silent fail - don't disturb the user experience on refresh errors
            }
        };

        // Don't fetch immediately if we already have initialData
        if (snmpData.length === 0) {
            fetchUpdatedData();
        }

        // Set up interval for periodic updates
        const interval = setInterval(fetchUpdatedData, REFRESH_INTERVAL);
        return () => clearInterval(interval);
    }, [nodeId, timeRange, snmpData.length]);

    // Update SNMP data when initialData changes from server
    useEffect(() => {
        if (initialData && initialData.length > 0) {
            setSNMPData(initialData);
        }
    }, [initialData]);

    // Process SNMP counter data to show rates instead of raw values
    const processCounterData = useCallback((data) => {
        if (!data || data.length < 2) return data || [];

        try {
            return data.map((point, index) => {
                if (index === 0) return { ...point, rate: 0 };

                const prevPoint = data[index - 1];
                const timeDiff = (new Date(point.timestamp) - new Date(prevPoint.timestamp)) / 1000;

                const currentValue = parseFloat(point.value) || 0;
                const prevValue = parseFloat(prevPoint.value) || 0;

                let rate = 0;
                if (currentValue >= prevValue) {
                    rate = (currentValue - prevValue) / timeDiff;
                } else {
                    // Counter wrapped, assume 32-bit counter
                    rate = ((4294967295 - prevValue) + currentValue) / timeDiff;
                }

                return {
                    ...point,
                    rate: rate,
                };
            });
        } catch (error) {
            console.error("Error processing counter data:", error);
            return data;
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

    // Process metric data when dependencies change
    useEffect(() => {
        if (snmpData.length > 0 && selectedMetric) {
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
    }, [selectedMetric, snmpData, timeRange, processCounterData]);

    const handleTimeRangeChange = (range) => {
        setTimeRange(range);
        // Update URL without full refresh
        const params = new URLSearchParams(searchParams);
        params.set('timeRange', range);
        router.push(`/service/${nodeId}/${serviceName}?${params.toString()}`, { scroll: false });
    };

    const formatRate = (rate) => {
        if (rate === undefined || rate === null || isNaN(rate)) return "N/A";
        const absRate = Math.abs(rate);
        if (absRate >= 1000000000) return `${(rate / 1000000000).toFixed(2)} GB/s`;
        else if (absRate >= 1000000) return `${(rate / 1000000).toFixed(2)} MB/s`;
        else if (absRate >= 1000) return `${(rate / 1000).toFixed(2)} KB/s`;
        else return `${rate.toFixed(2)} B/s`;
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

    if (!processedData.length && selectedMetric) {
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

    return (
        <div className="space-y-4 sm:space-y-6">
            <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                <div className="w-full sm:w-auto">
                    <select
                        value={selectedMetric || ''}
                        onChange={(e) => setSelectedMetric(e.target.value)}
                        className="w-full px-3 py-2 border rounded text-gray-800 dark:text-gray-200 dark:bg-gray-700 dark:border-gray-600"
                    >
                        {availableMetrics.map(metric => (
                            <option key={metric} value={metric}>{metric}</option>
                        ))}
                    </select>
                </div>
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

            {processedData.length > 0 && (
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4">
                    <div style={{ height: `${chartHeight}px` }}>
                        <ResponsiveContainer width="100%" height="100%">
                            <LineChart data={processedData}>
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
                                    formatter={(value, name) => [
                                        formatRate(value),
                                        name === 'rate' ? 'Transfer Rate' : name,
                                    ]}
                                />
                                <Legend />
                                <Line
                                    type="monotone"
                                    dataKey="rate"
                                    stroke="#8884d8"
                                    dot={false}
                                    name="Transfer Rate"
                                    isAnimationActive={false}
                                />
                            </LineChart>
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
                            const metricData = processCounterData(
                                snmpData.filter(item => item.oid_name === metric)
                            );
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