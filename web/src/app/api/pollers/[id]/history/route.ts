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

// src/app/api/pollers/[id]/history/route.ts
import { NextRequest, NextResponse } from "next/server";
import { getInternalApiUrl, getApiKey } from "@/lib/config";

// Define the expected history data structure
export interface HistoryEntry {
  timestamp: string; // ISO string
  is_healthy: boolean;
  [key: string]: unknown; // Allow additional fields
}

// Define the props type for the dynamic route
interface RouteProps {
  params: Promise<{ id: string }>; // params is a Promise due to async nature
}

export async function GET(req: NextRequest, props: RouteProps) {
  const params = await props.params; // Await the params Promise
  const pollerId = params.id;
  const apiKey = getApiKey();
  const apiUrl = getInternalApiUrl();

  try {
    const authHeader = req.headers.get("authorization");
    const headers: HeadersInit = {
      "Content-Type": "application/json",
      "X-API-Key": apiKey,
    };

    if (authHeader) {
      headers["Authorization"] = authHeader;
    }

    const response = await fetch(`${apiUrl}/api/pollers/${pollerId}/history`, {
      method: "GET",
      headers,
      cache: "no-store",
    });

    if (!response.ok) {
      const status = response.status;
      let errorMessage: string;
      try {
        const errorText = await response.text();
        console.error(`History API error (${status}): ${errorText}`);
        errorMessage = errorText;
      } catch {
        errorMessage = `Status code: ${status}`;
      }
      return NextResponse.json(
          { error: "Failed to fetch history", details: errorMessage },
          { status },
      );
    }

    const data: HistoryEntry[] = await response.json();
    return NextResponse.json(data);
  } catch (error) {
    console.error(`Error fetching history for poller ${pollerId}:`, error);
    return NextResponse.json(
        { error: "Internal server error while fetching history" },
        { status: 500 },
    );
  }
}