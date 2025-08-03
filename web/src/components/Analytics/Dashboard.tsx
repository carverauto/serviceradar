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
    AlertTriangle, Activity, ServerOff, Server
} from 'lucide-react';
import { useAuth } from '../AuthProvider';
import {Poller, GenericServiceDetails} from "@/types/types";
import { useRouter } from 'next/navigation';
import HighUtilizationWidget from './HighUtilizationWidget';
import CriticalEventsWidget from './CriticalEventsWidget';
import CriticalLogsWidget from './CriticalLogsWidget';
import ObservabilityWidget from './ObservabilityWidget';
import DeviceAvailabilityWidget from './DeviceAvailabilityWidget';
import RperfBandwidthWidget from './RperfBandwidthWidget';
import { formatNumber } from '@/utils/formatters';

const REFRESH_INTERVAL = 60000; // 60 seconds

// Reusable component for the top statistic cards
const StatCard = ({ 
    icon: Icon, 
    title, 
    value, 
    subValue, 
    alert = false, 
    isLoading = false, 
    onClick,
    tooltip
}: { 
    icon: React.ElementType; 
    title: string; 
    value: string | number; 
    subValue?: string; 
    alert?: boolean; 
    isLoading?: boolean;
    onClick?: () => void;
    tooltip?: string;
}) => (
    <div 
        className={`bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 p-4 rounded-lg flex items-center gap-4 ${
            onClick ? 'cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors' : ''
        }`}
        onClick={onClick}
        title={tooltip}
    >
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



const Dashboard = () => {
    const { token } = useAuth();
    const router = useRouter();
    const [stats, setStats] = useState({
        totalDevices: 0,
        offlineDevices: 0,
        highLatencyServices: 0,
        failingServices: 0,
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
                pollersData,
            ] = await Promise.all([
                postQuery('COUNT DEVICES'),
                postQuery('COUNT DEVICES WHERE is_available = false'),
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
                            // Handle both direct response_time and nested data.response_time (enhanced payload)
                            let responseTime = details?.response_time;
                            if (!responseTime && details?.data?.response_time) {
                                responseTime = details.data.response_time;
                            }
                            
                            if (responseTime) {
                                const responseTimeMs = responseTime / 1000000;
                                latencyData.push({ name: service.name, value: responseTimeMs });
                                if (responseTime > latencyThreshold) {
                                    highLatencyServices++;
                                }
                            }
                        } catch { /* ignore parse errors */ }
                    }
                });
            });

            setStats({ totalDevices, offlineDevices, highLatencyServices, failingServices });

        } catch (e) {
            setError(e instanceof Error ? e.message : "An unknown error occurred.");
        } finally {
            setIsLoading(false);
        }
    }, [postQuery, token]);

    const handleStatCardClick = useCallback((type: 'total' | 'offline' | 'latency' | 'failing') => {
        let query = '';
        switch (type) {
            case 'total':
                query = 'show devices';
                break;
            case 'offline':
                query = 'show devices where is_available = false';
                break;
            case 'latency':
                query = 'show services where type = "icmp" and response_time > 100000000';
                break;
            case 'failing':
                query = 'show services where available = false';
                break;
        }
        const encodedQuery = encodeURIComponent(query);
        router.push(`/query?q=${encodedQuery}`);
    }, [router]);

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
                    value={formatNumber(stats.totalDevices)}
                    isLoading={isLoading}
                    onClick={() => handleStatCardClick('total')}
                    tooltip="Click to view all devices"
                />
                <StatCard
                    icon={ServerOff}
                    title="Offline Devices"
                    value={formatNumber(stats.offlineDevices)}
                    alert
                    isLoading={isLoading}
                    onClick={() => handleStatCardClick('offline')}
                    tooltip="Click to view offline devices"
                />
                <StatCard
                    icon={Activity}
                    title="High Latency Services"
                    value={formatNumber(stats.highLatencyServices)}
                    subValue="> 100ms"
                    alert={stats.highLatencyServices > 0}
                    isLoading={isLoading}
                    onClick={() => handleStatCardClick('latency')}
                    tooltip="Click to view high latency ICMP services (> 100ms)"
                />
                <StatCard
                    icon={AlertTriangle}
                    title="Failing Services"
                    value={formatNumber(stats.failingServices)}
                    alert
                    isLoading={isLoading}
                    onClick={() => handleStatCardClick('failing')}
                    tooltip="Click to view unavailable services"
                />
            </div>

            {/* Network & Performance Analytics Section */}
            <div>
                <h2 className="text-xl font-bold text-gray-900 dark:text-white mb-4">Network & Performance Analytics</h2>
                <div className="grid grid-cols-1 lg:grid-cols-2 xl:grid-cols-3 gap-6">
                    <DeviceAvailabilityWidget />
                    <HighUtilizationWidget />
                    <RperfBandwidthWidget />
                    <CriticalLogsWidget />
                    <ObservabilityWidget />
                    <CriticalEventsWidget />
                </div>
            </div>
        </div>
    );
};

export default Dashboard;