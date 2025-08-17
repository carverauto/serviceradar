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

// src/app/api/auth/verify/route.ts
import { NextRequest, NextResponse } from "next/server";
import { getInternalApiUrl, getApiKey } from "@/lib/config";

// Update in src/app/api/auth/verify/route.ts
export async function GET(req: NextRequest) {
  const apiKey = getApiKey();
  const apiUrl = getInternalApiUrl();

  try {
    // Get the token from the Authorization header
    const authHeader = req.headers.get("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return NextResponse.json({ error: "Missing token" }, { status: 401 });
    }

    const token = authHeader.substring(7);

    // Forward to your Go API with API key to verify the token
    const response = await fetch(`${apiUrl}/api/status`, {
      headers: {
        Authorization: `Bearer ${token}`,
        "X-API-Key": apiKey,
      },
    });

    if (!response.ok) {
      // Forward the error from the API
      return NextResponse.json(
          { error: "Token verification failed" },
          { status: response.status },
      );
    }

    // Token is valid, return success with user info
    return NextResponse.json({ verified: true });
  } catch (error) {
    console.error("Token verification error:", error);
    return NextResponse.json(
        { error: "Internal server error during token verification" },
        { status: 500 },
    );
  }
}
