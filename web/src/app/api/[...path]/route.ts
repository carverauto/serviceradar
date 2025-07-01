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

// Catch-all API route to proxy requests to the backend with proper authentication
import { NextRequest, NextResponse } from 'next/server';

const apiUrl = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:8090';
const apiKey = process.env.API_KEY || '';

async function handler(req: NextRequest, { params }: { params: Promise<{ path: string[] }> }) {
    const resolvedParams = await params;
    // Each segment of the path from a catch-all route must be encoded individually.
    const path = resolvedParams.path.map(segment => encodeURIComponent(segment)).join('/');
    const url = new URL(req.url);
    const queryString = url.search;
    
    // Get authentication headers from the incoming request
    const authHeader = req.headers.get('authorization');
    const xApiKey = req.headers.get('x-api-key');
    
    const headers: HeadersInit = {
        'Content-Type': 'application/json',
    };
    
    // Forward authentication headers
    if (authHeader) {
        headers['Authorization'] = authHeader;
    }
    if (xApiKey) {
        headers['X-API-Key'] = xApiKey;
    } else if (apiKey) {
        // Fallback to environment variable API key if not provided
        headers['X-API-Key'] = apiKey;
    }
    
    const backendUrl = `${apiUrl}/api/${path}${queryString}`;
    
    try {
        const response = await fetch(backendUrl, {
            method: req.method,
            headers,
            body: req.body ? await req.text() : undefined,
            cache: 'no-store',
        });
        
        const data = await response.text();
        
        return new NextResponse(data, {
            status: response.status,
            headers: {
                'Content-Type': response.headers.get('content-type') || 'application/json',
            },
        });
    } catch (error) {
        console.error(`Error proxying request:`, error);
        return NextResponse.json(
            { error: 'Internal server error', details: error },
            { status: 500 }
        );
    }
}

export async function GET(req: NextRequest, context: { params: Promise<{ path: string[] }> }) {
    return handler(req, context);
}

export async function POST(req: NextRequest, context: { params: Promise<{ path: string[] }> }) {
    return handler(req, context);
}

export async function PUT(req: NextRequest, context: { params: Promise<{ path: string[] }> }) {
    return handler(req, context);
}

export async function DELETE(req: NextRequest, context: { params: Promise<{ path: string[] }> }) {
    return handler(req, context);
}

export async function PATCH(req: NextRequest, context: { params: Promise<{ path: string[] }> }) {
    return handler(req, context);
}