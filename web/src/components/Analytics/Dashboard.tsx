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
import {
    BarChart, Bar, XAxis, YAxis, ResponsiveContainer, Cell, Tooltip, Legend
} from 'recharts';
import {
    AlertTriangle, Activity, ServerOff, MoreHorizontal, Server
} from 'lucide-react';
import { useAuth } from '../AuthProvider';
import {ServiceEntry, Poller, GenericServiceDetails} from "@/types/types";
import { Device } from "@/types/devices";

const REFRESH_INTERVAL = 60000; // 60 seconds

// Reusable component for the top statistic cards
const StatCard = ({ icon, title, value, subValue, alert = false, isLoading = false }) => (
    <div className={`bg-[#25252e] border border-gray-700 p-4 rounded-lg flex items-center gap-4`}>
        <div className={`p-3 rounded-md ${
            alert ? 'bg-red-900/50 text-red-400'
                : title.includes('Latency') ? 'bg-yellow-900/50 text-yellow-400'
                    : 'bg-blue-900/50 text-blue-400'
        }`}>
            {React.cloneElement(icon, { className: 'h-6 w-6' })}
        </div>
        <div className="flex-1">
            {isLoading ? (
                <>
                    <div className="h-7 w-20 bg-gray-700 rounded-md animate-pulse"></div>
                    <div className="h-4 w-24 bg-gray-700 rounded-md animate-pulse mt-2"></div>
                </>
            ) : (
                <>
                    <p className="text-2xl font-bold text-white">{value}</p>
                    <p className="text-sm text-gray-400">{title} {subValue && <span className="text-gray-500">| {subValue}</span>}</p>
                </>
            )}
        </div>
    </div>
);

// Reusable component for the chart widgets
const ChartWidget = ({ title, children, moreOptions = true }) => (
    <div className="bg-[#25252e] border border-gray-700/80 rounded-lg p-4 flex flex-col h-[320px]">
        <div className="flex justify-between items-start mb-4">
            <h3 className="font-semibold text-white">{title}</h3>
            <div className="flex items-center gap-x-2">
                {moreOptions && <button className="text-gray-400 hover:text-white"><MoreHorizontal size={20} /></button>}
            </div>
        </div>
        <div className="flex-1">{children}</div>
    </div>
);

// "No Data to Show" component for charts
const NoData = () => (
    <div className="flex flex-col items-center justify-center h-full text-center text-gray-500">
        <div className="w-16 h-12 relative mb-2">
            <div className="absolute top-0 left-0 w-8 h-12 bg-gray-600 transform -skew-x-12"></div>
            <div className="absolute top-0 left-8 w-8 h-12 bg-green-600 transform -skew-x-12"></div>
        </div>
        <p>No data to show</p>
    </div>
);

// Bar Chart component for reuse
const SimpleBarChart = ({ data }) => (
    <ResponsiveContainer width="100%" height="100%">
        <BarChart data={data} margin={{ top: 10, right: 10, left: -10, bottom: 5 }}>
            <XAxis dataKey="name" tick={{ fill: '#9ca3af', fontSize: 12 }} axisLine={false} tickLine={false} interval={0} />
            <YAxis tick={{ fill: '#9ca3af', fontSize: 12 }} axisLine={false} tickLine={false} />
            <Tooltip
                cursor={{ fill: 'rgba(100, 116, 139, 0.1)' }}
                contentStyle={{ backgroundColor: '#16151c', border: '1px solid #4b5563', borderRadius: '0.5rem' }}
                labelStyle={{ color: '#d1d5db' }}
            />
            <Legend wrapperStyle={{fontSize: "12px"}}/>
            <Bar dataKey="value" name="Count" radius={[4, 4, 0, 0]}>
                {data.map((entry, index) => (
                    <Cell key={`cell-${index}`} fill={entry.color} />
                ))}
            </Bar>
        </BarChart>
    </ResponsiveContainer>
);

const Dashboard = () => {
    const { token } = useAuth();
    const [stats, setStats] = useState({
        totalDevices: 0,
        offlineDevices: 0,
        highLatencyServices: 0,
        failingServices: 0,
    });
    const [chartData, setChartData] = useState({
        deviceAvailability: [],
        topLatencyServices: [],
        servicesByType: [],
        discoveryBySource: [],
    });
    const [isLoading, setIsLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);

    const postQuery = useCallback(async (query: string) => {
        const response = await fetch('/api/query', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                ...(token && { Authorization: `Bearer ${token}` }),
            },
            body: JSON.stringify({ query, limit: 1000 }), // Limit to prevent massive data pulls
        });
        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.error || 'Failed to execute query');
        }
        return response.json();
    }, [token]);

    const fetchData = useCallback(async () => {
        setIsLoading(true);
        setError(null);

        try {
            // Use Promise.all to fetch data concurrently
            const [
                totalDevicesRes,
                offlineDevicesRes,
                allServicesRes,
                allDevicesRes,
                pollersData,
            ] = await Promise.all([
                postQuery('COUNT DEVICES'),
                postQuery('COUNT DEVICES WHERE is_available = false'),
                postQuery('SHOW SERVICES'),
                postQuery('SHOW DEVICES'),
                // Fetch pollers to get detailed service status and latency, which is not available in the 'SERVICES' stream
                fetch('/api/pollers', {
                    headers: {
                        'Content-Type': 'application/json',
                        ...(token && { Authorization: `Bearer ${token}` }),
                    },
                }).then(res => {
                    if (!res.ok) throw new Error('Failed to fetch pollers data for analytics');
                    return res.json() as Promise<Poller[]>;
                }),
            ]);

            // Calculate stats
            const totalDevices = totalDevicesRes.results[0]?.['count()'] || 0;
            const offlineDevices = offlineDevicesRes.results[0]?.['count()'] || 0;

            let failingServices = 0;
            let highLatencyServices = 0;
            const latencyThreshold = 100 * 1000000; // 100ms in nanoseconds
            const latencyData: { name: string; value: number }[] = [];

            pollersData.forEach(poller => {
                poller.services?.forEach(service => {
                    if (!service.available) {
                        failingServices++;
                    }
                    if (service.type === 'icmp' && service.available && service.details) {
                        try {
                            const details = (typeof service.details === 'string' ? JSON.parse(service.details) : service.details) as GenericServiceDetails;
                            if (details?.response_time) {
                                const responseTimeMs = details.response_time / 1000000;
                                latencyData.push({ name: service.name, value: responseTimeMs });
                                if (details.response_time > latencyThreshold) {
                                    highLatencyServices++;
                                }
                            }
                        } catch { /* ignore parse errors */ }
                    }
                });
            });

            setStats({ totalDevices, offlineDevices, highLatencyServices, failingServices });

            // Prepare chart data
            const topLatencyServices = latencyData
                .sort((a, b) => b.value - a.value)
                .slice(0, 5)
                .map((item, i) => ({ ...item, color: ['#f59e0b', '#facc15', '#fef08a', '#fde68a', '#fcd34d'][i % 5] }));

            setChartData({
                deviceAvailability: [
                    { name: 'Online', value: totalDevices - offlineDevices, color: '#3b82f6' },
                    { name: 'Offline', value: offlineDevices, color: '#ef4444' }
                ],
                topLatencyServices: topLatencyServices,
                servicesByType: Object.entries((allServicesRes.results as ServiceEntry[]).reduce((acc, s) => {
                    acc[s.service_type] = (acc[s.service_type] || 0) + 1;
                    return acc;
                }, {} as Record<string, number>)).map(([name, value], i) => ({ name, value, color: ['#3b82f6', '#50fa7b', '#60a5fa', '#50fa7b', '#50fa7b'][i % 5] })),
                discoveryBySource: Object.entries((allDevicesRes.results as Device[]).reduce((acc, d) => {
                    (d.discovery_sources || []).forEach(source => {
                        acc[source] = (acc[source] || 0) + 1;
                    });
                    return acc;
                }, {} as Record<string, number>)).map(([name, value], i) => ({ name, value, color: ['#3b82f6', '#50fa7b', '#60a5fa', '#50fa7b', '#50fa7b'][i % 5] })),
            });

        } catch (e) {
            setError(e instanceof Error ? e.message : "An unknown error occurred.");
        } finally {
            setIsLoading(false);
        }
    }, [postQuery, token]);

    useEffect(() => {
        fetchData();
        const interval = setInterval(() => {
            fetchData();
        }, REFRESH_INTERVAL);
        return () => clearInterval(interval);
    }, [fetchData]);

    return (
        <div className="space-y-6">
            {error && (
                <div className="bg-red-900/20 border border-red-500/30 p-4 rounded-lg">
                    <p className="text-red-400">Error: {error}</p>
                </div>
            )}
            {/* Stat Cards */}
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
                <StatCard
                    icon={<Server />}
                    title="Total Devices"
                    value={stats.totalDevices.toLocaleString()}
                    isLoading={isLoading}
                />
                <StatCard
                    icon={<ServerOff />}
                    title="Offline Devices"
                    value={stats.offlineDevices.toLocaleString()}
                    alert
                    isLoading={isLoading}
                />
                <StatCard
                    icon={<Activity />}
                    title="High Latency Services"
                    value={stats.highLatencyServices.toLocaleString()}
                    alert={stats.highLatencyServices > 0}
                    isLoading={isLoading}
                />
                <StatCard
                    icon={<AlertTriangle />}
                    title="Failing Services"
                    value={stats.failingServices.toLocaleString()}
                    alert
                    isLoading={isLoading}
                />
            </div>

            {/* Network & Performance Analytics Section */}
            <div>
                <h2 className="text-xl font-bold text-white mb-4">Network & Performance Analytics</h2>
                <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
                    <ChartWidget title="Device Availability">
                        {chartData.deviceAvailability.length > 0 ? <SimpleBarChart data={chartData.deviceAvailability} /> : <NoData />}
                    </ChartWidget>
                    <ChartWidget title="Top 5 High Latency Services (ms)">
                        {chartData.topLatencyServices.length > 0 ? <SimpleBarChart data={chartData.topLatencyServices} /> : <NoData />}
                    </ChartWidget>
                    <ChartWidget title="Services by Type">
                        {chartData.servicesByType.length > 0 ? <SimpleBarChart data={chartData.servicesByType} /> : <NoData />}
                    </ChartWidget>
                    <ChartWidget title="Device Discovery Sources">
                        {chartData.discoveryBySource.length > 0 ? <SimpleBarChart data={chartData.discoveryBySource} /> : <NoData />}
                    </ChartWidget>
                </div>
            </div>
        </div>
    );
};

export default Dashboard;