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

// src/app/api/pollers/route.ts
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

    // Create AbortController for timeout
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 15000); // 15 second timeout

    try {
      // Forward to your Go API with timeout
      const response = await fetch(`${apiUrl}/api/pollers`, {
        headers,
        signal: controller.signal,
      });

      clearTimeout(timeoutId);

      if (!response.ok) {
        let errorDetail = "Unknown error";
        try {
          const errorData = await response.text();
          errorDetail = errorData || `HTTP ${response.status}`;
        } catch {
          errorDetail = `HTTP ${response.status}`;
        }

        console.error(`Pollers API error: ${response.status} - ${errorDetail}`);
        
        return NextResponse.json(
          { 
            error: "Failed to fetch pollers",
            detail: errorDetail,
            status: response.status,
          },
          { status: response.status },
        );
      }

      // Forward the successful response
      const data = await response.json();
      return NextResponse.json(data);
    } catch (fetchError) {
      clearTimeout(timeoutId);
      throw fetchError;
    }
  } catch (error) {
    console.error("Error fetching pollers:", error);

    // Determine error type and provide specific message
    let errorMessage = "Internal server error while fetching pollers";
    let statusCode = 500;

    if (error instanceof Error) {
      if (error.name === 'AbortError') {
        errorMessage = "Request timeout while fetching pollers";
        statusCode = 504; // Gateway Timeout
      } else if (error.message.includes('ECONNREFUSED')) {
        errorMessage = "Backend service unavailable";
        statusCode = 503; // Service Unavailable
      } else if (error.message.includes('ENOTFOUND')) {
        errorMessage = "Backend service not found";
        statusCode = 502; // Bad Gateway
      }
    }

    return NextResponse.json(
      { 
        error: errorMessage,
        detail: error instanceof Error ? error.message : "Unknown error"
      },
      { status: statusCode },
    );
  }
}
