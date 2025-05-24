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


// Update in src/middleware.ts
export async function middleware(request: NextRequest) {
  const apiKey = env("API_KEY") || "";
  const isAuthEnabled = env("AUTH_ENABLED") === "true";

  // Handle OPTIONS preflight
  if (request.method === "OPTIONS") {
    return new NextResponse(null, {
      status: 200,
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
        "Access-Control-Allow-Headers":
            "Content-Type, Authorization, X-API-Key",
      },
    });
  }

  // Define public paths that don't need authentication
  const publicPaths = [
    "/login",
    "/auth",
    "/serviceRadar.svg",
    "/favicons",
    "/_next",  // Add Next.js assets path
    "/api/auth" // Add authentication API routes
  ];

  // Check if this is a public path
  const isPublicPath = publicPaths.some(path =>
      request.nextUrl.pathname.startsWith(path)
  );

  // Also consider API paths as special case
  const isApiPath = request.nextUrl.pathname.startsWith("/api/");

  // If public path, simply pass through with API key if needed
  if (isPublicPath) {
    const requestHeaders = new Headers(request.headers);
    if (apiKey && !isAuthEnabled) {
      requestHeaders.set("X-API-Key", apiKey);
    }
    return NextResponse.next({ request: { headers: requestHeaders } });
  }

  // For API paths, always include the API key
  if (isApiPath) {
    const requestHeaders = new Headers(request.headers);
    if (apiKey) {
      requestHeaders.set("X-API-Key", apiKey);
    }

    // Forward the auth token if present
    const token = request.cookies.get("accessToken")?.value;
    if (token) {
      requestHeaders.set("Authorization", `Bearer ${token}`);
    } else if (isAuthEnabled) {
      // If auth is enabled and no token for API, return 401
      return NextResponse.json(
          { error: "Authentication required" },
          { status: 401 }
      );
    }

    return NextResponse.next({ request: { headers: requestHeaders } });
  }

  // For all other paths, require authentication if enabled
  const requestHeaders = new Headers(request.headers);
  const token = request.cookies.get("accessToken")?.value;

  if (isAuthEnabled) {
    if (!token) {
      // Redirect to login for non-API routes without a token
      return NextResponse.redirect(new URL("/login", request.url));
    }
    requestHeaders.set("Authorization", `Bearer ${token}`);
  } else if (apiKey) {
    // If auth is disabled, use API key
    requestHeaders.set("X-API-Key", apiKey);
  }

  return NextResponse.next({
    request: { headers: requestHeaders },
  });
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};