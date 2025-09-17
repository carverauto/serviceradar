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

// src/app/api/devices/sweep/route.ts
import {NextRequest, NextResponse} from "next/server";
import { getInternalApiUrl, getApiKey } from "@/lib/config";

export async function GET(req: NextRequest) {
  const apiKey = getApiKey();
  const apiUrl = getInternalApiUrl();

  try {
    // Get pagination parameters from query string
    const searchParams = req.nextUrl.searchParams;
    const limit = parseInt(searchParams.get("limit") || "100");
    const cursor = searchParams.get("cursor") || "";
    const direction = searchParams.get("direction") || "next";

    // Get authorization header
    const authHeader = req.headers.get("authorization");

    // Create headers for backend request
    const headers: HeadersInit = {
      "Content-Type": "application/json",
      "X-API-Key": apiKey,
    };

    // Add Authorization header if it exists
    if (authHeader) {
      headers["Authorization"] = authHeader;
    }

    // Query the devices using SRQL syntax with proper pagination
    const query = 'in:devices discovery_sources:(sweep) time:last_24h sort:last_seen:desc';
    
    // Build request body with pagination
    const requestBody: {
      query: string;
      limit: number;
      cursor?: string;
      direction?: string;
    } = { 
      query,
      limit
    };
    
    if (cursor) {
      requestBody.cursor = cursor;
      requestBody.direction = direction;
    }
    
    // Forward request to Go API query endpoint
    const response = await fetch(
        `${apiUrl}/api/query`,
        {
          method: "POST",
          headers,
          body: JSON.stringify(requestBody),
          cache: "no-store",
        },
    );

    // Check for and handle errors
    if (!response.ok) {
      const status = response.status;
      let errorMessage: string;

      try {
        errorMessage = await response.text();
      } catch {
        errorMessage = `Status code: ${status}`;
      }

      return NextResponse.json(
          { error: "Failed to fetch sweep host states", details: errorMessage },
          { status },
      );
    }

    // Return successful response
    const data = await response.json();
    return NextResponse.json(data);
  } catch (error) {
    console.error("Error in sweep API:", error);
    return NextResponse.json(
        { error: "Internal server error while fetching sweep host states", details: String(error) },
        { status: 500 },
    );
  }
}
