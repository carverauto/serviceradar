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

// src/app/api/pollers/[id]/metrics/route.ts
import {NextRequest, NextResponse} from "next/server";
import {ServiceMetric} from "@/types/types";

// Define the props type for the dynamic route
interface RouteProps {
  params: Promise<{ id: string }>; // params is a Promise due to async nature
}

// Define the response type (already present but kept for clarity)
export async function GET(req: NextRequest, props: RouteProps) {
  const params = await props.params; // Await the params Promise
  const pollerId = params.id;
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

    // Forward request to Go API
    const response = await fetch(`${apiUrl}/api/pollers/${pollerId}/metrics`, {
      method: "GET",
      headers,
      cache: "no-store",
    });

    // Check for and handle errors
    if (!response.ok) {
      const status = response.status;
      let errorMessage: string;

      try {
        errorMessage = await response.text();
      } catch {
        errorMessage = `Status code: ${status}`;
      }

      // Return error response
      return NextResponse.json(
          { error: "Failed to fetch metrics", details: errorMessage },
          { status },
      );
    }

    // Return successful response
    const data: ServiceMetric[] = await response.json();
    return NextResponse.json(data);
  } catch (error) {
    console.error(`Error fetching metrics for poller ${pollerId}:`, error);

    return NextResponse.json(
        { error: "Internal server error while fetching metrics" },
        { status: 500 },
    );
  }
}