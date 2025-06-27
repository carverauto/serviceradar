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

import { useQueries } from '@tanstack/react-query';
import { useAuth } from '@/components/AuthProvider';
import { ServiceEntry, Poller, GenericServiceDetails } from '@/types/types';
import { Device } from '@/types/devices';

interface AnalyticsStats {
    totalDevices: number;
    offlineDevices: number;
    highLatencyServices: number;
    failingServices: number;
}

interface ChartData {
    deviceAvailability: { name: string; value: number; color: string }[];
    topLatencyServices: { name: string; value: number; color: string }[];
    servicesByType: { name: string; value: number; color: string }[];
    discoveryBySource: { name: string; value: number; color: string }[];
}

const REFRESH_INTERVAL = 60000; // 60 seconds

export const useAnalyticsData = () => {
    const { token } = useAuth();

    const postQuery = async (query: string) => {
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
        return response.json();
    };

    const fetchPollers = async (): Promise<Poller[]> => {
        const response = await fetch('/api/pollers', {
            headers: {
                'Content-Type': 'application/json',
                ...(token && { Authorization: `Bearer ${token}` }),
            },
        });
        if (!response.ok) throw new Error('Failed to fetch pollers data for analytics');
        return response.json();
    };

    // Use useQueries to fetch all data in parallel with individual caching
    const queries = useQueries({
        queries: [
            {
                queryKey: ['analytics', 'totalDevices'],
                queryFn: () => postQuery('COUNT DEVICES'),
                staleTime: 30000,
                refetchInterval: REFRESH_INTERVAL,
                enabled: !!token,
            },
            {
                queryKey: ['analytics', 'offlineDevices'],
                queryFn: () => postQuery('COUNT DEVICES WHERE is_available = false'),
                staleTime: 30000,
                refetchInterval: REFRESH_INTERVAL,
                enabled: !!token,
            },
            {
                queryKey: ['analytics', 'services'],
                queryFn: () => postQuery('SHOW SERVICES'),
                staleTime: 30000,
                refetchInterval: REFRESH_INTERVAL,
                enabled: !!token,
            },
            {
                queryKey: ['analytics', 'devices'],
                queryFn: () => postQuery('SHOW DEVICES'),
                staleTime: 30000,
                refetchInterval: REFRESH_INTERVAL,
                enabled: !!token,
            },
            {
                queryKey: ['analytics', 'pollers'],
                queryFn: fetchPollers,
                staleTime: 30000,
                refetchInterval: REFRESH_INTERVAL,
                enabled: !!token,
            },
        ],
    });

    const [
        totalDevicesQuery,
        offlineDevicesQuery,
        servicesQuery,
        devicesQuery,
        pollersQuery,
    ] = queries;

    // Calculate derived data
    const isLoading = queries.some(query => query.isLoading);
    const error = queries.find(query => query.error)?.error;

    let stats: AnalyticsStats = {
        totalDevices: 0,
        offlineDevices: 0,
        highLatencyServices: 0,
        failingServices: 0,
    };

    let chartData: ChartData = {
        deviceAvailability: [],
        topLatencyServices: [],
        servicesByType: [],
        discoveryBySource: [],
    };

    if (!isLoading && !error && queries.every(query => query.data)) {
        // Calculate stats
        const totalDevices = totalDevicesQuery.data?.results[0]?.['count()'] || 0;
        const offlineDevices = offlineDevicesQuery.data?.results[0]?.['count()'] || 0;

        let failingServices = 0;
        let highLatencyServices = 0;
        const latencyThreshold = 100 * 1000000; // 100ms in nanoseconds
        const latencyData: { name: string; value: number }[] = [];

        pollersQuery.data?.forEach((poller: Poller) => {
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

        stats = { totalDevices, offlineDevices, highLatencyServices, failingServices };

        // Prepare chart data
        const topLatencyServices = latencyData
            .sort((a, b) => b.value - a.value)
            .slice(0, 5)
            .map((item, i) => ({ ...item, color: ['#f59e0b', '#facc15', '#fef08a', '#fde68a', '#fcd34d'][i % 5] }));

        chartData = {
            deviceAvailability: [
                { name: 'Online', value: totalDevices - offlineDevices, color: '#3b82f6' },
                { name: 'Offline', value: offlineDevices, color: '#ef4444' }
            ],
            topLatencyServices: topLatencyServices,
            servicesByType: Object.entries((servicesQuery.data?.results as ServiceEntry[] || []).reduce((acc, s) => {
                acc[s.service_type] = (acc[s.service_type] || 0) + 1;
                return acc;
            }, {} as Record<string, number>)).map(([name, value], i) => ({ name, value, color: ['#3b82f6', '#50fa7b', '#60a5fa', '#50fa7b', '#50fa7b'][i % 5] })),
            discoveryBySource: Object.entries((devicesQuery.data?.results as Device[] || []).reduce((acc, d) => {
                (d.discovery_sources || []).forEach(source => {
                    acc[source] = (acc[source] || 0) + 1;
                });
                return acc;
            }, {} as Record<string, number>)).map(([name, value], i) => ({ name, value, color: ['#3b82f6', '#50fa7b', '#60a5fa', '#50fa7b', '#50fa7b'][i % 5] })),
        };
    }

    return {
        stats,
        chartData,
        isLoading,
        error: error as Error | null,
    };
};