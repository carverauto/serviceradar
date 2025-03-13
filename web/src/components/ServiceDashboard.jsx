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

import React, { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import {
    XAxis,
    YAxis,
    Tooltip,
    Legend,
    Line,
    LineChart,
    CartesianGrid,
    ResponsiveContainer,
} from 'recharts';
import NetworkSweepView from './NetworkSweepView';
import { PingStatus } from './NetworkStatus';
import SNMPDashboard from './SNMPDashboard';
import { ArrowLeft } from 'lucide-react';

const ServiceDashboard = ({
                              nodeId,
                              serviceName,
                              initialService = null,
                              initialMetrics = [],
                              initialSnmpData = [],
                              initialError = null,
                              initialTimeRange = '1h',
                          }) => {
    const router = useRouter();
    const [serviceData] = useState(initialService);
    const [metricsData] = useState(initialMetrics);
    const [snmpData] = useState(initialSnmpData);
    const [loading] = useState(!initialService && !initialError);
    const [error] = useState(initialError);
    const [selectedTimeRange, setSelectedTimeRange] = useState(initialTimeRange);
    const [chartHeight, setChartHeight] = useState(256);

    // Adjust chart height based on screen size
    useEffect(() => {
        const handleResize = () => {
            const width = window.innerWidth;
            if (width < 640) { // small screens
                setChartHeight(200);
            } else if (width < 1024) { // medium screens
                setChartHeight(220);
            } else { // large screens
                setChartHeight(256);
            }
        };

        handleResize(); // Initial call
        window.addEventListener('resize', handleResize);
        return () => window.removeEventListener('resize', handleResize);
    }, []);

    useEffect(() => {
        return () => console.log("ServiceDashboard unmounted");
    }, [nodeId, serviceName, initialSnmpData]);

    const filterDataByTimeRange = (data, range) => {
        const now = Date.now();
        const ranges = {
            '1h': 60 * 60 * 1000,
            '6h': 6 * 60 * 60 * 1000,
            '24h': 24 * 60 * 60 * 1000,
        };
        const timeLimit = now - ranges[range];
        return data.filter((point) => new Date(point.timestamp).getTime() >= timeLimit);
    };

    const renderMetricsChart = () => {
        if (!metricsData.length) return null;

        const chartData = filterDataByTimeRange(
            metricsData.map((metric) => ({
                timestamp: new Date(metric.timestamp).getTime(),
                response_time: metric.response_time / 1000000,
            })),
            selectedTimeRange
        );

        if (chartData.length === 0) {
            return (
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 sm:p-6 transition-colors">
                    <div className="flex flex-col sm:flex-row sm:justify-between sm:items-center mb-4 gap-2">
                        <h3 className="text-lg font-semibold text-gray-800 dark:text-gray-100">Response Time</h3>
                    </div>
                    <div className="h-32 sm:h-64 flex items-center justify-center text-gray-500 dark:text-gray-400">
                        No data available for the selected time range
                    </div>
                </div>
            );
        }

        return (
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 sm:p-6 transition-colors">
                <div className="flex flex-col sm:flex-row sm:justify-between sm:items-center mb-4 gap-2">
                    <h3 className="text-lg font-semibold text-gray-800 dark:text-gray-100">Response Time</h3>
                </div>
                <div className="h-48 sm:h-64">
                    <ResponsiveContainer width="100%" height="100%">
                        <LineChart data={chartData}>
                            <CartesianGrid strokeDasharray="3 3" />
                            <XAxis
                                dataKey="timestamp"
                                type="number"
                                domain={['auto', 'auto']}
                                tickFormatter={(ts) => new Date(ts).toLocaleTimeString()}
                            />
                            <YAxis unit="ms" domain={['auto', 'auto']} />
                            <Tooltip
                                labelFormatter={(ts) => new Date(ts).toLocaleString()}
                                formatter={(value) => [`${value.toFixed(2)} ms`, 'Response Time']}
                            />
                            <Legend />
                            <Line
                                type="monotone"
                                dataKey="response_time"
                                stroke="#8884d8"
                                dot={false}
                                name="Response Time"
                                isAnimationActive={false} // Disable animation during updates
                            />
                        </LineChart>
                    </ResponsiveContainer>
                </div>
            </div>
        );
    };

    const renderServiceContent = () => {
        if (!serviceData) return null;

        if (serviceData.type === 'snmp') {
            return (
                <SNMPDashboard
                    nodeId={nodeId}
                    serviceName={serviceName}
                    initialData={snmpData}
                    initialTimeRange={initialTimeRange}
                />
            );
        }

        if (serviceData.type === 'sweep') {
            return <NetworkSweepView nodeId={nodeId} service={serviceData} standalone />;
        }

        if (serviceData.type === 'icmp') {
            return (
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 sm:p-6 transition-colors">
                    <h3 className="text-lg font-semibold mb-4 text-gray-800 dark:text-gray-100">ICMP Status</h3>
                    <PingStatus
                        details={serviceData.message}
                        nodeId={nodeId}
                        serviceName={serviceName}
                    />
                </div>
            );
        }

        let details;
        try {
            details = typeof serviceData.details === 'string'
                ? JSON.parse(serviceData.details)
                : serviceData.details;
        } catch (e) {
            console.error('Error parsing service details:', e);
            return null;
        }

        if (!details) return null;

        return (
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                {Object.entries(details)
                    .filter(([key]) => key !== 'history')
                    .map(([key, value]) => (
                        <div
                            key={key}
                            className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 sm:p-6 transition-colors"
                        >
                            <h3 className="text-lg font-semibold mb-2 text-gray-800 dark:text-gray-100">
                                {key.split('_').map((word) => word.charAt(0).toUpperCase() + word.slice(1)).join(' ')}
                            </h3>
                            <div className="text-base sm:text-lg break-all text-gray-700 dark:text-gray-100">
                                {typeof value === 'boolean' ? (value ? 'Yes' : 'No') : value}
                            </div>
                        </div>
                    ))}
            </div>
        );
    };

    if (loading) {
        return (
            <div className="space-y-4">
                <div className="flex justify-between items-center">
                    <div className="h-8 bg-gray-200 dark:bg-gray-700 rounded w-32 sm:w-64 animate-pulse"></div>
                    <div className="h-8 bg-gray-200 dark:bg-gray-700 rounded w-20 sm:w-32 animate-pulse"></div>
                </div>
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 sm:p-6">
                    <div className="h-6 bg-gray-200 dark:bg-gray-700 rounded w-24 sm:w-40 mb-4 animate-pulse"></div>
                    <div className="flex justify-between">
                        <div className="h-8 bg-gray-200 dark:bg-gray-700 rounded w-16 sm:w-24 animate-pulse"></div>
                    </div>
                </div>
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 sm:p-6">
                    <div className="h-6 bg-gray-200 dark:bg-gray-700 rounded w-24 sm:w-40 mb-4 animate-pulse"></div>
                    <div className="h-32 sm:h-64 bg-gray-100 dark:bg-gray-700 rounded animate-pulse"></div>
                </div>
            </div>
        );
    }

    if (error) {
        return (
            <div className="bg-red-50 dark:bg-red-900 p-4 sm:p-6 rounded-lg shadow text-red-600 dark:text-red-200">
                <h2 className="text-xl font-bold mb-4">Error Loading Service</h2>
                <p className="mb-4">{error}</p>
                <button
                    onClick={() => router.push('/nodes')}
                    className="mt-2 px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-800 dark:text-gray-100 hover:bg-gray-300 dark:hover:bg-gray-600 rounded transition-colors flex items-center"
                >
                    <ArrowLeft className="mr-2 h-4 w-4" />
                    Back to Nodes
                </button>
            </div>
        );
    }

    return (
        <div className="space-y-4 sm:space-y-6 transition-colors">
            <div className="flex flex-col sm:flex-row sm:justify-between sm:items-center gap-2">
                <h2 className="text-xl sm:text-2xl font-bold text-gray-800 dark:text-gray-100">
                    {serviceName} Service Status
                </h2>
                <button
                    onClick={() => router.push('/nodes')}
                    className="px-4 py-2 bg-gray-100 dark:bg-gray-700 dark:text-gray-100 hover:bg-gray-200 dark:hover:bg-gray-600 rounded transition-colors flex items-center self-start"
                >
                    <ArrowLeft className="mr-2 h-4 w-4" />
                    Back to Nodes
                </button>
            </div>
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 sm:p-6 transition-colors">
                <div className="flex items-center justify-between">
                    <h3 className="text-lg font-semibold text-gray-800 dark:text-gray-100">Service Status</h3>
                    <div
                        className={`px-3 py-1 rounded transition-colors ${
                            serviceData?.available
                                ? 'bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-100'
                                : 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-100'
                        }`}
                    >
                        {serviceData?.available ? 'Online' : 'Offline'}
                    </div>
                </div>
            </div>
            {renderMetricsChart()}
            {renderServiceContent()}
        </div>
    );
};

export default React.memo(ServiceDashboard);