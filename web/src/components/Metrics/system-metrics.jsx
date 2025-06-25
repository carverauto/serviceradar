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

import React, { useState, useEffect } from 'react';
import { RefreshCw } from 'lucide-react';
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer } from 'recharts';
import { ErrorMessage, EmptyState, LoadingState } from './error-components';
import { fetchSystemData, getCombinedChartData } from './data-service';
import { CustomTooltip } from './shared-components';
import {
    CpuCard,
    CpuChart,
    CpuCoresChart,
    MemoryCard,
    MemoryChart,
    MemoryDetails,
    FilesystemCard,
    FilesystemChart,
    FilesystemDetails,
} from './metric-components';

const SystemMetrics = ({ pollerId = 'poller-01', initialData = null }) => {
    const [data, setData] = useState(initialData);
    const [loading, setLoading] = useState(!initialData);
    const [error, setError] = useState(null);
    const [refreshing, setRefreshing] = useState(false);
    const [lastUpdated, setLastUpdated] = useState(initialData ? new Date() : null);
    const [activeTab, setActiveTab] = useState('overview');
    const [timeRange, setTimeRange] = useState('1h');

    useEffect(() => {
        if (!initialData) {
            const loadData = async () => {
                try {
                    setLoading(true);
                    const result = await fetchSystemData(pollerId, timeRange);
                    setData(result);
                    setLastUpdated(new Date());
                    setError(null);
                } catch (err) {
                    console.error('Error loading system data:', err);
                    setError('Failed to load system data');
                } finally {
                    setLoading(false);
                }
            };

            loadData();
        }

        const intervalId = setInterval(() => {
            handleRefresh();
        }, 30000);

        return () => clearInterval(intervalId);
    }, [pollerId, timeRange, initialData]);

    const handleRefresh = async () => {
        try {
            setRefreshing(true);
            const result = await fetchSystemData(pollerId, timeRange);
            setData(result);
            setLastUpdated(new Date());
            setError(null);
        } catch (err) {
            console.error('Error refreshing system data:', err);
            setError('Failed to refresh system data');
        } finally {
            setRefreshing(false);
        }
    };

    if (loading && !data) {
        return <LoadingState message="Loading system metrics data..." />;
    }

    if (error) {
        return (
            <ErrorMessage
                title="Failed to load metrics"
                message={error || "We couldn't load the system metrics. Please try again later."}
                onRetry={handleRefresh}
            />
        );
    }

    if (!data) {
        return (
            <EmptyState
                message="No system metrics data available for this poller."
                onAction={handleRefresh}
                actionLabel="Refresh"
            />
        );
    }

    const combinedChartData = getCombinedChartData(data);

    return (
        <div className="bg-white dark:bg-gray-800 rounded-lg shadow transition-colors">
            <div className="p-4 border-b border-gray-200 dark:border-gray-700">
                <div className="flex flex-wrap justify-between items-center">
                    <h2 className="text-lg font-semibold text-gray-800 dark:text-gray-100">System Metrics</h2>

                    <div className="flex items-center">
                        <div className="text-sm text-gray-600 dark:text-gray-400 mr-4">
                            <span className="mr-2">Poller: {pollerId}</span>
                            {lastUpdated && (
                                <span>Updated: {lastUpdated.toLocaleTimeString()}</span>
                            )}
                        </div>

                        <button
                            onClick={handleRefresh}
                            disabled={refreshing}
                            className="p-2 bg-gray-100 dark:bg-gray-700 rounded hover:bg-gray-200 dark:hover:bg-gray-600 text-gray-600 dark:text-gray-300 transition-colors"
                        >
                            <RefreshCw size={16} className={refreshing ? 'animate-spin' : ''} />
                        </button>
                    </div>
                </div>
            </div>

            <div className="border-b border-gray-200 dark:border-gray-700">
                <div className="flex">
                    <button
                        className={`px-4 py-2 text-sm font-medium ${
                            activeTab === 'overview'
                                ? 'border-b-2 border-blue-500 text-blue-500'
                                : 'text-gray-600 dark:text-gray-400 hover:text-gray-800 dark:hover:text-white'
                        }`}
                        onClick={() => setActiveTab('overview')}
                    >
                        Overview
                    </button>
                    <button
                        className={`px-4 py-2 text-sm font-medium ${
                            activeTab === 'trends'
                                ? 'border-b-2 border-blue-500 text-blue-500'
                                : 'text-gray-600 dark:text-gray-400 hover:text-gray-800 dark:hover:text-white'
                        }`}
                        onClick={() => setActiveTab('trends')}
                    >
                        Trends
                    </button>
                    <button
                        className={`px-4 py-2 text-sm font-medium ${
                            activeTab === 'details'
                                ? 'border-b-2 border-blue-500 text-blue-500'
                                : 'text-gray-600 dark:text-gray-400 hover:text-gray-800 dark:hover:text-white'
                        }`}
                        onClick={() => setActiveTab('details')}
                    >
                        Details
                    </button>
                </div>
            </div>

            <div className="px-4 pt-4 flex justify-end">
                <div className="bg-gray-100 dark:bg-gray-700 rounded-lg inline-flex p-1">
                    {['1h', '6h', '24h'].map((range) => (
                        <button
                            key={range}
                            onClick={() => setTimeRange(range)}
                            className={`px-3 py-1 text-sm rounded-md transition-colors ${
                                timeRange === range
                                    ? 'bg-blue-600 text-white'
                                    : 'text-gray-600 dark:text-gray-400 hover:text-gray-800 dark:hover:text-white'
                            }`}
                        >
                            {range}
                        </button>
                    ))}
                </div>
            </div>

            <div className="p-4">
                {activeTab === 'overview' && (
                    <>
                        <div className="mb-6">
                            <div className="mb-2 text-sm font-medium text-gray-600 dark:text-gray-300">All Metrics</div>
                            <div className="bg-gray-100 dark:bg-gray-700 rounded-lg p-4" style={{ height: '240px' }}>
                                <ResponsiveContainer width="100%" height="100%">
                                    <LineChart data={combinedChartData} margin={{ top: 5, right: 10, left: 0, bottom: 5 }}>
                                        <CartesianGrid strokeDasharray="3 3" stroke="#D1D5DB dark:#374151" />
                                        <XAxis
                                            dataKey="formattedTime"
                                            stroke="#6B7280"
                                            tick={{ fontSize: 12 }}
                                        />
                                        <YAxis
                                            stroke="#6B7280"
                                            tick={{ fontSize: 12 }}
                                            tickFormatter={(value) => `${value}%`}
                                            domain={[0, 100]}
                                        />
                                        <Tooltip content={(props) => <CustomTooltip {...props} metricData={data} />} />
                                        <Legend />
                                        <Line
                                            name="CPU"
                                            type="monotone"
                                            dataKey="cpu"
                                            stroke="#50FA7B"
                                            dot={false}
                                            activeDot={{ r: 5 }}
                                            isAnimationActive={false}
                                        />
                                        <Line
                                            name="Memory"
                                            type="monotone"
                                            dataKey="memory"
                                            stroke="#EC4899"
                                            dot={false}
                                            activeDot={{ r: 5 }}
                                            isAnimationActive={false}
                                        />
                                        <Line
                                            name="Disk"
                                            type="monotone"
                                            dataKey="disk"
                                            stroke="#10B981"
                                            dot={false}
                                            activeDot={{ r: 5 }}
                                            isAnimationActive={false}
                                        />
                                    </LineChart>
                                </ResponsiveContainer>
                            </div>
                        </div>

                        <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
                            <CpuCard data={data.cpu} />
                            <MemoryCard data={data.memory} />
                            <FilesystemCard data={data.disk} />
                        </div>
                    </>
                )}

                {activeTab === 'trends' && (
                    <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                        <CpuChart data={data.cpu} />
                        <MemoryChart data={data.memory} />
                        <FilesystemChart data={data.disk} />
                    </div>
                )}

                {activeTab === 'details' && (
                    <div className="space-y-6">
                        <CpuCoresChart cores={data.cpu.cores} />
                        <FilesystemDetails drives={data.disk.drives} />
                        <MemoryDetails data={data.memory} />
                    </div>
                )}
            </div>
        </div>
    );
};

export default SystemMetrics;