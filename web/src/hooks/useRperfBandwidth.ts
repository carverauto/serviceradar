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

import { useQuery } from '@tanstack/react-query';
import { useAuth } from '@/components/AuthProvider';
import { RperfMetric } from '@/types/rperf';
import { Poller } from '@/types/types';

interface RperfBandwidthData {
    name: string;
    value: number;
    color: string;
}

export function useRperfBandwidth() {
    const { token } = useAuth();

    return useQuery({
        queryKey: ['rperf-bandwidth', token],
        queryFn: async (): Promise<RperfBandwidthData[]> => {
            console.log('[useRperfBandwidth] Starting data fetch...');
            
            // Fetch pollers data
            const pollersResponse = await fetch('/api/pollers', {
                headers: {
                    'Content-Type': 'application/json',
                    ...(token && { Authorization: `Bearer ${token}` }),
                },
            });

            if (!pollersResponse.ok) {
                throw new Error('Failed to fetch pollers data for rperf analytics');
            }

            const pollersData: Poller[] = await pollersResponse.json();
            console.log('[useRperfBandwidth] Pollers data:', pollersData.length, 'pollers');

            // Filter pollers that have rperf services
            const rperfPollers = pollersData.filter(poller => 
                poller.services?.some(s => s.type === 'grpc' && s.name === 'rperf-checker')
            );
            
            console.log('[useRperfBandwidth] RPerf pollers:', rperfPollers.length);

            if (rperfPollers.length === 0) {
                console.log('[useRperfBandwidth] No pollers with rperf-checker service found');
                return [];
            }

            // Get data for the last 1 hour
            const endTime = new Date();
            const startTime = new Date(endTime.getTime() - 1 * 60 * 60 * 1000); // 1 hour
            console.log('[useRperfBandwidth] Fetching data from', startTime.toISOString(), 'to', endTime.toISOString());

            // Fetch rperf data from all pollers
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
            
            console.log('[useRperfBandwidth] Total rperf metrics fetched:', allRperfData.length);

            // Process the data into chart format
            const rperfBandwidthData: RperfBandwidthData[] = [];
            
            if (allRperfData.length > 0) {
                // Group by target and calculate average bandwidth for each
                const successfulMetrics = allRperfData.filter(metric => metric.success);
                console.log('[useRperfBandwidth] Successful metrics:', successfulMetrics.length, 'out of', allRperfData.length);
                
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
            } else {
                console.log('[useRperfBandwidth] No rperf data found in the last hour');
            }
            
            console.log('[useRperfBandwidth] Returning', rperfBandwidthData.length, 'bandwidth entries');
            return rperfBandwidthData;
        },
        enabled: !!token,
        staleTime: 60000, // 1 minute stale time
        refetchInterval: 60000, // Refetch every minute
    });
}