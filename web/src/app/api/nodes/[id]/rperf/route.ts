// src/app/api/nodes/[id]/rperf/route.ts
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
        const authHeader = req.headers.get("authorization");
        const headers: HeadersInit = {
            "Content-Type": "application/json",
            "X-API-Key": apiKey,
        };
        if (authHeader) headers["Authorization"] = authHeader;

        const url = `${apiUrl}/api/nodes/${nodeId}/rperf${start && end ? `?start=${start}&end=${end}` : ""}`;
        const response = await fetch(url, {
            headers,
            cache: "no-store",
        });

        if (!response.ok) {
            const errorMessage = await response.text();
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