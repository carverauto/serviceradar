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

// src/middleware.ts
import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';
import { env } from 'next-runtime-env';

export function middleware(request: NextRequest) {
    // Only apply to api routes
    if (request.nextUrl.pathname.startsWith('/api/')) {
        // Get API key using next-runtime-env
        const apiKey = env('API_KEY') || '';

        // Clone the request headers
        const requestHeaders = new Headers(request.headers);

        // Add the API key header
        requestHeaders.set('X-API-Key', apiKey);

        console.log(`[Middleware] Adding API key to request: ${request.nextUrl.pathname}`);

        // Return a new response with the API key header
        return NextResponse.next({
            request: {
                headers: requestHeaders,
            },
        });
    }

    return NextResponse.next();
}

export const config = {
    matcher: '/api/:path*',
};