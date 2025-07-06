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

// web/src/middleware.ts
import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";
import { env } from "next-runtime-env";

export async function middleware(request: NextRequest) {
  const apiKey = env("API_KEY") || "";
  const isAuthEnabled = env("AUTH_ENABLED") === "true";
  const requestHeaders = new Headers(request.headers);

  // Handle OPTIONS preflight
  if (request.method === "OPTIONS") {
    return new NextResponse(null, {
      status: 200,
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization, X-API-Key",
      },
    });
  }

  // Define public paths that don't need authentication
  const publicPaths = [
    "/login",
    "/auth",
    "/serviceRadar.svg",
    "/favicons",
    "/_next",  // Next.js assets
    "/api/auth" // Authentication API routes
  ];

  // Check if the request path is public
  const isPublicPath = publicPaths.some(path => request.nextUrl.pathname.startsWith(path));
  if (isPublicPath) {
    return NextResponse.next();
  }

  // --- Main Logic for Authenticated Routes ---

  const accessToken = request.cookies.get("accessToken")?.value;
  const requestApiKey = request.headers.get("x-api-key");

  // For API routes, we allow either a bearer token or a valid API key
  if (request.nextUrl.pathname.startsWith("/api/")) {
    // Option 1: Valid Bearer Token (for UI-driven requests)
    if (accessToken) {
      requestHeaders.set("Authorization", `Bearer ${accessToken}`);
      // Also forward the API key for services that might need it internally
      if (apiKey) {
        requestHeaders.set("X-API-Key", apiKey);
      }
      return NextResponse.next({ request: { headers: requestHeaders } });
    }

    // Option 2: Valid API Key (for server-to-server requests like serviceradar-sync)
    if (requestApiKey && requestApiKey === apiKey) {
      // The API key is valid. We let the request through.
      // We also set the X-API-Key header to ensure the backend receives it.
      requestHeaders.set("X-API-Key", requestApiKey);
      return NextResponse.next({ request: { headers: requestHeaders } });
    }

    // If we reach here, it's an API request with no valid credentials.
    // Only return 401 if authentication is globally enabled.
    if (isAuthEnabled) {
      return NextResponse.json({ error: "Authentication required" }, { status: 401 });
    }
  }

  // For all other protected paths (i.e., the web UI pages), we require a bearer token if auth is enabled.
  if (isAuthEnabled) {
    if (!accessToken) {
      // No token, redirect to the login page.
      return NextResponse.redirect(new URL("/login", request.url));
    }
    // Token exists, add it to the request headers for downstream use.
    requestHeaders.set("Authorization", `Bearer ${accessToken}`);
  } else if (apiKey) {
    // If auth is disabled, fall back to using the system-wide API key for non-page requests.
    requestHeaders.set("X-API-Key", apiKey);
  }

  return NextResponse.next({
    request: { headers: requestHeaders },
  });
}

export const config = {
  matcher: [
    /*
     * Match all request paths except for the ones starting with a specific set of prefixes.
     * - _next/static (static files)
     * - _next/image (image optimization files)
     * - favicon.ico (favicon file)
     * - api/auth (authentication routes to prevent auth loops)
     */
    '/((?!api/auth|_next/static|_next/image|favicon.ico).*)',
  ],
};