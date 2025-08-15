import { NextRequest, NextResponse } from "next/server";
import { getInternalApiUrl, getApiKey } from "@/lib/config";
import { SnmpDataPoint } from "@/types/snmp";

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
        const authHeader = req.headers.get("authorization");
        const headers: HeadersInit = {
            "Content-Type": "application/json",
            "X-API-Key": apiKey,
        };
        if (authHeader) headers["Authorization"] = authHeader;

        const url = `${apiUrl}/api/pollers/${pollerId}/snmp${start && end ? `?start=${start}&end=${end}` : ""}`;
        const response = await fetch(url, {
            headers,
            cache: "no-store",
        });

        if (!response.ok) {
            const errorMessage = await response.text();
            return NextResponse.json(
                { error: "Failed to fetch SNMP data", details: errorMessage },
                { status: response.status },
            );
        }

        const data: SnmpDataPoint[] = await response.json();
        return NextResponse.json(data);
    } catch (error) {
        console.error(`Error fetching SNMP data for poller ${pollerId}:`, error);
        return NextResponse.json(
            { error: "Internal server error while fetching SNMP data" },
            { status: 500 },
        );
    }
}