import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';

// The API key should be accessible through server runtime config
const API_KEY = process.env.API_KEY || '';

export async function middleware(request: NextRequest) {
    console.log("Middleware triggered for:", request.method, request.nextUrl.pathname);

    // Handle OPTIONS preflight requests
    if (request.method === 'OPTIONS') {
        return new NextResponse(null, {
            status: 200,
            headers: {
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Methods': 'GET,POST,PUT,DELETE,OPTIONS',
                'Access-Control-Allow-Headers': 'Content-Type,Authorization,X-API-Key',
            },
        });
    }

    // Clone and modify headers - ALWAYS add API key
    const requestHeaders = new Headers(request.headers);
    requestHeaders.set('X-API-Key', API_KEY);
    console.log("Setting API Key header:", API_KEY ? "Key set (not shown)" : "No key available");

    // Log all headers for debugging (in dev only)
    if (process.env.NODE_ENV === 'development') {
        console.log("Request headers:");
        requestHeaders.forEach((value, key) => {
            if (key !== 'x-api-key') { // Don't log the actual API key
                console.log(`${key}: ${value}`);
            } else {
                console.log("x-api-key: [PRESENT]");
            }
        });
    }

    console.log("Original URL:", request.url);
    console.log("Next URL:", request.nextUrl.href);

    // Forward the request with modified headers
    return NextResponse.next({
        request: { headers: requestHeaders },
    });
}

// Match all routes
export const config = {
    matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'],
};