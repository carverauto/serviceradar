// src/app/api/nodes/[id]/rperf/route.ts - Update this file
import { NextRequest, NextResponse } from "next/server";

interface RouteProps {
    params: Promise<{ id: string }>;
}

export async function GET(req: NextRequest, props: RouteProps) {
    const params = await props.params;
    const nodeId = params.id;
    const apiKey = process.env.API_KEY || "";
    const apiUrl = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8090";
    const { searchParams } = new URL(req.url);
    const start = searchParams.get("start");
    const end = searchParams.get("end");

    try {
        // Get the token from authorization header or cookie
        const authHeader = req.headers.get("authorization");
        const accessTokenCookie = req.cookies.get("accessToken")?.value;

        const headers: HeadersInit = {
            "Content-Type": "application/json",
            "X-API-Key": apiKey,
        };

        // Prioritize the authorization header, fall back to cookie
        if (authHeader) {
            headers["Authorization"] = authHeader;
            console.log("Using Authorization header for rperf API call");
        } else if (accessTokenCookie) {
            headers["Authorization"] = `Bearer ${accessTokenCookie}`;
            console.log("Using cookie token for rperf API call");
        }

        // Make sure to properly format the URL with query parameters
        let url = `${apiUrl}/api/nodes/${nodeId}/rperf`;
        if (start && end) {
            url += `?start=${encodeURIComponent(start)}&end=${encodeURIComponent(end)}`;
        }

        console.log(`Fetching rperf data from: ${url}`);

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

        const data = await response.json();
        return NextResponse.json(data);
    } catch (error) {
        console.error(`Error fetching rperf metrics for node ${nodeId}:`, error);
        return NextResponse.json(
            { error: "Internal server error while fetching rperf metrics" },
            { status: 500 },
        );
    }
}