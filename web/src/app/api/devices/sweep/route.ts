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

export async function GET(req: NextRequest) {
  const apiKey = process.env.API_KEY || "";
  const apiUrl = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8090";

  try {
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

    // Query the device_updates using SRQL syntax - device-centric, not poller-centric
    const query = `show device_updates order by timestamp desc limit 10000`;
    
    // Forward request to Go API query endpoint
    const response = await fetch(
        `${apiUrl}/api/query`,
        {
          method: "POST",
          headers,
          body: JSON.stringify({ query }),
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