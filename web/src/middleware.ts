// src/middleware.ts
import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';
import { env } from 'next-runtime-env';

export async function middleware(request: NextRequest) {
    const isAuthEnabled = env('AUTH_ENABLED') === 'true';
    const apiKey = env('API_KEY') || '';
    const requestHeaders = new Headers(request.headers);

    // Debug log to verify environment
    console.log('Middleware - AUTH_ENABLED:', isAuthEnabled, 'Path:', request.nextUrl.pathname);

    // Public paths don’t need auth
    const publicPaths = ['/login', '/auth'];
    if (publicPaths.some(path => request.nextUrl.pathname.startsWith(path))) {
        if (apiKey && !isAuthEnabled) {
            requestHeaders.set('X-API-Key', apiKey);
        }
        return NextResponse.next({ request: { headers: requestHeaders } });
    }

    if (isAuthEnabled) {
        // Check for token in cookies or Authorization header
        const token = request.cookies.get('accessToken')?.value ||
            request.headers.get('Authorization')?.replace('Bearer ', '');

        if (!token) {
            console.log('No token found, redirecting to /login');
            return NextResponse.redirect(new URL('/login', request.url));
        }

        // Verify token with backend
        try {
            const response = await fetch(`${process.env.NEXT_PUBLIC_API_URL}/api/status`, {
                headers: {
                    'Authorization': `Bearer ${token}`,
                    // Don’t send API key when AUTH_ENABLED=true
                },
            });

            if (!response.ok) {
                console.log('Token invalid, redirecting to /login');
                return NextResponse.redirect(new URL('/login', request.url));
            }

            requestHeaders.set('Authorization', `Bearer ${token}`);
        } catch (error) {
            console.error('Token verification failed:', error);
            return NextResponse.redirect(new URL('/login', request.url));
        }
    } else {
        // Use API key only when AUTH_ENABLED=false
        if (!apiKey) {
            console.log('No API key provided and AUTH_ENABLED=false, redirecting to /login');
            return NextResponse.redirect(new URL('/login', request.url));
        }
        requestHeaders.set('X-API-Key', apiKey);
    }

    return NextResponse.next({ request: { headers: requestHeaders } });
}

export const config = {
    matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'],
};