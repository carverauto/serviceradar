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
import {Poller, GenericServiceDetails} from "@/types/types";
import { Device } from "@/types/devices";
import { RperfMetric } from "@/types/rperf";
import HighUtilizationWidget from './HighUtilizationWidget';
import CriticalEventsWidget from './CriticalEventsWidget';

const REFRESH_INTERVAL = 60000; // 60 seconds

// Reusable component for the top statistic cards
const StatCard = ({ icon: Icon, title, value, subValue, alert = false, isLoading = false }: { icon: React.ElementType; title: string; value: string | number; subValue?: string; alert?: boolean; isLoading?: boolean }) => (
    <div className={`bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 p-4 rounded-lg flex items-center gap-4`}>
        <div className={`p-3 rounded-md ${
            alert ? 'bg-red-100 dark:bg-red-900/50 text-red-600 dark:text-red-400'
                : title.includes('Latency') ? 'bg-yellow-100 dark:bg-yellow-900/50 text-yellow-600 dark:text-yellow-400'
                    : 'bg-blue-100 dark:bg-blue-900/50 text-blue-600 dark:text-blue-400'
        }`}>
            <Icon className='h-6 w-6' />
        </div>
        <div className="flex-1">
            {isLoading ? (
                <>
                    <div className="h-7 w-20 bg-gray-200 dark:bg-gray-700 rounded-md animate-pulse"></div>
                    <div className="h-4 w-24 bg-gray-200 dark:bg-gray-700 rounded-md animate-pulse mt-2"></div>
                </>
            ) : (
                <>
                    <p className="text-2xl font-bold text-gray-900 dark:text-white">{value}</p>
                    <p className="text-sm text-gray-600 dark:text-gray-400">{title} {subValue && <span className="text-gray-600 dark:text-gray-500">| {subValue}</span>}</p>
                </>
            )}
        </div>
    </div>
);

// Reusable component for the chart widgets
const ChartWidget = ({ title, children, moreOptions = true }: { title: string; children: React.ReactNode; moreOptions?: boolean }) => (
    <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 flex flex-col h-[320px]">
        <div className="flex justify-between items-start mb-4">
            <h3 className="font-semibold text-gray-900 dark:text-white">{title}</h3>
            <div className="flex items-center gap-x-2">
                {moreOptions && <button className="text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"><MoreHorizontal size={20} /></button>}
            </div>
        </div>
        <div className="flex-1">{children}</div>
    </div>
);

// "No Data to Show" component for charts
const NoData = () => (
    <div className="flex flex-col items-center justify-center h-full text-center text-gray-600 dark:text-gray-500">
        <div className="w-16 h-12 relative mb-2">
            <div className="absolute top-0 left-0 w-8 h-12 bg-gray-600 transform -skew-x-12"></div>
            <div className="absolute top-0 left-8 w-8 h-12 bg-green-600 transform -skew-x-12"></div>
        </div>
        <p>No data to show</p>
    </div>
);

// Bar Chart component for reuse
const SimpleBarChart = ({ data }: { data: { name: string; value: number; color: string }[] }) => (
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
    const [chartData, setChartData] = useState<{
        deviceAvailability: { name: string; value: number; color: string }[];
        topLatencyServices: { name: string; value: number; color: string }[];
        discoveryBySource: { name: string; value: number; color: string }[];
        rperfBandwidth: { name: string; value: number; color: string }[];
    }>({
        deviceAvailability: [],
        topLatencyServices: [],
        discoveryBySource: [],
        rperfBandwidth: [],
    });
    const [isLoading, setIsLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);

    // Simple in-memory cache for 30 seconds
    const cacheRef = React.useRef<Map<string, { data: unknown; timestamp: number }>>(new Map());
    
    const postQuery = useCallback(async (query: string) => {
        const cacheKey = query;
        const now = Date.now();
        
        // Check cache first (30 second TTL)
        const cached = cacheRef.current.get(cacheKey);
        if (cached && (now - cached.timestamp) < 30000) {
            console.log(`[Cache Hit] ${query}`);
            return cached.data;
        }
        
        console.log(`[API Call] ${query}`);
        const response = await fetch('/api/query', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                ...(token && { Authorization: `Bearer ${token}` }),
            },
            body: JSON.stringify({ query, limit: 1000 }),
        });
        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.error || 'Failed to execute query');
        }
        const data = await response.json();
        
        // Cache the result
        cacheRef.current.set(cacheKey, { data, timestamp: now });
        
        return data;
    }, [token]);

    const fetchData = useCallback(async () => {
        setIsLoading(true);
        setError(null);

        try {
            // Use Promise.all to fetch data concurrently
            const [
                totalDevicesRes,
                offlineDevicesRes,
                allDevicesRes,
                pollersData,
            ] = await Promise.all([
                postQuery('COUNT DEVICES'),
                postQuery('COUNT DEVICES WHERE is_available = false'),
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

            // Fetch rperf data from all pollers that have rperf services
            const rperfPollers = pollersData.filter(poller => 
                poller.services?.some(s => s.type === 'grpc' && s.name === 'rperf-checker')
            );
            
            // Get data for the last 24 hours
            const endTime = new Date();
            const startTime = new Date(endTime.getTime() - 24 * 60 * 60 * 1000);
            
            const rperfPromises = rperfPollers.map(poller => {
                const url = `/api/pollers/${poller.poller_id}/rperf?start=${startTime.toISOString()}&end=${endTime.toISOString()}`;
                
                return fetch(url, {
                    headers: {
                        'Content-Type': 'application/json',
                        ...(token && { Authorization: `Bearer ${token}` }),
                    },
                })
                .then(res => {
                    if (!res.ok) {
                        console.error(`RPerf API error for poller ${poller.poller_id}: ${res.status}`);
                        return [];
                    }
                    return res.json() as Promise<RperfMetric[]>;
                })
                .catch((err) => {
                    console.error(`Error fetching rperf for poller ${poller.poller_id}:`, err);
                    return [];
                });
            });
            
            const rperfDataArrays = await Promise.all(rperfPromises);
            const allRperfData = rperfDataArrays.flat();

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

            // Calculate average rperf bandwidth (in Mbps)
            /*
            let avgRperfBandwidth = 0;
            if (allRperfData.length > 0) {
                const recentRperfData = allRperfData
                    .filter(metric => metric.success)
                    .sort((a, b) => new Date(b.timestamp).getTime() - new Date(a.timestamp).getTime())
                    .slice(0, 10); // Get last 10 successful measurements

                if (recentRperfData.length > 0) {
                     const totalBandwidth = recentRperfData.reduce((sum, metric) => sum + (metric.bits_per_second / 1000000), 0);
                     avgRperfBandwidth = Math.round(totalBandwidth / recentRperfData.length);
                }
            }
             */

            setStats({ totalDevices, offlineDevices, highLatencyServices, failingServices });

            // Prepare rperf bandwidth data for chart
            const rperfBandwidthData: { name: string; value: number; color: string }[] = [];
            if (allRperfData.length > 0) {
                // Group by target and calculate average bandwidth for each
                const successfulMetrics = allRperfData.filter(metric => metric.success);
                
                // Track which sources (pollers) are measuring each target
                const targetBandwidths = successfulMetrics.reduce((acc, metric) => {
                    if (!acc[metric.target]) {
                        acc[metric.target] = { total: 0, count: 0, sources: new Set<string>() };
                    }
                    acc[metric.target].total += metric.bits_per_second / 1000000; // Convert to Mbps
                    acc[metric.target].count += 1;
                    
                    // Track the source poller if available
                    if (metric.agent_id) {
                        acc[metric.target].sources.add(metric.agent_id);
                    }
                    
                    return acc;
                }, {} as Record<string, { total: number; count: number; sources: Set<string> }>);

                // Convert to chart data format and sort by bandwidth
                Object.entries(targetBandwidths)
                    .map(([target, data]) => {
                        let displayName = target;
                        if (data.sources.size > 1) {
                            // Multiple sources measuring this target
                            displayName = `${target} (${data.sources.size} sources)`;
                        } else if (data.sources.size === 1 && rperfPollers.length > 1) {
                            // Single source but multiple pollers exist - show which one
                            const sourceName = Array.from(data.sources)[0];
                            displayName = `${target} (${sourceName})`;
                        }
                        return {
                            name: displayName,
                            value: Math.round(data.total / data.count),
                        };
                    })
                    .sort((a, b) => b.value - a.value)
                    .slice(0, 5) // Top 5 targets
                    .forEach((item, i) => {
                        rperfBandwidthData.push({
                            ...item,
                            color: ['#3b82f6', '#60a5fa', '#93c5fd', '#dbeafe', '#eff6ff'][i % 5]
                        });
                    });
            }

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
                discoveryBySource: Object.entries((allDevicesRes.results as Device[]).reduce((acc, d) => {
                    (d.discovery_sources || []).forEach(source => {
                        acc[source] = (acc[source] || 0) + 1;
                    });
                    return acc;
                }, {} as Record<string, number>)).map(([name, value], i) => ({ name, value, color: ['#3b82f6', '#50fa7b', '#60a5fa', '#50fa7b', '#50fa7b'][i % 5] })),
                rperfBandwidth: rperfBandwidthData,
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
                    icon={Server}
                    title="Total Devices"
                    value={stats.totalDevices.toLocaleString()}
                    isLoading={isLoading}
                />
                <StatCard
                    icon={ServerOff}
                    title="Offline Devices"
                    value={stats.offlineDevices.toLocaleString()}
                    alert
                    isLoading={isLoading}
                />
                <StatCard
                    icon={Activity}
                    title="High Latency Services"
                    value={stats.highLatencyServices.toLocaleString()}
                    alert={stats.highLatencyServices > 0}
                    isLoading={isLoading}
                />
                <StatCard
                    icon={AlertTriangle}
                    title="Failing Services"
                    value={stats.failingServices.toLocaleString()}
                    alert
                    isLoading={isLoading}
                />
            </div>

            {/* Network & Performance Analytics Section */}
            <div>
                <h2 className="text-xl font-bold text-gray-900 dark:text-white mb-4">Network & Performance Analytics</h2>
                <div className="grid grid-cols-1 lg:grid-cols-2 xl:grid-cols-3 gap-6">
                    <ChartWidget title="Device Availability">
                        {chartData.deviceAvailability.length > 0 ? <SimpleBarChart data={chartData.deviceAvailability} /> : <NoData />}
                    </ChartWidget>
                    <ChartWidget title="Top 5 High Latency Services (ms)">
                        {chartData.topLatencyServices.length > 0 ? <SimpleBarChart data={chartData.topLatencyServices} /> : <NoData />}
                    </ChartWidget>
                    <HighUtilizationWidget />
                    <CriticalEventsWidget />
                    <ChartWidget title="Device Discovery Sources">
                        {chartData.discoveryBySource.length > 0 ? <SimpleBarChart data={chartData.discoveryBySource} /> : <NoData />}
                    </ChartWidget>
                    <ChartWidget title="RPerf Bandwidth by Target (Mbps)">
                        {chartData.rperfBandwidth.length > 0 ? <SimpleBarChart data={chartData.rperfBandwidth} /> : <NoData />}
                    </ChartWidget>
                </div>
            </div>
        </div>
    );
};

export default Dashboard;