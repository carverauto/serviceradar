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
import { getInternalApiUrl, getApiKey } from "@/lib/config";
import { requirePermission } from "@/middleware/rbac";

// Get configuration for a specific service
export async function GET(
  req: NextRequest,
  { params }: { params: { service: string } }
) {
  // Simple auth check - verify token is present
  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) {
    return NextResponse.json(
      { error: 'Unauthorized: Authentication required' },
      { status: 401 }
    );
  }

  const apiKey = getApiKey();
  const apiUrl = getInternalApiUrl();
  const kvStore = req.nextUrl.searchParams.get("kvStore") || "local";

  try {
    const response = await fetch(`${apiUrl}/config/${params.service}?kvStore=${kvStore}`, {
      method: "GET",
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": apiKey,
        "Authorization": req.headers.get("Authorization") || "",
      },
    });

    if (!response.ok) {
      const errorText = await response.text();
      return NextResponse.json(
        { error: `Failed to fetch ${params.service} configuration`, details: errorText },
        { status: response.status }
      );
    }

    const data = await response.json();
    return NextResponse.json(data);
  } catch (error) {
    console.error(`${params.service} config fetch error:`, error);
    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}

// Update configuration for a specific service
export async function PUT(
  req: NextRequest,
  { params }: { params: { service: string } }
) {
  // Simple auth check - verify token is present
  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) {
    return NextResponse.json(
      { error: 'Unauthorized: Authentication required' },
      { status: 401 }
    );
  }

  const apiKey = getApiKey();
  const apiUrl = getInternalApiUrl();
  const kvStore = req.nextUrl.searchParams.get("kvStore") || "local";

  try {
    const body = await req.json();

    const response = await fetch(`${apiUrl}/config/${params.service}?kvStore=${kvStore}`, {
      method: "PUT",
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": apiKey,
        "Authorization": req.headers.get("Authorization") || "",
      },
      body: JSON.stringify(body),
    });

    if (!response.ok) {
      const errorText = await response.text();
      return NextResponse.json(
        { error: `Failed to update ${params.service} configuration`, details: errorText },
        { status: response.status }
      );
    }

    const data = await response.json();
    return NextResponse.json(data);
  } catch (error) {
    console.error(`${params.service} config update error:`, error);
    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}

// Delete configuration for a specific service
export async function DELETE(
  req: NextRequest,
  { params }: { params: { service: string } }
) {
  // Simple auth check - verify token is present
  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) {
    return NextResponse.json(
      { error: 'Unauthorized: Authentication required' },
      { status: 401 }
    );
  }

  const apiKey = getApiKey();
  const apiUrl = getInternalApiUrl();
  const kvStore = req.nextUrl.searchParams.get("kvStore") || "local";

  try {
    const response = await fetch(`${apiUrl}/config/${params.service}?kvStore=${kvStore}`, {
      method: "DELETE",
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": apiKey,
        "Authorization": req.headers.get("Authorization") || "",
      },
    });

    if (!response.ok) {
      const errorText = await response.text();
      return NextResponse.json(
        { error: `Failed to delete ${params.service} configuration`, details: errorText },
        { status: response.status }
      );
    }

    return NextResponse.json({ success: true });
  } catch (error) {
    console.error(`${params.service} config delete error:`, error);
    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}