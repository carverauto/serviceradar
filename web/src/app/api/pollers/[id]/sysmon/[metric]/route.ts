// src/app/api/pollers/[id]/sysmon/[metric]/route.ts
import { NextRequest, NextResponse } from 'next/server';

interface RouteProps {
    params: Promise<{ id: string; metric: string }>;
}

export async function GET(req: NextRequest, props: RouteProps) {
    const params = await props.params;
    const pollerId = params.id;
    const metric = params.metric.toLowerCase(); // Normalize to lowercase
    const apiKey = process.env.API_KEY || '';
    const apiUrl = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:8090';
    const { searchParams } = new URL(req.url);
    const start = searchParams.get('start');
    const end = searchParams.get('end');

    // Validate metric type
    const validMetrics = ['cpu', 'disk', 'memory'];
    if (!validMetrics.includes(metric)) {
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

        if (authHeader) {
            headers['Authorization'] = authHeader;
        }

        const url = `${apiUrl}/api/pollers/${pollerId}/sysmon/${metric}${start && end ? `?start=${start}&end=${end}` : ''}`;
        const response = await fetch(url, {
            headers,
            cache: 'no-store',
        });

        if (!response.ok) {
            const errorMessage = await response.text();
            return NextResponse.json(
                { error: `Failed to fetch Sysmon ${metric} data`, details: errorMessage },
                { status: response.status },
            );
        }

        const data = await response.json();
        return NextResponse.json(data);
    } catch (error) {
        console.error(`Error fetching Sysmon ${metric} data for poller ${pollerId}:`, error);
        return NextResponse.json(
            { error: `Internal server error while fetching Sysmon ${metric} data` },
            { status: 500 },
        );
    }
}