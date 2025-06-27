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


// This function is updated to be more flexible with caching.
// It now accepts NextFetchRequestConfig to control caching behavior.
// By default, it will not cache (revalidate: 0), preserving behavior for
// parts of the app that haven't been updated to the new caching strategy.
export async function fetchFromAPI<T>(
    endpoint: string,
    token?: string,
    nextFetchOptions?: NextFetchRequestConfig,
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
  const apiKey = env('API_KEY'); // Use next-runtime-env for consistency
  if (apiKey) {
    headers["X-API-Key"] = apiKey;
  }
  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }

  try {
    const response = await fetch(apiUrl, {
      headers,
      // Use provided next.js fetch options, or default to no caching.
      next: nextFetchOptions || { revalidate: 0 },
      credentials: "include",
    });

    if (!response.ok) {
        let errorBody;
        try {
            errorBody = await response.json();
        } catch {
            errorBody = await response.text();
        }
        console.error(`API request to ${apiUrl} failed with status ${response.status}:`, errorBody);
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
