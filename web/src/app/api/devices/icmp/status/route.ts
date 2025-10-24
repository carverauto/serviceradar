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

import { NextRequest, NextResponse } from 'next/server';
import { getInternalApiUrl, getApiKey } from '@/lib/config';

interface CacheEntry {
    statuses: Record<string, { hasMetrics: boolean; status: number }>;
    timestamp: number;
}

const inFlightRequests = new Map<string, Promise<Record<string, { hasMetrics: boolean; status: number }>>>();
const statusCache = new Map<string, CacheEntry>();
const CACHE_TTL = 30 * 1000; // 30 seconds cache

export async function POST(req: NextRequest) {
    const apiKey = getApiKey();
    const apiUrl = getInternalApiUrl();

    try {
        const body = await req.json();
        const { deviceIds } = body;

        if (!Array.isArray(deviceIds) || deviceIds.length === 0) {
            return NextResponse.json(
                { error: 'deviceIds array is required and must not be empty' },
                { status: 400 }
            );
        }

        const cacheKey = deviceIds.sort().join(',');
        
        // Check cache first
        const cached = statusCache.get(cacheKey);
        if (cached && (Date.now() - cached.timestamp) < CACHE_TTL) {
            return NextResponse.json({ statuses: cached.statuses });
        }

        // Check if request is already in flight
        const existingRequest = inFlightRequests.get(cacheKey);
        if (existingRequest) {
            const statuses = await existingRequest;
            return NextResponse.json({ statuses });
        }

        // Get authorization header from incoming request
        const authHeader = req.headers.get("authorization");

        // Create new request
        const requestPromise = fetchICMPStatuses(apiUrl, apiKey, deviceIds, authHeader);
        inFlightRequests.set(cacheKey, requestPromise);

        try {
            const statuses = await requestPromise;
            
            // Cache the results
            statusCache.set(cacheKey, {
                statuses,
                timestamp: Date.now()
            });

            return NextResponse.json({ statuses });
        } finally {
            // Clean up in-flight request
            inFlightRequests.delete(cacheKey);
        }

    } catch (error) {
        console.error('Error in ICMP status bulk fetch:', error);
        return NextResponse.json(
            { error: 'Internal server error while fetching ICMP statuses' },
            { status: 500 }
        );
    }
}

async function fetchICMPStatuses(
    apiUrl: string,
    apiKey: string,
    deviceIds: string[],
    authHeader: string | null
): Promise<Record<string, { hasMetrics: boolean; status: number }>> {
    const buildHeaders = (): HeadersInit => {
        const baseHeaders: HeadersInit = {
            'Content-Type': 'application/json',
        };

        if (apiKey) {
            baseHeaders['X-API-Key'] = apiKey;
        }

        // Forward Authorization header if it exists
        if (authHeader) {
            baseHeaders['Authorization'] = authHeader;
        }

        return baseHeaders;
    };

    const endTime = new Date();
    const startTime = new Date(endTime.getTime() - 60 * 60 * 1000); // Last hour
    
    const promises = deviceIds.map(async (deviceId) => {
        try {
            const queryParams = new URLSearchParams({
                type: 'icmp',
                start: startTime.toISOString(),
                end: endTime.toISOString()
            });

            const url = `${apiUrl}/api/devices/${encodeURIComponent(deviceId)}/metrics?${queryParams}`;
            
            const performFetch = async () => fetch(url, {
                method: 'GET',
                headers: buildHeaders(),
                cache: 'no-store',
            });

            const response = await performFetch();

            if (response.ok) {
                const metrics = await response.json() as Array<unknown>;
                const hasMetrics = metrics && metrics.length > 0;
                console.log(`ICMP status for device ${deviceId}: hasMetrics=${hasMetrics}, metricsCount=${metrics?.length || 0}`);
                if (hasMetrics) {
                    console.log(`ICMP metrics sample for ${deviceId}:`, JSON.stringify(metrics[0], null, 2));
                }
                return [deviceId, { hasMetrics, status: response.status }];
            } else {
                console.log(`ICMP status for device ${deviceId}: HTTP ${response.status} - ${await response.text()}`);
                return [deviceId, { hasMetrics: false, status: response.status }];
            }
        } catch (error) {
            console.error(`Error fetching ICMP status for device ${deviceId}:`, error);
            return [deviceId, { hasMetrics: false, status: 500 }];
        }
    });

    const results = await Promise.all(promises);
    return Object.fromEntries(results);
}
