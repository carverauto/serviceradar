// web/src/middleware.ts
import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';
import { env } from 'next-runtime-env';

export async function middleware(request: NextRequest) {
    const apiKey = env('API_KEY') || '';
    const isAuthEnabled = env('AUTH_ENABLED') === 'true';

    console.log("Middleware triggered for:", request.method, request.nextUrl.pathname);
    console.log("AUTH_ENABLED:", isAuthEnabled, "API_KEY:", apiKey);

    // Handle OPTIONS preflight
    if (request.method === 'OPTIONS') {
        return new NextResponse(null, {
            status: 200,
            headers: {
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
                'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-API-Key',
            },
        });
    }

    // Public paths and static assets
    const publicPaths = ['/login', '/auth', '/serviceRadar.svg', '/favicons'];
    if (publicPaths.some(path => request.nextUrl.pathname.startsWith(path))) {
        const requestHeaders = new Headers(request.headers);
        if (apiKey && !isAuthEnabled) {
            requestHeaders.set('X-API-Key', apiKey);
        }
        return NextResponse.next({ request: { headers: requestHeaders } });
    }

    const requestHeaders = new Headers(request.headers);
    const token = request.cookies.get('accessToken')?.value ||
        request.headers.get('Authorization')?.replace('Bearer ', '');

    if (isAuthEnabled) {
        if (!token) {
            console.log("No token found, redirecting to /login");
            return NextResponse.redirect(new URL('/login', request.url));
        }
        requestHeaders.set('Authorization', `Bearer ${token}`);
    } else if (apiKey) {
        requestHeaders.set('X-API-Key', apiKey);
    }

    console.log("Headers being sent to backend:");
    requestHeaders.forEach((value, key) => console.log(`${key}: ${value}`));

    return NextResponse.next({
        request: { headers: requestHeaders },
    });
}

export const config = {
    matcher: ['/((?!_next/static|_next/image).*)'], // Exclude _next/static and _next/image
};