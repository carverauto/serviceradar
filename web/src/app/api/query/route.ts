// src/app/api/query/route.ts
import { NextRequest, NextResponse } from "next/server";

export async function POST(req: NextRequest) {
    const apiKey = process.env.API_KEY || "";
    const apiUrl = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8090";

    try {
        const body = await req.json();
        const { query } = body;

        if (!query) {
            return NextResponse.json(
                { error: "Query is required" },
                { status: 400 },
            );
        }

        const authHeader = req.headers.get("Authorization");
        const headersToBackend: HeadersInit = {
            "Content-Type": "application/json",
            "X-API-Key": apiKey,
        };

        if (authHeader) {
            headersToBackend["Authorization"] = authHeader;
        }

        console.log(`[API Query Route] Forwarding to: ${apiUrl}/api/query with headers:`, {
            "X-API-Key": apiKey ? 'Present' : 'Absent', // Don't log the key itself
            "Authorization": authHeader ? 'Present' : 'Absent'
        });


        const backendResponse = await fetch(`${apiUrl}/api/query`, {
            method: "POST",
            headers: headersToBackend,
            body: JSON.stringify({ query }),
            cache: "no-store",
        });

        if (!backendResponse.ok) {
            let errorData;
            const contentType = backendResponse.headers.get("content-type");
            if (contentType && contentType.includes("application/json")) {
                errorData = await backendResponse.json();
            } else {
                const textError = await backendResponse.text();
                errorData = { error: "Backend returned non-JSON error response", details: textError.substring(0, 500) }; // Limit length
            }
            console.error(`[API Query Route] Backend error ${backendResponse.status}:`, errorData);
            return NextResponse.json(
                errorData || { error: "Failed to execute query on backend" },
                { status: backendResponse.status },
            );
        }

        const responseData = await backendResponse.json();
        return NextResponse.json(responseData);

    } catch (error) {
        console.error("[API Query Route] Error in route handler:", error);
        const errorMessage = error instanceof Error ? error.message : "Internal server error";
        return NextResponse.json(
            { error: "Internal server error processing query", details: errorMessage },
            { status: 500 },
        );
    }
}