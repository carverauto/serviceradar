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

import { RperfMetric } from '@/types/rperf';

interface RperfData {
    pollerId: string;
    rperfMetrics: RperfMetric[];
}

interface CachedRperfData {
    data: RperfData[];
    timestamp: number;
    promise?: Promise<RperfData[]>;
}

class RperfService {
    private cache: CachedRperfData | null = null;
    private readonly CACHE_DURATION = 30000; // 30 seconds cache
    private subscribers: Set<() => void> = new Set();

    async getRperfData(token?: string): Promise<RperfData[]> {
        const now = Date.now();
        
        // Return cached data if still valid
        if (this.cache && (now - this.cache.timestamp) < this.CACHE_DURATION) {
            return this.cache.data;
        }
        
        // If there's already a request in flight, wait for it
        if (this.cache?.promise) {
            return this.cache.promise;
        }
        
        // Start new request
        const promise = this.fetchRperfData(token);
        
        // Store the promise to prevent duplicate requests
        if (this.cache) {
            this.cache.promise = promise;
        } else {
            this.cache = {
                data: [],
                timestamp: 0,
                promise
            };
        }
        
        try {
            const data = await promise;
            
            // Update cache with successful result
            this.cache = {
                data,
                timestamp: now,
                promise: undefined
            };
            
            // Notify all subscribers
            this.notifySubscribers();
            
            return data;
        } catch (error) {
            // Clear the promise on error so retry can work
            if (this.cache) {
                this.cache.promise = undefined;
            }
            throw error;
        }
    }

    private async fetchRperfData(token?: string): Promise<RperfData[]> {
        const headers = {
            'Content-Type': 'application/json',
            ...(token && { Authorization: `Bearer ${token}` }),
        };

        // Get pollers that have rperf services
        const pollersResponse = await fetch('/api/pollers', { headers });
        
        if (!pollersResponse.ok) {
            throw new Error('Failed to fetch pollers');
        }

        const pollersData = await pollersResponse.json();
        const rperfPollers = pollersData.filter((poller: {
            poller_id: string;
            services?: { type: string; name: string }[];
        }) => 
            poller.services?.some((s) => s.type === 'grpc' && s.name === 'rperf-checker')
        );

        if (rperfPollers.length === 0) {
            return [];
        }

        // Get data for the last 2 hours to calculate trends
        const endTime = new Date();
        const startTime = new Date(endTime.getTime() - 2 * 60 * 60 * 1000);
        
        const rperfPromises = rperfPollers.map(async (poller: { poller_id: string }) => {
            const url = `/api/pollers/${poller.poller_id}/rperf?start=${startTime.toISOString()}&end=${endTime.toISOString()}`;
            
            try {
                const response = await fetch(url, { headers });
                if (!response.ok) {
                    console.error(`RPerf API error for poller ${poller.poller_id}: ${response.status}`);
                    return { pollerId: poller.poller_id, rperfMetrics: [] };
                }
                const metrics = await response.json() as RperfMetric[];
                return { pollerId: poller.poller_id, rperfMetrics: metrics };
            } catch (err) {
                console.error(`Error fetching rperf for poller ${poller.poller_id}:`, err);
                return { pollerId: poller.poller_id, rperfMetrics: [] };
            }
        });
        
        return Promise.all(rperfPromises);
    }

    // Subscription system for real-time updates
    subscribe(callback: () => void): () => void {
        this.subscribers.add(callback);
        return () => this.subscribers.delete(callback);
    }

    private notifySubscribers(): void {
        this.subscribers.forEach(callback => callback());
    }

    // Method to force refresh
    refresh(token?: string): Promise<RperfData[]> {
        this.cache = null;
        return this.getRperfData(token);
    }

    // Check if cache is valid
    isCacheValid(): boolean {
        if (!this.cache) return false;
        const now = Date.now();
        return (now - this.cache.timestamp) < this.CACHE_DURATION;
    }
}

// Export singleton instance
export const rperfService = new RperfService();