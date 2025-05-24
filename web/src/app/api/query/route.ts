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

        // Get the authorization header if it exists
        const authHeader = req.headers.get("Authorization");

        // Create headers with API key and Content-Type
        const headers: HeadersInit = {
            "Content-Type": "application/json",
            "X-API-Key": apiKey,
        };

        // Add Authorization header if present
        if (authHeader) {
            headers["Authorization"] = authHeader;
        }

        const backendResponse = await fetch(`${apiUrl}/api/query`, {
            method: "POST",
            headers,
            body: JSON.stringify({ query }),
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