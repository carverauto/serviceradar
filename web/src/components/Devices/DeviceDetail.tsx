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
import { Device } from '@/types/devices';
import { 
    Server, 
    CheckCircle, 
    XCircle, 
    Activity,
    Network,
    HardDrive,
    Cpu,
    BarChart3,
    Clock,
    MapPin,
    Loader2,
    AlertTriangle,
    ArrowLeft,
    TrendingUp
} from 'lucide-react';
import Link from 'next/link';
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, Legend } from 'recharts';

interface TimeseriesMetric {
    name: string;
    type: string;
    value: string;
    timestamp: string;
    target_device_ip: string;
    device_id: string;
    partition: string;
    poller_id: string;
    metadata: string;
}

interface DeviceDetailProps {
    deviceId: string;
}

const MetricCard = ({ 
    title, 
    value, 
    icon, 
    color = "blue",
    subtitle 
}: { 
    title: string; 
    value: string | number; 
    icon: React.ReactNode; 
    color?: string;
    subtitle?: string;
}) => (
    <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 p-4 rounded-lg">
        <div className="flex items-center">
            <div className={`p-2 bg-${color}-100 dark:bg-gray-700/50 rounded-md mr-4 text-${color}-600 dark:text-${color}-400`}>
                {icon}
            </div>
            <div className="flex-1">
                <p className="text-sm text-gray-600 dark:text-gray-400">{title}</p>
                <p className="text-2xl font-bold text-gray-900 dark:text-white">{value}</p>
                {subtitle && (
                    <p className="text-xs text-gray-500 dark:text-gray-500">{subtitle}</p>
                )}
            </div>
        </div>
    </div>
);

const DeviceDetail: React.FC<DeviceDetailProps> = ({ deviceId }) => {
    const { token } = useAuth();
    const [device, setDevice] = useState<Device | null>(null);
    const [metrics, setMetrics] = useState<TimeseriesMetric[]>([]);
    const [loading, setLoading] = useState(true);
    const [metricsLoading, setMetricsLoading] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const [selectedMetricType, setSelectedMetricType] = useState<string>('all');
    const [timeRange, setTimeRange] = useState<string>('24h');

    const fetchDevice = useCallback(async () => {
        setLoading(true);
        setError(null);
        try {
            const response = await fetch(`/api/devices/${encodeURIComponent(deviceId)}`, {
                headers: {
                    ...(token && { Authorization: `Bearer ${token}` }),
                },
                cache: 'no-store',
            });

            if (!response.ok) {
                throw new Error(`Failed to fetch device: ${response.status}`);
            }

            const deviceData = await response.json();
            setDevice(deviceData);
        } catch (e) {
            setError(e instanceof Error ? e.message : "Failed to fetch device");
        } finally {
            setLoading(false);
        }
    }, [deviceId, token]);

    const fetchMetrics = useCallback(async () => {
        setMetricsLoading(true);
        try {
            // Calculate time range
            const end = new Date();
            const start = new Date();
            switch (timeRange) {
                case '1h':
                    start.setHours(start.getHours() - 1);
                    break;
                case '6h':
                    start.setHours(start.getHours() - 6);
                    break;
                case '24h':
                    start.setHours(start.getHours() - 24);
                    break;
                case '7d':
                    start.setDate(start.getDate() - 7);
                    break;
                default:
                    start.setHours(start.getHours() - 24);
            }

            const params = new URLSearchParams({
                start: start.toISOString(),
                end: end.toISOString(),
            });

            if (selectedMetricType !== 'all') {
                params.set('type', selectedMetricType);
            }

            const response = await fetch(`/api/devices/${encodeURIComponent(deviceId)}/metrics?${params}`, {
                headers: {
                    ...(token && { Authorization: `Bearer ${token}` }),
                },
                cache: 'no-store',
            });

            if (!response.ok) {
                throw new Error(`Failed to fetch metrics: ${response.status}`);
            }

            const metricsData = await response.json();
            setMetrics(metricsData || []);
        } catch (e) {
            console.error("Error fetching metrics:", e);
        } finally {
            setMetricsLoading(false);
        }
    }, [deviceId, token, selectedMetricType, timeRange]);

    useEffect(() => {
        fetchDevice();
    }, [fetchDevice]);

    useEffect(() => {
        if (device) {
            fetchMetrics();
        }
    }, [device, fetchMetrics]);

    // Prepare chart data
    const chartData = React.useMemo(() => {
        if (!metrics.length) return [];

        // Group metrics by timestamp and type
        const groupedData = metrics.reduce((acc, metric) => {
            const timestamp = new Date(metric.timestamp).getTime();
            const key = timestamp.toString();
            
            if (!acc[key]) {
                acc[key] = {
                    timestamp: timestamp,
                    time: new Date(timestamp).toLocaleTimeString(),
                };
            }
            
            // Parse numeric values
            const value = parseFloat(metric.value);
            if (!isNaN(value)) {
                acc[key][`${metric.type}_${metric.name}`] = value;
            }
            
            return acc;
        }, {} as Record<string, any>);

        return Object.values(groupedData).sort((a, b) => a.timestamp - b.timestamp);
    }, [metrics]);

    // Get unique metric types
    const metricTypes = React.useMemo(() => {
        const types = [...new Set(metrics.map(m => m.type))];
        return types.sort();
    }, [metrics]);

    // Get metric statistics
    const metricStats = React.useMemo(() => {
        const stats = {
            total: metrics.length,
            types: metricTypes.length,
            latestTimestamp: metrics.length > 0 ? 
                new Date(Math.max(...metrics.map(m => new Date(m.timestamp).getTime()))) : null,
            oldestTimestamp: metrics.length > 0 ? 
                new Date(Math.min(...metrics.map(m => new Date(m.timestamp).getTime()))) : null,
        };
        return stats;
    }, [metrics, metricTypes]);

    if (loading) {
        return (
            <div className="flex items-center justify-center p-8">
                <Loader2 className="h-8 w-8 text-gray-400 animate-spin" />
                <span className="ml-2 text-gray-600 dark:text-gray-400">Loading device details...</span>
            </div>
        );
    }

    if (error) {
        return (
            <div className="text-center p-8">
                <AlertTriangle className="mx-auto h-12 w-12 text-red-400 mb-4" />
                <p className="text-red-400 text-lg">{error}</p>
                <Link 
                    href="/devices" 
                    className="mt-4 inline-flex items-center text-blue-600 hover:text-blue-800"
                >
                    <ArrowLeft className="h-4 w-4 mr-2" />
                    Back to Devices
                </Link>
            </div>
        );
    }

    if (!device) {
        return (
            <div className="text-center p-8">
                <Server className="mx-auto h-12 w-12 text-gray-400 mb-4" />
                <p className="text-gray-400 text-lg">Device not found</p>
                <Link 
                    href="/devices" 
                    className="mt-4 inline-flex items-center text-blue-600 hover:text-blue-800"
                >
                    <ArrowLeft className="h-4 w-4 mr-2" />
                    Back to Devices
                </Link>
            </div>
        );
    }

    return (
        <div className="space-y-6">
            {/* Back Navigation */}
            <Link 
                href="/devices" 
                className="inline-flex items-center text-blue-600 hover:text-blue-800 dark:text-blue-400 dark:hover:text-blue-300"
            >
                <ArrowLeft className="h-4 w-4 mr-2" />
                Back to Devices
            </Link>

            {/* Device Overview */}
            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-6">
                <div className="flex items-start justify-between">
                    <div className="flex items-center">
                        <div className="p-3 bg-blue-100 dark:bg-gray-700/50 rounded-lg mr-4">
                            <Server className="h-8 w-8 text-blue-600 dark:text-blue-400" />
                        </div>
                        <div>
                            <h2 className="text-2xl font-bold text-gray-900 dark:text-white">
                                {device.hostname || device.ip}
                            </h2>
                            <p className="text-gray-600 dark:text-gray-400">{device.device_id}</p>
                            <div className="flex items-center mt-2 space-x-4">
                                <div className="flex items-center">
                                    <MapPin className="h-4 w-4 mr-1 text-gray-500" />
                                    <span className="text-sm text-gray-500">{device.poller_id}</span>
                                </div>
                                <div className="flex items-center">
                                    <Clock className="h-4 w-4 mr-1 text-gray-500" />
                                    <span className="text-sm text-gray-500">
                                        Last seen: {new Date(device.last_seen).toLocaleString()}
                                    </span>
                                </div>
                            </div>
                        </div>
                    </div>
                    <div className="flex items-center">
                        {device.is_available ? (
                            <div className="flex items-center text-green-600">
                                <CheckCircle className="h-6 w-6 mr-2" />
                                <span className="font-medium">Online</span>
                            </div>
                        ) : (
                            <div className="flex items-center text-red-600">
                                <XCircle className="h-6 w-6 mr-2" />
                                <span className="font-medium">Offline</span>
                            </div>
                        )}
                    </div>
                </div>

                {/* Discovery Sources */}
                <div className="mt-4">
                    <p className="text-sm text-gray-600 dark:text-gray-400 mb-2">Discovery Sources:</p>
                    <div className="flex flex-wrap gap-2">
                        {device.discovery_sources.map(source => (
                            <span 
                                key={source}
                                className="px-2 py-1 text-xs font-medium rounded-full bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-300"
                            >
                                {source}
                            </span>
                        ))}
                    </div>
                </div>
            </div>

            {/* Metrics Overview */}
            <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
                <MetricCard
                    title="Total Metrics"
                    value={metricStats.total.toLocaleString()}
                    icon={<TrendingUp className="h-6 w-6" />}
                    color="blue"
                />
                <MetricCard
                    title="Metric Types"
                    value={metricStats.types}
                    icon={<BarChart3 className="h-6 w-6" />}
                    color="green"
                />
                <MetricCard
                    title="Latest Data"
                    value={metricStats.latestTimestamp ? 
                        metricStats.latestTimestamp.toLocaleTimeString() : 'N/A'
                    }
                    icon={<Clock className="h-6 w-6" />}
                    color="purple"
                    subtitle={metricStats.latestTimestamp ? 
                        metricStats.latestTimestamp.toLocaleDateString() : undefined
                    }
                />
                <MetricCard
                    title="Active Collectors"
                    value={[...new Set(metrics.map(m => m.poller_id))].length}
                    icon={<Activity className="h-6 w-6" />}
                    color="orange"
                />
            </div>

            {/* Metrics Controls */}
            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4">
                <div className="flex flex-col md:flex-row gap-4 justify-between items-center">
                    <div className="flex items-center gap-4">
                        <label className="text-sm font-medium text-gray-700 dark:text-gray-300">
                            Metric Type:
                        </label>
                        <select
                            value={selectedMetricType}
                            onChange={(e) => setSelectedMetricType(e.target.value)}
                            className="border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white px-3 py-2 focus:ring-blue-500 focus:border-blue-500"
                        >
                            <option value="all">All Types</option>
                            {metricTypes.map(type => (
                                <option key={type} value={type}>{type.toUpperCase()}</option>
                            ))}
                        </select>
                    </div>

                    <div className="flex items-center gap-4">
                        <label className="text-sm font-medium text-gray-700 dark:text-gray-300">
                            Time Range:
                        </label>
                        <select
                            value={timeRange}
                            onChange={(e) => setTimeRange(e.target.value)}
                            className="border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white px-3 py-2 focus:ring-blue-500 focus:border-blue-500"
                        >
                            <option value="1h">Last Hour</option>
                            <option value="6h">Last 6 Hours</option>
                            <option value="24h">Last 24 Hours</option>
                            <option value="7d">Last 7 Days</option>
                        </select>
                    </div>
                </div>
            </div>

            {/* Metrics Chart */}
            {metricsLoading ? (
                <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-8">
                    <div className="flex items-center justify-center">
                        <Loader2 className="h-8 w-8 text-gray-400 animate-spin" />
                        <span className="ml-2 text-gray-600 dark:text-gray-400">Loading metrics...</span>
                    </div>
                </div>
            ) : chartData.length > 0 ? (
                <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-6">
                    <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">
                        Device Metrics Timeline
                    </h3>
                    <div className="h-96">
                        <ResponsiveContainer width="100%" height="100%">
                            <LineChart data={chartData}>
                                <CartesianGrid strokeDasharray="3 3" className="opacity-30" />
                                <XAxis 
                                    dataKey="time" 
                                    className="text-xs"
                                />
                                <YAxis className="text-xs" />
                                <Tooltip 
                                    contentStyle={{
                                        backgroundColor: 'rgba(17, 24, 39, 0.95)',
                                        border: 'none',
                                        borderRadius: '8px',
                                        color: 'white'
                                    }}
                                />
                                <Legend />
                                {/* Dynamic lines based on available metrics */}
                                {Object.keys(chartData[0] || {})
                                    .filter(key => key !== 'timestamp' && key !== 'time')
                                    .slice(0, 5) // Limit to 5 lines for readability
                                    .map((key, index) => (
                                        <Line
                                            key={key}
                                            type="monotone"
                                            dataKey={key}
                                            stroke={`hsl(${(index * 60) % 360}, 70%, 50%)`}
                                            strokeWidth={2}
                                            dot={false}
                                        />
                                    ))
                                }
                            </LineChart>
                        </ResponsiveContainer>
                    </div>
                </div>
            ) : (
                <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-8">
                    <div className="text-center">
                        <BarChart3 className="mx-auto h-12 w-12 text-gray-400 mb-4" />
                        <p className="text-gray-400">No metrics available for the selected time range</p>
                    </div>
                </div>
            )}
        </div>
    );
};

export default DeviceDetail;