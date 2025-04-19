// src/components/Metrics/system-metrics.jsx
import React, { useState, useEffect } from 'react';
import { RefreshCw, AlertTriangle } from 'lucide-react';
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer } from 'recharts';
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

    // Load initial data if no initialData is provided
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

        // Set up refresh interval
        const intervalId = setInterval(() => {
            handleRefresh();
        }, 30000); // Refresh every 30 seconds

        return () => clearInterval(intervalId);
    }, [pollerId, timeRange, initialData]);

    // Handle manual refresh
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

    // Loading state
    if (loading && !data) {
        return (
            <div className="bg-gray-900 rounded-lg shadow p-6 min-h-52 flex items-center justify-center">
                <div className="animate-pulse flex space-x-2">
                    <div className="h-3 w-3 bg-blue-400 rounded-full animate-bounce"></div>
                    <div className="h-3 w-3 bg-blue-400 rounded-full animate-bounce delay-75"></div>
                    <div className="h-3 w-3 bg-blue-400 rounded-full animate-bounce delay-150"></div>
                </div>
                <div className="ml-2 text-gray-400">Loading system data...</div>
            </div>
        );
    }

    // Error state
    if (error) {
        return (
            <div className="bg-gray-900 rounded-lg shadow p-6 text-red-500">
                <div className="flex items-center">
                    <AlertTriangle className="mr-2" />
                    {error}
                </div>
                <button
                    onClick={handleRefresh}
                    className="mt-4 px-3 py-1 bg-gray-800 text-gray-300 rounded flex items-center hover:bg-gray-700"
                >
                    <RefreshCw size={14} className={`mr-2 ${refreshing ? 'animate-spin' : ''}`} />
                    Retry
                </button>
            </div>
        );
    }

    if (!data) {
        return (
            <div className="bg-gray-900 rounded-lg shadow p-6">
                <div className="text-gray-400">No system data available</div>
            </div>
        );
    }

    // Combined chart data
    const combinedChartData = getCombinedChartData(data);

    return (
        <div className="bg-gray-900 rounded-lg shadow">
            <div className="p-4 border-b border-gray-800">
                <div className="flex flex-wrap justify-between items-center">
                    <h2 className="text-lg font-semibold text-white">System Metrics</h2>

                    <div className="flex items-center">
                        <div className="text-sm text-gray-400 mr-4">
                            <span className="mr-2">Poller: {pollerId}</span>
                            {lastUpdated && (
                                <span>Updated: {lastUpdated.toLocaleTimeString()}</span>
                            )}
                        </div>

                        <button
                            onClick={handleRefresh}
                            disabled={refreshing}
                            className="p-2 bg-gray-800 rounded hover:bg-gray-700 text-gray-300"
                        >
                            <RefreshCw size={16} className={refreshing ? 'animate-spin' : ''} />
                        </button>
                    </div>
                </div>
            </div>

            {/* Navigation tabs */}
            <div className="border-b border-gray-800">
                <div className="flex">
                    <button
                        className={`px-4 py-2 text-sm font-medium ${
                            activeTab === 'overview'
                                ? 'border-b-2 border-blue-500 text-blue-500'
                                : 'text-gray-400 hover:text-white'
                        }`}
                        onClick={() => setActiveTab('overview')}
                    >
                        Overview
                    </button>
                    <button
                        className={`px-4 py-2 text-sm font-medium ${
                            activeTab === 'trends'
                                ? 'border-b-2 border-blue-500 text-blue-500'
                                : 'text-gray-400 hover:text-white'
                        }`}
                        onClick={() => setActiveTab('trends')}
                    >
                        Trends
                    </button>
                    <button
                        className={`px-4 py-2 text-sm font-medium ${
                            activeTab === 'details'
                                ? 'border-b-2 border-blue-500 text-blue-500'
                                : 'text-gray-400 hover:text-white'
                        }`}
                        onClick={() => setActiveTab('details')}
                    >
                        Details
                    </button>
                </div>
            </div>

            {/* Time range selector */}
            <div className="px-4 pt-4 flex justify-end">
                <div className="bg-gray-800 rounded-lg inline-flex p-1">
                    {['1h', '6h', '24h'].map((range) => (
                        <button
                            key={range}
                            onClick={() => setTimeRange(range)}
                            className={`px-3 py-1 text-sm rounded-md transition-colors ${
                                timeRange === range
                                    ? 'bg-blue-600 text-white'
                                    : 'text-gray-400 hover:text-white'
                            }`}
                        >
                            {range}
                        </button>
                    ))}
                </div>
            </div>

            <div className="p-4">
                {/* Overview Tab */}
                {activeTab === 'overview' && (
                    <>
                        {/* Combined chart view */}
                        <div className="mb-6">
                            <div className="mb-2 text-sm font-medium text-gray-300">All Metrics</div>
                            <div className="bg-gray-800 rounded-lg p-4" style={{ height: '240px' }}>
                                <ResponsiveContainer width="100%" height="100%">
                                    <LineChart data={combinedChartData} margin={{ top: 5, right: 10, left: 0, bottom: 5 }}>
                                        <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
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
                                            stroke="#8B5CF6"
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

                        {/* Compact metrics summary */}
                        <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
                            <CpuCard data={data.cpu} />
                            <MemoryCard data={data.memory} />
                            <FilesystemCard data={data.disk} />
                        </div>
                    </>
                )}

                {/* Trends Tab */}
                {activeTab === 'trends' && (
                    <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                        <CpuChart data={data.cpu} />
                        <MemoryChart data={data.memory} />
                        <FilesystemChart data={data.disk} />
                    </div>
                )}

                {/* Details Tab */}
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