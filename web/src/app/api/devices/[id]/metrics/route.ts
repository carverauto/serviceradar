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

// src/app/api/devices/[id]/metrics/route.ts
import {NextRequest, NextResponse} from "next/server";
import { getInternalApiUrl, getApiKey } from "@/lib/config";

// Define the props type for the dynamic route
interface RouteProps {
  params: Promise<{ id: string }>; // params is a Promise due to async nature
}

export async function GET(req: NextRequest, props: RouteProps) {
  const params = await props.params; // Await the params Promise
  const deviceId = decodeURIComponent(params.id); // Decode in case device_id contains special characters like ':'
  const apiKey = getApiKey();
  const apiUrl = getInternalApiUrl();

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

    // Get query parameters
    const { searchParams } = new URL(req.url);
    const params2 = new URLSearchParams();
    
    // Forward relevant query parameters
    if (searchParams.get('start')) params2.set('start', searchParams.get('start')!);
    if (searchParams.get('end')) params2.set('end', searchParams.get('end')!);
    if (searchParams.get('type')) params2.set('type', searchParams.get('type')!);
    if (searchParams.get('limit')) params2.set('limit', searchParams.get('limit')!);

    // Forward request to Go API
    const queryString = params2.toString();
    const url = `${apiUrl}/api/devices/${encodeURIComponent(deviceId)}/metrics${queryString ? `?${queryString}` : ''}`;
    
    const response = await fetch(url, {
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
          { error: "Failed to fetch device metrics", details: errorMessage },
          { status },
      );
    }

    // Return successful response
    const data = await response.json();
    return NextResponse.json(data);
  } catch (error) {
    console.error(`Error fetching metrics for device ${deviceId}:`, error);

    return NextResponse.json(
        { error: "Internal server error while fetching device metrics" },
        { status: 500 },
    );
  }
}