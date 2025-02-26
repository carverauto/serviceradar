import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';

export function middleware(request: NextRequest) {
    const url = request.nextUrl.clone();

    // Only apply to /api/* paths
    if (url.pathname.startsWith('/api/')) {

        const apiKey = process.env.API_KEY || '';

        // Create a new request with added headers
        const modifiedRequest = new Request(url, {
            headers: {
                ...request.headers,
                'X-API-Key': apiKey,
            },
        });

        return NextResponse.rewrite(url, { request: modifiedRequest });
    }

    return NextResponse.next();
}

export const config = {
    matcher: '/api/:path*', // Apply middleware only to /api/* routes
};