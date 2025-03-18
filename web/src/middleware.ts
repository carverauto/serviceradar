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

export async function middleware(request: NextRequest) {
    const isAuthEnabled = env('AUTH_ENABLED') === 'true';
    const apiKey = env('API_KEY') || '';

    // Clone the request headers
    const requestHeaders = new Headers(request.headers);
    requestHeaders.set('X-API-Key', apiKey);

    // Handle public paths (no auth required)
    const publicPaths = ['/login', '/auth'];
    if (publicPaths.some(path => request.nextUrl.pathname.startsWith(path))) {
        return NextResponse.next({
            request: { headers: requestHeaders },
        });
    }

    // If auth is enabled, check for token
    if (isAuthEnabled) {
        const token = request.headers.get('Authorization')?.replace('Bearer ', '');
        if (!token && !request.nextUrl.pathname.startsWith('/login')) {
            return NextResponse.redirect(new URL('/login', request.url));
        }

        if (token) {
            try {
                const response = await fetch(`${process.env.NEXT_PUBLIC_API_URL}/api/status`, {
                    headers: {
                        'Authorization': `Bearer ${token}`,
                        'X-API-Key': apiKey,
                    },
                });

                if (!response.ok) {
                    return NextResponse.redirect(new URL('/login', request.url));
                }
            } catch (error) {
                console.error('Token verification failed:', error);
                return NextResponse.redirect(new URL('/login', request.url));
            }
        }
    }

    // Proceed with the request, ensuring API key is always included
    return NextResponse.next({
        request: { headers: requestHeaders },
    });
}

export const config = {
    matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'],
};