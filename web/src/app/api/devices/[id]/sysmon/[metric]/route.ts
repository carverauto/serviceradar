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

// src/app/api/devices/[id]/sysmon/[metric]/route.ts
import { NextRequest, NextResponse } from 'next/server';
import { getInternalApiUrl, getApiKey } from '@/lib/config';

interface RouteProps {
    params: Promise<{ id: string; metric: string }>;
}

export async function GET(req: NextRequest, props: RouteProps) {
    const params = await props.params;
    const deviceId = params.id;
    const metric = params.metric.toLowerCase();
    const apiKey = getApiKey();
    const apiUrl = getInternalApiUrl();
    const { searchParams } = new URL(req.url);
    const start = searchParams.get('start');
    const end = searchParams.get('end');

    // Validate metric type
    const validMetrics = ['cpu', 'disk', 'memory', 'processes'];
    if (!validMetrics.includes(metric)) {
        console.error(`Invalid metric requested: ${metric}`);
        return NextResponse.json(
            { error: `Invalid metric type. Must be one of: ${validMetrics.join(', ')}` },
            { status: 400 },
        );
    }

    try {
        // Get authentication headers from the incoming request
        const authHeader = req.headers.get('authorization');
        const xApiKey = req.headers.get('x-api-key');
        
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
            // Fallback to environment variable API key if not provided
            headers['X-API-Key'] = apiKey;
        }

        const queryString = start && end ? `?start=${encodeURIComponent(start)}&end=${encodeURIComponent(end)}` : '';
        const url = `${apiUrl}/api/devices/${encodeURIComponent(deviceId)}/sysmon/${metric}${queryString}`;

        console.log(`Fetching Sysmon ${metric} data for device ${deviceId} from ${url}`);
        console.log(`Query params: start=${start}, end=${end}`);

        const response = await fetch(url, {
            headers,
            cache: 'no-store',
        });

        console.log(`API response status: ${response.status}`);

        if (!response.ok) {
            const errorMessage = await response.text();
            console.error(`Failed to fetch Sysmon ${metric} data: ${errorMessage}`);
            return NextResponse.json(
                { error: `Failed to fetch Sysmon ${metric} data`, details: errorMessage },
                { status: response.status },
            );
        }

        const data = await response.json();
        console.log(`Response data length: ${JSON.stringify(data).length}`);
        console.log(`Response data sample: ${JSON.stringify(data).slice(0, 200)}...`);

        // Optional: Transform data if backend format doesn't match frontend expectations
        let transformedData;
        if (metric === 'cpu') {
            transformedData = Array.isArray(data) ? data : {
                cpus: data.cpus || [],
                timestamp: data.timestamp || new Date().toISOString(),
            };
        } else if (metric === 'memory') {
            transformedData = Array.isArray(data) ? data : {
                memory: {
                    used_bytes: data.memory?.used_bytes || 0,
                    total_bytes: data.memory?.total_bytes || 1,
                },
                timestamp: data.timestamp || new Date().toISOString(),
            };
        } else if (metric === 'disk') {
            transformedData = Array.isArray(data) ? data : {
                disks: data.disks || [],
                timestamp: data.timestamp || new Date().toISOString(),
            };
        } else if (metric === 'processes') {
            transformedData = Array.isArray(data) ? data : {
                processes: data.processes || [],
                timestamp: data.timestamp || new Date().toISOString(),
            };
        }

        return NextResponse.json(transformedData);
    } catch (error) {
        console.error(`Error fetching Sysmon ${metric} data for device ${deviceId}:`, error);
        return NextResponse.json(
            { error: `Internal server error while fetching Sysmon ${metric} data`, details: error},
            { status: 500 },
        );
    }
}