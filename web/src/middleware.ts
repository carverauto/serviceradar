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