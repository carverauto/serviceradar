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

import { env } from "next-runtime-env";

function normalizeBaseUrl(url: string): string {
  const withoutProtocolWhitespace = url.trim();
  const withoutTrailingSlash = withoutProtocolWhitespace.replace(/\/+$/, "");
  return withoutTrailingSlash.replace(/\/api$/, "");
}

/**
 * Configuration helper for ServiceRadar web application
 * Handles both server-side and client-side API URLs
 */

// For server-side API calls (container-to-container communication)
export function getInternalApiUrl(): string {
  if (typeof window === "undefined") {
    // Server-side code path - check internal URL first
    const internalUrl = process.env.NEXT_INTERNAL_API_URL;
    if (internalUrl) {
      // If it contains /api, it's probably a mistake - remove it
      return normalizeBaseUrl(internalUrl);
    }

    // Local development fallback - direct to backend
    return normalizeBaseUrl("http://localhost:8090");
  }

  // Client-side fallback (shouldn't be used for server-side API routes)
  const publicUrl = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8090";
  return normalizeBaseUrl(publicUrl);
}

// For server-side SRQL calls (container-to-container to SRQL service)
export function getInternalSrqlUrl(): string {
  if (typeof window === "undefined") {
    const internalSrqlUrl =
      process.env.NEXT_INTERNAL_SRQL_URL || process.env.NEXT_INTERNAL_API_URL;
    if (internalSrqlUrl) {
      return normalizeBaseUrl(internalSrqlUrl);
    }

    // Fallback for local development
    return normalizeBaseUrl("http://localhost:8080");
  }

  // Client-side fallback (only used when explicitly needed)
  const publicSrqlUrl =
    process.env.NEXT_PUBLIC_SRQL_URL ||
    process.env.NEXT_PUBLIC_API_URL ||
    "http://localhost:8080";
  return normalizeBaseUrl(publicSrqlUrl);
}

// For client-side API calls (browser to API)
export function getPublicApiUrl(): string {
  // Client-side can use either next-runtime-env or process.env
  // Try process.env first for server-side rendering
  if (typeof window === "undefined") {
    return normalizeBaseUrl(process.env.NEXT_PUBLIC_API_URL || "http://localhost:8090");
  }
  // Use next-runtime-env for client-side runtime configuration
  return normalizeBaseUrl(env("NEXT_PUBLIC_API_URL") || "http://localhost:8090");
}

// Get API key for server-side requests
export function getApiKey(): string {
  return process.env.API_KEY || process.env.NEXT_PUBLIC_API_KEY || "";
}

// Get JWT secret for token validation
export function getJwtSecret(): string {
  return process.env.JWT_SECRET || "";
}

// Check if authentication is enabled
export function isAuthEnabled(): boolean {
  return process.env.AUTH_ENABLED === "true";
}

// Configuration object for easy access
export const config = {
  api: {
    internal: getInternalApiUrl(),
    public: getPublicApiUrl(),
    key: getApiKey(),
    srqlInternal: getInternalSrqlUrl(),
  },
  auth: {
    enabled: isAuthEnabled(),
    jwtSecret: getJwtSecret(),
  },
};

// Helper function to determine if we're running in server context
export function isServer(): boolean {
  return typeof window === "undefined";
}

// Get the appropriate API URL based on context
export function getApiUrl(): string {
  return isServer() ? getInternalApiUrl() : getPublicApiUrl();
}

// Force rebuild Fri Aug 15 01:42:01 CDT 2025
