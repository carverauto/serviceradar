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

import React, { useMemo, useCallback } from 'react';
import {
    AlertTriangle, Activity, ServerOff, Server
} from 'lucide-react';
import {GenericServiceDetails} from "@/types/types";
import { useRouter } from 'next/navigation';
import { AnalyticsProvider, useAnalytics } from '@/contexts/AnalyticsContext';
import { SysmonProvider } from '@/contexts/SysmonContext';
import { RperfProvider } from '@/contexts/RperfContext';
import HighUtilizationWidget from './HighUtilizationWidget';
import CriticalEventsWidget from './CriticalEventsWidget';
import CriticalLogsWidget from './CriticalLogsWidget';
import ObservabilityWidget from './ObservabilityWidget';
import DeviceAvailabilityWidget from './DeviceAvailabilityWidget';
import RperfBandwidthWidget from './RperfBandwidthWidget';
import { formatNumber } from '@/utils/formatters';

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



const DashboardContent = () => {
    const router = useRouter();
    const { data: analyticsData, loading: isLoading, error } = useAnalytics();

    // Calculate derived stats from shared analytics data
    const stats = useMemo(() => {
        if (!analyticsData) {
            return { totalDevices: 0, offlineDevices: 0, highLatencyServices: 0, failingServices: 0 };
        }

        let failingServices = 0;
        let highLatencyServices = 0;
        const latencyThreshold = 100 * 1000000; // 100ms in nanoseconds

        (analyticsData.pollers as Array<{ services?: Array<{ available: boolean; type: string; details?: unknown; }> }>).forEach((poller) => {
            poller.services?.forEach((service) => {
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
                        
                        if (responseTime && responseTime > latencyThreshold) {
                            highLatencyServices++;
                        }
                    } catch { /* ignore parse errors */ }
                }
            });
        });

        return {
            totalDevices: analyticsData.totalDevices,
            offlineDevices: analyticsData.offlineDevices,
            highLatencyServices,
            failingServices
        };
    }, [analyticsData]);

    const handleStatCardClick = useCallback((type: 'total' | 'offline' | 'latency' | 'failing') => {
        let query = '';
        switch (type) {
            case 'total':
                query = 'in:devices time:last_7d sort:last_seen:desc limit:100';
                break;
            case 'offline':
                query = 'in:devices is_available:false time:last_7d sort:last_seen:desc limit:100';
                break;
            case 'latency':
                query = 'in:services type:icmp response_time:[100000000,] sort:timestamp:desc limit:100';
                break;
            case 'failing':
                query = 'in:services available:false sort:timestamp:desc limit:100';
                break;
        }
        const encodedQuery = encodeURIComponent(query);
        router.push(`/query?q=${encodedQuery}`);
    }, [router]);

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

const Dashboard = () => {
    return (
        <AnalyticsProvider>
            <SysmonProvider>
                <RperfProvider>
                    <DashboardContent />
                </RperfProvider>
            </SysmonProvider>
        </AnalyticsProvider>
    );
};

export default Dashboard;
