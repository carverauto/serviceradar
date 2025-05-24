// src/app/api/query/route.ts
import { NextRequest, NextResponse } from "next/server";
import { env } from 'next-runtime-env';

export async function POST(req: NextRequest) {
    const apiKey = env("API_KEY") || "";  // Change this line
    const apiUrl = env("NEXT_PUBLIC_API_URL") || "http://localhost:8090";  // And optionally this one

    console.log("[API Query Route] Received request to /api/query");

    // Add an explicit check for apiKey early on
    if (!apiKey) {
        console.error("[API Query Route] Error: API_KEY is not configured in the environment.");
        return NextResponse.json(
            { error: "Server configuration error: API key is missing." },
            { status: 500 }
        );
    }

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
        } else {
            // If AUTH_ENABLED is true (implicitly, as backend requires token),
            // and authHeader is missing, this indicates a problem.
            // Middleware should ideally catch this if AUTH_ENABLED=true and cookie is missing.
            // If APIQueryClient also failed to send a token, this is where it would be missing.
            console.warn("[API Query Route] Authorization header is missing from the incoming request.");
            // Depending on how strict AUTH_ENABLED is, you might return 401 here,
            // but the Go backend will likely do it if it's missing.
        }

        console.log(`[API Query Route] Forwarding to: ${apiUrl}/api/query. API Key Present: ${apiKey ? 'Yes' : 'No'}, Auth Header Present: ${authHeader ? 'Yes' : 'No'}`);
        // Sensitive values (actual key/token) should not be logged directly in production.
        // The current logging of presence is good.

        const backendResponse = await fetch(`${apiUrl}/api/query`, {
            method: "POST",
            headers: headersToBackend,
            body: JSON.stringify({ query }),
            cache: "no-store",
        });

        // ... (rest of your error handling and response forwarding)
        if (!backendResponse.ok) {
            let errorData;
            const contentType = backendResponse.headers.get("content-type");
            if (contentType && contentType.includes("application/json")) {
                errorData = await backendResponse.json();
            } else {
                const textError = await backendResponse.text();
                errorData = { error: "Backend returned non-JSON error response", details: textError.substring(0, 500) };
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