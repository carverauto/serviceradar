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

// src/lib/api.ts - server-side utilities with TypeScript
import { env } from 'next-runtime-env';
import { SystemStatus, Node } from '@/types';

// Server-side fetching for Next.js server components with generic return type
export async function fetchFromAPI<T>(endpoint: string, token?: string): Promise<T | null> {
    const apiKey = env('API_KEY') || '';
    const baseUrl = env('NEXT_PUBLIC_API_URL') || 'http://localhost:8090';
    const apiUrl = endpoint.startsWith('/api/') ? endpoint : `/api/${endpoint}`;
    const url = new URL(apiUrl, baseUrl).toString();

    const headers: HeadersInit = {};
    if (apiKey) {
        headers['X-API-Key'] = apiKey;
    }
    if (token) {
        headers['Authorization'] = `Bearer ${token}`;
    }

    try {
        const response = await fetch(url, {
            headers,
            cache: 'no-store',
        });

        if (!response.ok) {
            throw new Error(`API request failed: ${response.status}`);
        }

        return response.json();
    } catch (error) {
        console.error('Error fetching from API:', error);
        return null;
    }
}

// Union type for cacheable data (exported for client-api.ts)
export type CacheableData = SystemStatus | Node[];