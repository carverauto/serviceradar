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

import { useEffect, useMemo, useState } from 'react';
import { useAuth } from '@/components/AuthProvider';
import { analyticsService, AnalyticsData } from '@/services/analyticsService';
import { ServiceEntry } from '@/types/types';
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

const EMPTY_STATS: AnalyticsStats = {
    totalDevices: 0,
    offlineDevices: 0,
    highLatencyServices: 0,
    failingServices: 0,
};

const REFRESH_INTERVAL = 60000; // 60 seconds
export const useAnalyticsData = () => {
    const { token } = useAuth();
    const [analyticsData, setAnalyticsData] = useState<AnalyticsData | null>(null);
    const [isLoading, setIsLoading] = useState<boolean>(true);
    const [error, setError] = useState<Error | null>(null);

    useEffect(() => {
        let cancelled = false;

        const updateFromService = async (forceRefresh = false) => {
            try {
                const data = forceRefresh
                    ? await analyticsService.refresh(token || undefined)
                    : await analyticsService.getAnalyticsData(token || undefined);
                if (!cancelled) {
                    setAnalyticsData(data);
                    setError(null);
                }
            } catch (err) {
                if (!cancelled) {
                    setError(err instanceof Error ? err : new Error(String(err)));
                }
            } finally {
                if (!cancelled) {
                    setIsLoading(false);
                }
            }
        };

        // Initial load
        setIsLoading(true);
        updateFromService();

        // Subscribe to cache updates so other consumers keep us fresh
        const unsubscribe = analyticsService.subscribe(() => {
            updateFromService();
        });

        // Periodic refresh to keep data current
        const intervalId = window.setInterval(() => {
            updateFromService(true);
        }, REFRESH_INTERVAL);

        return () => {
            cancelled = true;
            unsubscribe();
            window.clearInterval(intervalId);
        };
    }, [token]);

    const { stats, chartData } = useMemo(() => {
        if (!analyticsData) {
            return {
                stats: { ...EMPTY_STATS },
                chartData: {
                    deviceAvailability: [],
                    topLatencyServices: [],
                    servicesByType: [],
                    discoveryBySource: [],
                },
            };
        }

        const failingServices = analyticsData.failingServiceCount ?? 0;
        const highLatencyServices = analyticsData.highLatencyServiceCount ?? 0;
        const latencyBuckets = (analyticsData.serviceLatencyBuckets ?? [])
            .filter((bucket): bucket is { name: string; responseTimeMs: number } =>
                Boolean(bucket && typeof bucket.name === 'string' && Number.isFinite(bucket.responseTimeMs)))
            .map((bucket) => ({
                name: bucket.name,
                value: bucket.responseTimeMs,
            }))
            .sort((a, b) => b.value - a.value);

        const computedStats: AnalyticsStats = {
            totalDevices: analyticsData.totalDevices,
            offlineDevices: analyticsData.offlineDevices,
            highLatencyServices,
            failingServices,
        };

        const services = (analyticsData.servicesLatest as ServiceEntry[]) || [];
        const devices = (analyticsData.devicesLatest as Device[]) || [];

        const deviceAvailability = [
            { name: 'Online', value: analyticsData.totalDevices - analyticsData.offlineDevices, color: '#3b82f6' },
            { name: 'Offline', value: analyticsData.offlineDevices, color: '#ef4444' },
        ];

        const topLatencyServices = latencyBuckets
            .slice(0, 5)
            .map((item, index) => ({
                ...item,
                color: ['#f59e0b', '#facc15', '#fef08a', '#fde68a', '#fcd34d'][index % 5],
            }));

        const servicesByType = Object.entries(
            services.reduce((acc, service) => {
                const type = service.service_type || 'unknown';
                acc[type] = (acc[type] || 0) + 1;
                return acc;
            }, {} as Record<string, number>)
        ).map(([name, value], index) => ({
            name,
            value,
            color: ['#3b82f6', '#50fa7b', '#60a5fa', '#50fa7b', '#50fa7b'][index % 5],
        }));

        const discoveryBySource = Object.entries(
            devices.reduce((acc, device) => {
                (device.discovery_sources || []).forEach((source) => {
                    acc[source] = (acc[source] || 0) + 1;
                });
                return acc;
            }, {} as Record<string, number>)
        ).map(([name, value], index) => ({
            name,
            value,
            color: ['#3b82f6', '#50fa7b', '#60a5fa', '#50fa7b', '#50fa7b'][index % 5],
        }));

        const computedChartData: ChartData = {
            deviceAvailability,
            topLatencyServices,
            servicesByType,
            discoveryBySource,
        };

        return { stats: computedStats, chartData: computedChartData };
    }, [analyticsData]);

    return {
        stats,
        chartData,
        isLoading,
        error,
    };
};
