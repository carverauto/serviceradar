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

// src/lib/client-api.ts - client-side utilities with caching and TypeScript
"use client";

import { useState, useEffect, useRef } from "react";
import { SystemStatus } from "@/types/types";
import { CacheableData } from "./api"; // Import from server-side api.ts

// Cache store
const apiCache = new Map<string, { data: CacheableData; timestamp: number }>();
const pendingRequests = new Map<string, Promise<CacheableData>>();

// Cache expiration time (in milliseconds)
const CACHE_EXPIRY = 5000; // 5 seconds

/**
 * Client-side fetching with caching
 */
export function useAPIData(
  endpoint: string,
  initialData: SystemStatus | null,
  token?: string,
  refreshInterval = 10000,
) {
  const [data, setData] = useState<SystemStatus | null>(initialData);
  const [error, setError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(!initialData);

  // To track if the component is still mounted
  const isMounted = useRef(true);

  useEffect(() => {
    isMounted.current = true;
    return () => {
      isMounted.current = false;
    };
  }, []);

  useEffect(() => {
    // const apiUrl = endpoint.startsWith('/api/') ? endpoint : `/api/${endpoint}`;
    const apiUrl = endpoint.startsWith("http")
      ? endpoint
      : `${process.env.NEXT_PUBLIC_API_URL || "http://localhost:8090"}${endpoint}`;
    let intervalId: NodeJS.Timeout;

    const fetchData = async () => {
      if (!isMounted.current) return;

      try {
        setIsLoading(true);
        const result = await fetchWithCache(apiUrl, {
          headers: token ? { Authorization: `Bearer ${token}` } : {},
        });

        if (isMounted.current) {
          // Type assertion since useAPIData is specifically for SystemStatus
          setData(result as SystemStatus);
          setIsLoading(false);
        }
      } catch (err) {
        if (isMounted.current) {
          console.error(`Error fetching ${apiUrl}:`, err);
          setError((err as Error).message);
          setIsLoading(false);
        }
      }
    };

    // Initial fetch
    fetchData();

    // Set up polling
    if (refreshInterval) {
      intervalId = setInterval(fetchData, refreshInterval);
    }

    return () => {
      if (intervalId) clearInterval(intervalId);
    };
  }, [endpoint, refreshInterval, token]);

  return { data, error, isLoading };
}

/**
 * Fetch with caching and request deduplication
 */
export async function fetchWithCache(
  endpoint: string,
  options: RequestInit = {},
): Promise<SystemStatus> {
  const apiUrl = endpoint.startsWith("/api/") ? endpoint : `/api/${endpoint}`;
  const cacheKey = `${apiUrl}-${JSON.stringify(options)}`;

  // Check if we have a cached response that's still valid
  const cachedData = apiCache.get(cacheKey);
  if (cachedData && cachedData.timestamp > Date.now() - CACHE_EXPIRY) {
    return cachedData.data as SystemStatus; // Type assertion for specific use case
  }

  // Check if we already have a pending request for this URL
  if (pendingRequests.has(cacheKey)) {
    return pendingRequests.get(cacheKey)! as Promise<SystemStatus>;
  }

  // Create a new request and store it
  const fetchPromise = fetchAPI(apiUrl, options)
    .then((data) => {
      // Store in cache
      apiCache.set(cacheKey, {
        data,
        timestamp: Date.now(),
      });
      // Remove from pending requests
      pendingRequests.delete(cacheKey);
      return data;
    })
    .catch((error) => {
      // Remove from pending requests on error
      pendingRequests.delete(cacheKey);
      throw error;
    });

  // Store the pending request
  pendingRequests.set(cacheKey, fetchPromise as Promise<CacheableData>);

  return fetchPromise;
}

/**
 * Simple fetch with API key and optional token
 */
export async function fetchAPI(
  endpoint: string,
  customOptions: RequestInit = {},
): Promise<any> {
  const apiUrl = endpoint.startsWith("/api/") ? endpoint : `/api/${endpoint}`;

  const defaultOptions: RequestInit = {
    headers: {
      "Content-Type": "application/json",
    },
    cache: "no-store" as RequestCache,
  };

  const options: RequestInit = {
    ...defaultOptions,
    ...customOptions,
    headers: {
      ...defaultOptions.headers,
      ...(customOptions.headers || {}),
    },
  };

  const response = await fetch(apiUrl, options);

  if (!response.ok) {
    const errorText = await response.text();
    console.error(
      `API request failed: ${response.status} - ${errorText} for ${apiUrl}`,
    );
    throw new Error(`API request failed: ${response.status} - ${errorText}`);
  }

  return response.json();
}
