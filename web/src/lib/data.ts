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

// src/lib/data.ts
import { cache } from 'react';
import { Poller, ServiceMetric, SystemStatus, ServicePayload } from '@/types/types';
import { HistoryEntry } from '@/app/api/pollers/[id]/history/route';
import { SnmpDataPoint } from '@/types/snmp';
import { fetchFromAPI } from './api';

// Set a revalidation period for cached data. 15 seconds is a good starting point for a dashboard.
const REVALIDATE_SECONDS = 15;

/**
 * Fetches all pollers and caches the result.
 * React's `cache` function memoizes the request, so multiple calls to this
 * function within the same render pass will result in only one database query.
 */
export const getCachedPollers = cache(
  async (token?: string): Promise<Poller[]> => {
    return (await fetchFromAPI<Poller[]>('/pollers', token, {
      next: { revalidate: REVALIDATE_SECONDS },
    })) || [];
  }
);

/**
 * Fetches a single poller by filtering the cached list of all pollers.
 * This avoids a network request if all pollers are already in the cache.
 */
export const getCachedPoller = cache(
  async (pollerId: string, token?: string): Promise<Poller | undefined> => {
    const pollers = await getCachedPollers(token);
    return pollers.find((p) => p.poller_id === pollerId);
  }
);

/**
 * Fetches the history for a specific poller and caches the result.
 */
export const getCachedPollerHistory = cache(
    async (pollerId: string, token?: string): Promise<HistoryEntry[]> => {
        return (await fetchFromAPI<HistoryEntry[]>(`/pollers/${pollerId}/history`, token, {
            next: { revalidate: REVALIDATE_SECONDS },
        })) || [];
    }
);

/**
 * Fetches metrics for a specific poller and caches the result.
 */
export const getCachedPollerMetrics = cache(
    async (pollerId: string, token?: string): Promise<ServiceMetric[]> => {
        return (await fetchFromAPI<ServiceMetric[]>(`/pollers/${pollerId}/metrics`, token, {
            next: { revalidate: REVALIDATE_SECONDS },
        })) || [];
    }
);

/**
 * Fetches a specific service and caches the result.
 */
export const getCachedService = cache(
    async (pollerId: string, serviceName: string, token?: string): Promise<ServicePayload | null> => {
        return await fetchFromAPI<ServicePayload>(`/pollers/${pollerId}/services/${serviceName}`, token, {
            next: { revalidate: REVALIDATE_SECONDS },
        });
    }
);

/**
 * Fetches the overall system status and caches the result.
 */
export const getCachedSystemStatus = cache(
    async (token?: string): Promise<SystemStatus | null> => {
        return await fetchFromAPI<SystemStatus>('/status', token, {
            next: { revalidate: REVALIDATE_SECONDS },
        });
    }
);

/**
 * Fetches SNMP data for a specific poller and time range, and caches the result.
 */
export const getCachedSnmpData = cache(
    async (pollerId: string, timeRange: string, token?: string): Promise<SnmpDataPoint[]> => {
        const end = new Date();
        const start = new Date();
        switch (timeRange) {
            case '6h': start.setHours(end.getHours() - 6); break;
            case '24h': start.setHours(end.getHours() - 24); break;
            default: start.setHours(end.getHours() - 1); break;
        }

        const endpoint = `/pollers/${pollerId}/snmp?start=${start.toISOString()}&end=${end.toISOString()}`;
        return (await fetchFromAPI<SnmpDataPoint[]>(
            endpoint,
            token,
            { next: { revalidate: REVALIDATE_SECONDS } }
        )) || [];
    }
);

