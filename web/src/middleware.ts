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

  // Public paths and static assets
  const publicPaths = ["/login", "/auth", "/serviceRadar.svg", "/favicons"];
  if (publicPaths.some((path) => request.nextUrl.pathname.startsWith(path))) {
    const requestHeaders = new Headers(request.headers);
    if (apiKey && !isAuthEnabled) {
      requestHeaders.set("X-API-Key", apiKey);
    }
    return NextResponse.next({ request: { headers: requestHeaders } });
  }

  const isPublicPath =
    request.nextUrl.pathname.startsWith("/api/") ||
    request.nextUrl.pathname.startsWith("/auth/") ||
    publicPaths.some((path) => request.nextUrl.pathname.startsWith(path));

  if (isPublicPath) {
    const requestHeaders = new Headers(request.headers);
    if (apiKey) {
      requestHeaders.set("X-API-Key", apiKey);
    }
    return NextResponse.next({ request: { headers: requestHeaders } });
  }

  const requestHeaders = new Headers(request.headers);
  const token =
    request.cookies.get("accessToken")?.value ||
    request.headers.get("Authorization")?.replace("Bearer ", "");

  if (isAuthEnabled) {
    if (!token) {
      return NextResponse.redirect(new URL("/login", request.url));
    }
    requestHeaders.set("Authorization", `Bearer ${token}`);
  } else if (apiKey) {
    requestHeaders.set("X-API-Key", apiKey);
  }

  return NextResponse.next({
    request: { headers: requestHeaders },
  });
}

export const config = {
  matcher: ["/((?!_next/static|_next/image).*)"], // Exclude _next/static and _next/image
};
