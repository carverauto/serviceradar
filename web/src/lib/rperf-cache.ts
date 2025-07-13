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

interface CacheEntry {
    data: RperfMetric[];
    timestamp: number;
    promise?: Promise<RperfMetric[]>;
}

class RperfCache {
    private cache = new Map<string, CacheEntry>();
    private readonly TTL = 30000; // 30 seconds
    private static instanceCount = 0;
    private instanceId: number;

    constructor() {
        RperfCache.instanceCount++;
        this.instanceId = RperfCache.instanceCount;
        console.log(`[RPerf Cache] Creating instance #${this.instanceId}`);
    }

    private roundToMinute(date: Date): Date {
        const rounded = new Date(date);
        rounded.setSeconds(0, 0); // Round down to the minute
        return rounded;
    }

    async getRperfData(
        pollerId: string, 
        startTime: Date, 
        endTime: Date, 
        token?: string
    ): Promise<RperfMetric[]> {
        // Round timestamps to nearest minute for better cache hits
        const roundedStart = this.roundToMinute(startTime);
        const roundedEnd = this.roundToMinute(endTime);
        const cacheKey = `${pollerId}-${roundedStart.toISOString()}-${roundedEnd.toISOString()}`;
        const now = Date.now();
        
        console.log(`[RPerf Cache#${this.instanceId} Check] ${pollerId} - Key: ${cacheKey}`);
        
        // Check cache first
        const cached = this.cache.get(cacheKey);
        if (cached && (now - cached.timestamp) < this.TTL) {
            console.log(`[RPerf Cache#${this.instanceId} Hit] ${pollerId} - Age: ${now - cached.timestamp}ms`);
            // If there's a pending promise, wait for it
            if (cached.promise) {
                console.log(`[RPerf Cache#${this.instanceId} Pending Promise] ${pollerId}`);
                return cached.promise;
            }
            return cached.data;
        }
        
        // If there's already a pending request for this key, return that promise
        if (cached?.promise) {
            console.log(`[RPerf Cache#${this.instanceId} Sharing Promise] ${pollerId}`);
            return cached.promise;
        }
        
        console.log(`[RPerf Cache#${this.instanceId} Miss] ${pollerId} - Making API call`);
        
        // Create the API request using rounded timestamps for consistency
        const url = `/api/pollers/${pollerId}/rperf?start=${roundedStart.toISOString()}&end=${roundedEnd.toISOString()}`;
        console.log(`[RPerf API Call] ${url}`);
        const promise = fetch(url, {
            headers: {
                'Content-Type': 'application/json',
                ...(token && { Authorization: `Bearer ${token}` }),
            },
        })
        .then(res => {
            if (!res.ok) {
                console.error(`RPerf API error for poller ${pollerId}: ${res.status}`);
                return [];
            }
            return res.json() as Promise<RperfMetric[]>;
        })
        .then(data => {
            console.log(`[RPerf API Success] ${pollerId} - Got ${data.length} metrics`);
            // Cache the result and remove the promise
            this.cache.set(cacheKey, { data, timestamp: now });
            return data;
        })
        .catch((err) => {
            console.error(`[RPerf API Error] ${pollerId}:`, err);
            // Remove the failed promise from cache
            this.cache.delete(cacheKey);
            return [];
        });
        
        // Store the promise in cache while it's pending
        this.cache.set(cacheKey, { data: [], timestamp: now, promise });
        
        return promise;
    }

    clearCache() {
        this.cache.clear();
    }

    getCacheStats() {
        return {
            size: this.cache.size,
            entries: Array.from(this.cache.entries()).map(([key, entry]) => ({
                key,
                age: Date.now() - entry.timestamp,
                hasPendingRequest: !!entry.promise
            }))
        };
    }
}

// Global singleton instance
export const rperfCache = new RperfCache();