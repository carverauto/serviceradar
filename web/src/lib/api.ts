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

// web/src/lib/api.ts - server-side utilities with TypeScript
import { SystemStatus, Poller } from "@/types/types";
import { env } from 'next-runtime-env';

export async function fetchFromAPI<T>(
    endpoint: string,
    token?: string,
): Promise<T | null> {
  const normalizedEndpoint = endpoint.replace(/^\/+/, "");

  // Handle both server and client side URL construction properly
  let apiUrl: string;

  if (typeof window === "undefined") {
    // Server-side: Use a fully qualified URL or environment variable
    // const baseApiUrl = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8090";
    const baseApiUrl = env('NEXT_PUBLIC_API_URL') || "http://localhost:8090";
    apiUrl = `${baseApiUrl}/api/${normalizedEndpoint}`;
  } else {
    // Client-side: Use relative URL path
    apiUrl = `/api/${normalizedEndpoint}`;
  }

  const headers: HeadersInit = { "Content-Type": "application/json" };
  const apiKey = process.env.API_KEY;
  if (apiKey) {
    headers["X-API-Key"] = apiKey;
  }
  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }

  try {
    const response = await fetch(apiUrl, {
      headers,
      cache: "no-store",
      credentials: "include",
    });

    if (!response.ok) {
      throw new Error(`API request failed: ${response.status}`);
    }

    return response.json();
  } catch (error) {
    console.error("Error fetching from API:", error);
    return null;
  }
}

// Union type for cacheable data (exported for client-api.ts)
export type CacheableData = SystemStatus | Poller[];
