// src/app/api/pollers/[id]/sysmon/[metric]/route.ts
import { NextRequest, NextResponse } from 'next/server';
import { getInternalApiUrl, getApiKey } from '@/lib/config';

interface RouteProps {
    params: Promise<{ id: string; metric: string }>;
}

export async function GET(req: NextRequest, props: RouteProps) {
    const params = await props.params;
    const pollerId = params.id;
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
        const authHeader = req.headers.get('authorization');
        const headers: HeadersInit = {
            'Content-Type': 'application/json',
            'X-API-Key': apiKey,
        };
        if (authHeader) headers['Authorization'] = authHeader;

        const queryString = start && end ? `?start=${encodeURIComponent(start)}&end=${encodeURIComponent(end)}` : '';
        const url = `${apiUrl}/api/pollers/${pollerId}/sysmon/${metric}${queryString}`;

        console.log(`Fetching Sysmon ${metric} data for poller ${pollerId} from ${url}`);
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
        console.error(`Error fetching Sysmon ${metric} data for poller ${pollerId}:`, error);
        return NextResponse.json(
            { error: `Internal server error while fetching Sysmon ${metric} data`, details: error},
            { status: 500 },
        );
    }
}