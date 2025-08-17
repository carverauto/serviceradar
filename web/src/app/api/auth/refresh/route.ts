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

// src/app/api/auth/refresh/route.ts
import { NextRequest, NextResponse } from "next/server";
import { getInternalApiUrl, getApiKey } from "@/lib/config";

export async function POST(req: NextRequest) {
  const apiKey = getApiKey();
  const apiUrl = getInternalApiUrl();

  try {
    // Parse the request body to get the refresh token
    const body = await req.json();
    const refreshToken = body.refresh_token || body.refreshToken;

    if (!refreshToken) {
      return NextResponse.json(
        { error: "Missing refresh token" },
        { status: 400 },
      );
    }

    // Forward to your Go API with API key
    const response = await fetch(`${apiUrl}/auth/refresh`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": apiKey,
      },
      body: JSON.stringify({ refresh_token: refreshToken }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error(
        `Token refresh failed with status ${response.status}: ${errorText}`,
      );

      return NextResponse.json(
        { error: "Token refresh failed", details: errorText },
        { status: response.status },
      );
    }

    // Forward the successful response
    const data = await response.json();
    return NextResponse.json(data);
  } catch (error) {
    console.error("Token refresh error:", error);
    return NextResponse.json(
      { error: "Internal server error during token refresh" },
      { status: 500 },
    );
  }
}
