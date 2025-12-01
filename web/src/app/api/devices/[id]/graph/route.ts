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

// src/app/api/devices/[id]/graph/route.ts
import { NextRequest, NextResponse } from "next/server";
import { getApiKey, getInternalApiUrl } from "@/lib/config";

interface RouteProps {
  params: Promise<{ id: string }>;
}

export async function GET(req: NextRequest, props: RouteProps) {
  const params = await props.params;
  const deviceId = decodeURIComponent(params.id);
  const apiUrl = getInternalApiUrl();
  const apiKey = getApiKey();

  try {
    const authHeader = req.headers.get("authorization");
    const headers: HeadersInit = {
      "Content-Type": "application/json",
    };
    if (apiKey) {
      headers["X-API-Key"] = apiKey;
    }
    if (authHeader) {
      headers["Authorization"] = authHeader;
    }

    const { searchParams } = new URL(req.url);
    const forwarded = new URLSearchParams();
    ["collector_owned", "collector_owned_only", "include_topology"].forEach(
      (key) => {
        const value = searchParams.get(key);
        if (value !== null) {
          forwarded.set(key, value);
        }
      },
    );

    const target = new URL(
      `${apiUrl}/api/devices/${encodeURIComponent(deviceId)}/graph`,
    );
    forwarded.forEach((value, key) => target.searchParams.set(key, value));

    const response = await fetch(target.toString(), {
      method: "GET",
      headers,
      cache: "no-store",
    });

    if (!response.ok) {
      const status = response.status;
      let errorMessage: string;
      try {
        errorMessage = await response.text();
      } catch {
        errorMessage = `Status code: ${status}`;
      }
      return NextResponse.json(
        { error: "Failed to fetch device graph", details: errorMessage },
        { status },
      );
    }

    const data = await response.json();
    return NextResponse.json(data);
  } catch (error) {
    console.error(`Error fetching graph for device ${deviceId}:`, error);
    return NextResponse.json(
      { error: "Internal server error while fetching device graph" },
      { status: 500 },
    );
  }
}
