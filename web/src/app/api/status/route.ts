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

// src/app/api/status/route.ts
import { NextRequest, NextResponse } from "next/server";

export async function GET(req: NextRequest) {
  const apiKey = process.env.API_KEY || "";
  const apiUrl = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8090";

  try {
    // Get the authorization header if it exists
    const authHeader = req.headers.get("Authorization");

    // Create headers with API key
    const headers: HeadersInit = {
      "Content-Type": "application/json",
      "X-API-Key": apiKey,
    };

    // Add Authorization header if present
    if (authHeader) {
      headers["Authorization"] = authHeader;
    }

    // Forward to your Go API
    const response = await fetch(`${apiUrl}/api/status`, {
      headers,
      cache: "no-store",
    });

    if (!response.ok) {
      return NextResponse.json(
        { error: "Failed to fetch status" },
        { status: response.status },
      );
    }

    // Forward the successful response
    const data = await response.json();
    return NextResponse.json(data);
  } catch (error) {
    console.error("Error fetching status:", error);

    return NextResponse.json(
      { error: "Internal server error while fetching status" },
      { status: 500 },
    );
  }
}
