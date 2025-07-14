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
import { RperfMetric } from '@/types/rperf';

interface UseMultiPollerRperfDataOptions {
    pollerIds: string[];
    startTime: Date;
    endTime: Date;
    enabled?: boolean;
}

export const useMultiPollerRperfData = ({ 
    pollerIds, 
    startTime, 
    endTime, 
    enabled = true 
}: UseMultiPollerRperfDataOptions) => {
    const { token } = useAuth();

    console.log(`[useMultiPollerRperfData] Hook called with:`, {
        pollerIds,
        pollerIdsLength: pollerIds.length,
        startTime: startTime.toISOString(),
        endTime: endTime.toISOString(),
        enabled,
        tokenAvailable: !!token,
        effectiveEnabled: enabled && !!token
    });

    const queries = useQueries({
        queries: pollerIds.map(pollerId => ({
            queryKey: [
                'rperf', 
                pollerId, 
                // Round to nearest minute for better cache hits
                Math.floor(startTime.getTime() / 60000), 
                Math.floor(endTime.getTime() / 60000)
            ],
            queryFn: async (): Promise<RperfMetric[]> => {
                console.log(`[React Query Multi] Starting fetch for ${pollerId} from ${startTime.toISOString()} to ${endTime.toISOString()}`);
                console.log(`[React Query Multi] Token available:`, !!token);
                console.log(`[React Query Multi] Enabled:`, enabled);
                
                const url = `/api/pollers/${pollerId}/rperf?start=${startTime.toISOString()}&end=${endTime.toISOString()}`;
                console.log(`[React Query Multi] Fetching URL:`, url);
                
                const response = await fetch(url, {
                    headers: {
                        'Content-Type': 'application/json',
                        ...(token && { Authorization: `Bearer ${token}` }),
                    },
                });

                console.log(`[React Query Multi] Response status for ${pollerId}:`, response.status);

                if (!response.ok) {
                    const errorText = await response.text();
                    console.error(`RPerf API error for poller ${pollerId}: ${response.status} - ${errorText}`);
                    throw new Error(`Failed to fetch rperf data for ${pollerId}: ${response.status}`);
                }

                const data = await response.json();
                console.log(`[React Query Multi] Successfully got ${data.length} rperf metrics for ${pollerId}`);
                return data;
            },
            enabled: enabled && !!token,
            staleTime: 30000, // 30 seconds
            refetchInterval: 60000, // 60 seconds
        }))
    });

    // Aggregate results
    const isLoading = queries.some(query => query.isLoading);
    const isError = queries.some(query => query.isError);
    const errors = queries.filter(query => query.error).map(query => query.error);
    
    // Flatten all successful results
    const allData = queries
        .filter(query => query.data)
        .flatMap(query => query.data || []);

    console.log(`[useMultiPollerRperfData] Results:`, {
        totalQueries: queries.length,
        queriesWithData: queries.filter(q => q.data).length,
        allDataLength: allData.length,
        isLoading,
        isError,
        queryStates: queries.map(q => ({
            status: q.status,
            hasData: !!q.data,
            dataLength: q.data?.length || 0,
            error: q.error?.message
        }))
    });

    return {
        data: allData,
        isLoading,
        isError,
        errors,
        queries, // Individual query results for debugging
    };
};