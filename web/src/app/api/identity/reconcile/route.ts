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

import { NextResponse } from "next/server";
import { getApiKey, getInternalApiUrl } from "@/lib/config";

export async function POST(req: Request) {
  const apiUrl = getInternalApiUrl();
  const apiKey = getApiKey();
  const authHeader = req.headers.get("authorization");

  try {
    const response = await fetch(`${apiUrl}/api/identity/reconcile`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": apiKey,
        ...(authHeader ? { Authorization: authHeader } : {}),
      },
      cache: "no-store",
    });

    if (!response.ok) {
      const errorText = await response.text();
      return NextResponse.json(
        { error: "Failed to trigger reconciliation", detail: errorText || response.statusText },
        { status: response.status },
      );
    }

    const data = await response.json();
    return NextResponse.json(data);
  } catch (error) {
    return NextResponse.json(
      {
        error: "Internal server error while triggering reconciliation",
        detail: error instanceof Error ? error.message : "unknown error",
      },
      { status: 500 },
    );
  }
}
