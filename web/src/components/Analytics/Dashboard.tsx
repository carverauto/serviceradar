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
import { useSrqlQuery } from '@/contexts/SrqlQueryContext';

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
    const { setQuery: setSrqlQuery } = useSrqlQuery();
    const { data: analyticsData, loading: isLoading, error } = useAnalytics();
    const diagnostics = analyticsData?.deviceStatsDiagnostics;

    // Calculate derived stats from shared analytics data
    const stats = useMemo(() => {
        if (!analyticsData) {
            return { totalDevices: 0, offlineDevices: 0, highLatencyServices: 0, failingServices: 0 };
        }

        const failingServices = analyticsData.failingServiceCount ?? 0;
        const highLatencyServices = analyticsData.highLatencyServiceCount ?? 0;

        return {
            totalDevices: analyticsData.totalDevices,
            offlineDevices: analyticsData.offlineDevices,
            highLatencyServices,
            failingServices
        };
    }, [analyticsData]);

    const totalDevicesAlert = Boolean(diagnostics?.warnings?.length);

    const totalDevicesSubValue = useMemo(() => {
        const summary = diagnostics?.summary;
        if (!summary) {
            return undefined;
        }

        const { rawRecords, processedRecords } = summary;
        if (rawRecords === undefined || processedRecords === undefined) {
            return undefined;
        }

        return `raw ${formatNumber(rawRecords)} / processed ${formatNumber(processedRecords)}`;
    }, [diagnostics]);

    const deviceStatsTooltip = useMemo(() => {
        const summary = diagnostics?.summary;
        if (!summary) {
            return undefined;
        }

        const parts: string[] = [];
        if (summary.timestamp) {
            parts.push(`snapshot ${summary.timestamp}`);
        }
        if (typeof summary.ageMs === 'number') {
            parts.push(`age ${Math.max(Math.floor(summary.ageMs / 1000), 0)}s`);
        }
        if (typeof summary.rawRecords === 'number' && typeof summary.processedRecords === 'number') {
            parts.push(`raw ${formatNumber(summary.rawRecords)} → processed ${formatNumber(summary.processedRecords)}`);
        }
        if (typeof summary.skippedNonCanonicalRecords === 'number') {
            parts.push(`skipped non-canonical ${formatNumber(summary.skippedNonCanonicalRecords)}`);
        }
        if (typeof summary.skippedServiceComponents === 'number') {
            parts.push(`skipped components ${formatNumber(summary.skippedServiceComponents)}`);
        }
        if (typeof summary.skippedTombstonedRecords === 'number') {
            parts.push(`skipped tombstoned ${formatNumber(summary.skippedTombstonedRecords)}`);
        }

        return parts.join(' • ');
    }, [diagnostics]);

    const handleStatCardClick = useCallback((type: 'total' | 'offline' | 'latency' | 'failing') => {
        let query = '';
        let targetRoute: string | null = null;
        let viewId: string | null = null;

        switch (type) {
            case 'total':
                query = 'in:devices time:last_7d sort:last_seen:desc limit:100';
                targetRoute = '/devices';
                viewId = 'devices:inventory';
                break;
            case 'offline':
                query = 'in:devices is_available:false time:last_7d sort:last_seen:desc limit:100';
                targetRoute = '/devices';
                viewId = 'devices:inventory';
                break;
            case 'latency':
                query = 'in:services type:icmp response_time:[100000000,] sort:timestamp:desc limit:100';
                break;
            case 'failing':
                query = 'in:services available:false sort:timestamp:desc limit:100';
                break;
        }
        if (targetRoute && viewId) {
            setSrqlQuery(query, { origin: 'view', viewPath: targetRoute, viewId });
            router.push(targetRoute);
            return;
        }

        const encodedQuery = encodeURIComponent(query);
        router.push(`/query?q=${encodedQuery}`);
    }, [router, setSrqlQuery]);

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
                    subValue={totalDevicesSubValue}
                    alert={totalDevicesAlert}
                    isLoading={isLoading}
                    onClick={() => handleStatCardClick('total')}
                    tooltip={deviceStatsTooltip ?? 'Click to view all devices'}
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

            {totalDevicesAlert && diagnostics?.details.length ? (
                <div className="rounded-md border border-yellow-400 bg-yellow-50 p-4 dark:border-yellow-600 dark:bg-yellow-900/30">
                    <div className="flex items-start gap-3">
                        <AlertTriangle className="mt-0.5 h-5 w-5 text-yellow-700 dark:text-yellow-300" />
                        <div>
                            <p className="text-sm font-semibold text-yellow-800 dark:text-yellow-200">
                                Device stats diagnostics
                            </p>
                            <ul className="mt-2 space-y-1 text-sm text-yellow-800 dark:text-yellow-200">
                                {diagnostics.details.map((message, index) => (
                                    <li key={index}>• {message}</li>
                                ))}
                            </ul>
                        </div>
                    </div>
                </div>
            ) : null}

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
