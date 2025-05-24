// src/app/api/query/route.ts
import { NextRequest, NextResponse } from "next/server";
import { env } from "next-runtime-env";

export async function POST(req: NextRequest) {
    const apiKey = env("API_KEY") || ""; // Server-side env
    const apiUrl = env("NEXT_PUBLIC_API_URL") || "http://localhost:8090"; // Server-side env

    try {
        const body = await req.json();
        const { query } = body;

        if (!query) {
            return NextResponse.json(
                { error: "Query is required" },
                { status: 400 },
            );
        }

        // Headers from the incoming request (managed by middleware.ts)
        // The middleware should have already added X-API-Key and Authorization if applicable.
        // We just need to ensure Content-Type is set for the backend.
        const requestHeaders = new Headers(req.headers); // Clone headers from middleware
        requestHeaders.set("Content-Type", "application/json");
        // Remove host header to avoid issues with proxies
        requestHeaders.delete("host");


        const backendResponse = await fetch(`${apiUrl}/api/query`, {
            method: "POST",
            headers: requestHeaders, // Pass through headers from middleware + Content-Type
            body: JSON.stringify({ query }), // Send the query in the expected format
            cache: "no-store",
        });

        const responseData = await backendResponse.json();

        if (!backendResponse.ok) {
            return NextResponse.json(
                responseData || { error: "Failed to execute query on backend" },
                { status: backendResponse.status },
            );
        }

        return NextResponse.json(responseData);
    } catch (error) {
        console.error("Error in /api/query route:", error);
        const errorMessage = error instanceof Error ? error.message : "Internal server error";
        return NextResponse.json(
            { error: "Internal server error processing query", details: errorMessage },
            { status: 500 },
        );
    }
}