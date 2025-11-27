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

import { NextRequest, NextResponse } from "next/server";
import { getApiKey, getInternalApiUrl } from "@/lib/config";

interface RouteProps {
  params: Promise<{ id: string }>;
}

export async function POST(req: NextRequest, props: RouteProps) {
  const { id } = await props.params;
  const apiUrl = getInternalApiUrl();
  const apiKey = getApiKey();
  const authHeader = req.headers.get("authorization");

  if (!id) {
    return NextResponse.json({ error: "sighting id is required" }, { status: 400 });
  }

  let reason = "";
  try {
    const body = await req.json();
    if (typeof body?.reason === "string") {
      reason = body.reason;
    }
  } catch {
    // ignore parse errors and fallback to empty reason
  }

  try {
    const response = await fetch(`${apiUrl}/api/identity/sightings/${id}/dismiss`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": apiKey,
        ...(authHeader ? { Authorization: authHeader } : {}),
      },
      body: JSON.stringify({ reason }),
      cache: "no-store",
    });

    if (!response.ok) {
      const errorText = await response.text();
      return NextResponse.json(
        { error: "Failed to dismiss sighting", detail: errorText || response.statusText },
        { status: response.status },
      );
    }

    const data = await response.json();
    return NextResponse.json(data);
  } catch (error) {
    return NextResponse.json(
      {
        error: "Internal server error while dismissing sighting",
        detail: error instanceof Error ? error.message : "unknown error",
      },
      { status: 500 },
    );
  }
}
