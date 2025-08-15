// src/app/api/pollers/[id]/rperf/route.ts - Update this file
import { NextRequest, NextResponse } from "next/server";
import { getInternalApiUrl, getApiKey } from "@/lib/config";
import {RperfMetric} from "@/types/rperf";

interface RouteProps {
    params: Promise<{ id: string }>;
}

export async function GET(req: NextRequest, props: RouteProps) {
    const params = await props.params;
    const pollerId = params.id;
    const apiKey = getApiKey();
    const apiUrl = getInternalApiUrl();
    const { searchParams } = new URL(req.url);
    const start = searchParams.get("start");
    const end = searchParams.get("end");

    try {
        // Get the token from authorization header or cookie
        const authHeader = req.headers.get("authorization");
        const headers: HeadersInit = {
            "Content-Type": "application/json",
            "X-API-Key": apiKey,
        };
        if (authHeader) headers["Authorization"] = authHeader;

        // Make sure to properly format the URL with query parameters
        let url = `${apiUrl}/api/pollers/${pollerId}/rperf`;
        if (start && end) {
            url += `?start=${encodeURIComponent(start)}&end=${encodeURIComponent(end)}`;
        }

        const response = await fetch(url, {
            headers,
            cache: "no-store",
        });

        if (!response.ok) {
            const errorMessage = await response.text();
            console.error(`API error (${response.status}): ${errorMessage}`);
            return NextResponse.json(
                { error: "Failed to fetch rperf metrics", details: errorMessage },
                { status: response.status },
            );
        }

        const data: RperfMetric[] = await response.json();
        return NextResponse.json(data);
    } catch (error) {
        console.error(`Error fetching rperf metrics for poller ${pollerId}:`, error);
        return NextResponse.json(
            { error: "Internal server error while fetching rperf metrics" },
            { status: 500 },
        );
    }
}