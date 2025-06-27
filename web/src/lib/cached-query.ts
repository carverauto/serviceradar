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

import { fetchAPI } from '@/lib/client-api';

// Cache store for query results
const queryCache = new Map<string, { data: any; timestamp: number }>();
const pendingQueries = new Map<string, Promise<any>>();

// Cache configuration
const CACHE_TTL = 30000; // 30 seconds cache TTL

export async function cachedQuery<T>(
    query: string,
    token?: string,
    ttl: number = CACHE_TTL
): Promise<T> {
    const cacheKey = `query:${query}`;
    const now = Date.now();
    
    // Check if we have valid cached data
    const cached = queryCache.get(cacheKey);
    if (cached && (now - cached.timestamp) < ttl) {
        console.log(`[Query Cache Hit] ${query}`);
        return cached.data;
    }
    
    // Check if there's already a pending request
    if (pendingQueries.has(cacheKey)) {
        console.log(`[Query Dedup] Waiting for existing query: ${query}`);
        return pendingQueries.get(cacheKey);
    }
    
    // Create the query promise
    const queryPromise = (async () => {
        try {
            console.log(`[Query Fetch] Executing: ${query}`);
            
            const data = await fetchAPI<T>('/api/query', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    ...(token && { Authorization: `Bearer ${token}` }),
                },
                body: JSON.stringify({ query }),
            });
            
            // Cache the successful response
            queryCache.set(cacheKey, {
                data,
                timestamp: now
            });
            
            // Clean up pending query
            pendingQueries.delete(cacheKey);
            
            return data;
        } catch (error) {
            // Clean up pending query on error
            pendingQueries.delete(cacheKey);
            
            // If we have stale cached data, return it instead of failing
            if (cached) {
                console.warn(`[Query Fallback] Using stale cache due to error: ${error}`);
                return cached.data;
            }
            
            throw error;
        }
    })();
    
    // Store the pending query
    pendingQueries.set(cacheKey, queryPromise);
    
    return queryPromise;
}

// Clear specific query from cache
export function clearQueryCache(query?: string) {
    if (query) {
        const cacheKey = `query:${query}`;
        queryCache.delete(cacheKey);
        pendingQueries.delete(cacheKey);
        console.log(`[Query Cache] Cleared cache for: ${query}`);
    } else {
        queryCache.clear();
        pendingQueries.clear();
        console.log('[Query Cache] Cleared all query cache');
    }
}

// Cleanup old cache entries periodically
setInterval(() => {
    const now = Date.now();
    const expiredKeys: string[] = [];
    
    queryCache.forEach((value, key) => {
        if (now - value.timestamp > CACHE_TTL * 2) {
            expiredKeys.push(key);
        }
    });
    
    expiredKeys.forEach(key => {
        queryCache.delete(key);
        console.log(`[Query Cache Cleanup] Removed expired entry: ${key}`);
    });
}, 60000); // Run cleanup every minute