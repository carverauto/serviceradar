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

// src/app/api/devices/snmp/status/route.ts
import { NextRequest, NextResponse } from 'next/server';
import { getInternalSrqlUrl, getApiKey } from '@/lib/config';
import { escapeSrqlValue } from '@/lib/srql';

// Simple in-memory cache for SNMP status results
interface CacheEntry {
    statuses: Record<string, { hasMetrics: boolean; status: number }>;
    timestamp: number;
}

// Track in-flight requests to prevent duplicate calls
const inFlightRequests = new Map<string, Promise<Record<string, { hasMetrics: boolean; status: number }>>>();

const statusCache = new Map<string, CacheEntry>();
const CACHE_TTL = 30 * 1000; // 30 seconds cache

export async function POST(req: NextRequest) {
    const apiKey = getApiKey();
    const srqlUrl = getInternalSrqlUrl();

    try {
        const body = await req.json();
        const { deviceIds } = body;

        if (!Array.isArray(deviceIds) || deviceIds.length === 0) {
            return NextResponse.json(
                { error: 'deviceIds array is required and must not be empty' },
                { status: 400 }
            );
        }

        // Create cache key from sorted device IDs
        const cacheKey = deviceIds.sort().join(',');
        
        // Check cache first
        const cachedEntry = statusCache.get(cacheKey);
        if (cachedEntry && Date.now() - cachedEntry.timestamp < CACHE_TTL) {
            console.log(`SNMP cache hit for ${deviceIds.length} devices`);
            return NextResponse.json({ statuses: cachedEntry.statuses });
        }

        // Check if there's already an in-flight request for the same devices
        const existingRequest = inFlightRequests.get(cacheKey);
        if (existingRequest) {
            console.log(`SNMP request deduplication: waiting for existing request for ${deviceIds.length} devices`);
            try {
                const statuses = await existingRequest;
                return NextResponse.json({ statuses });
            } catch {
                // If the existing request failed, we'll proceed to make a new one
                console.log('Existing SNMP request failed, making new request');
                inFlightRequests.delete(cacheKey);
            }
        }

        // Get authentication headers from the incoming request
        const authHeader = req.headers.get('authorization');
        const xApiKey = req.headers.get('x-api-key');
        const cookieHeader = req.headers.get('cookie');
        
        const headers: HeadersInit = {
            'Content-Type': 'application/json',
        };
        
        // Forward authentication headers
        if (authHeader) {
            headers['Authorization'] = authHeader;
        }
        if (xApiKey) {
            headers['X-API-Key'] = xApiKey;
        } else if (apiKey) {
            headers['X-API-Key'] = apiKey;
        }
        if (cookieHeader) {
            headers['Cookie'] = cookieHeader;
        }

        // Create and store the promise for the SRQL query to enable request deduplication
        const executeQuery = async (): Promise<Record<string, { hasMetrics: boolean; status: number }>> => {
            // Use SRQL to efficiently query which devices have recent SNMP metrics
            console.log(`Fetching SNMP status for ${deviceIds.length} devices using SRQL`);
            
            try {
                // Create SRQL query to find devices with recent SNMP metrics (last 2 hours for faster query)
                const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString();
                
                // Query SNMP data using snmp_metrics entity (maps to timeseries_metrics with metric_type='snmp' filter)
                // Note: limit/pagination not supported for most SNMP entities
                const deviceFilters = deviceIds
                    .map((id) => `device_id:"${escapeSrqlValue(String(id))}"`)
                    .join(' ');
                const srqlQuery = {
                    query: `in:snmp_metrics ${deviceFilters} time:[${twoHoursAgo},] sort:timestamp:desc`
                };

            const queryResponse = await fetch(`${srqlUrl}/api/query`, {
                method: 'POST',
                headers,
                body: JSON.stringify(srqlQuery),
                cache: 'no-store'
            });

            let devicesWithMetrics: string[] = [];
            
            if (queryResponse.ok) {
                const queryData = await queryResponse.json();
                // Extract unique device IDs from the results
                const results = queryData.results as Array<{ device_id: string }> || [];
                const uniqueDevices = new Set(results.map(row => row.device_id));
                devicesWithMetrics = Array.from(uniqueDevices);
                console.log(`SNMP SRQL query successful: found ${devicesWithMetrics.length} devices with recent SNMP metrics`);
            } else {
                console.error('SNMP SRQL query failed:', queryResponse.status, await queryResponse.text());
                // If SRQL query fails, we'll return empty results rather than attempting 
                // to call non-existent endpoints
                devicesWithMetrics = [];
                console.log('SNMP SRQL query failed, returning no devices with metrics');
            }

            // Create status map for all requested devices
            const statusMap = deviceIds.reduce((acc, deviceId) => {
                acc[deviceId] = {
                    hasMetrics: devicesWithMetrics.includes(deviceId),
                    status: devicesWithMetrics.includes(deviceId) ? 200 : 404
                };
                return acc;
            }, {} as Record<string, { hasMetrics: boolean; status: number }>);

            // Cache the result
            statusCache.set(cacheKey, {
                statuses: statusMap,
                timestamp: Date.now()
            });

            // Clean up old cache entries (simple cleanup)
            if (statusCache.size > 100) {
                const now = Date.now();
                for (const [key, entry] of statusCache.entries()) {
                    if (now - entry.timestamp > CACHE_TTL * 2) {
                        statusCache.delete(key);
                    }
                }
            }

            return statusMap;
            
        } catch (error) {
            console.error('Error in SRQL SNMP query:', error);
            // If SRQL query fails, return empty results for all devices
            const statusMap = deviceIds.reduce((acc, deviceId) => {
                acc[deviceId] = {
                    hasMetrics: false,
                    status: 500
                };
                return acc;
            }, {} as Record<string, { hasMetrics: boolean; status: number }>);

            console.log('SNMP SRQL query error, returning no devices with metrics');
            return statusMap;
        }
        };

        // Store the promise in the in-flight requests map to enable deduplication
        inFlightRequests.set(cacheKey, executeQuery());

        try {
            // Execute the query and wait for the result
            const statuses = await inFlightRequests.get(cacheKey)!;
            
            // Clean up the in-flight request
            inFlightRequests.delete(cacheKey);
            
            return NextResponse.json({ statuses });
            
        } catch (error) {
            // Clean up the in-flight request on error
            inFlightRequests.delete(cacheKey);
            throw error;
        }

    } catch (error) {
        console.error('Error fetching bulk SNMP status:', error);
        return NextResponse.json(
            { error: 'Internal server error while fetching SNMP status' },
            { status: 500 }
        );
    }
}
