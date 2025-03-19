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

// web/src/lib/api.ts - server-side utilities with TypeScript
import { SystemStatus, Node } from '@/types';

export async function fetchFromAPI<T>(endpoint: string, token?: string): Promise<T | null> {
    const baseUrl = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:8090';
    const normalizedEndpoint = endpoint.replace(/^\/+/, ''); // Remove leading slashes
    const apiUrl = normalizedEndpoint.startsWith('auth/') || normalizedEndpoint.startsWith('api/')
        ? `${baseUrl}/${normalizedEndpoint}`
        : `${baseUrl}/api/${normalizedEndpoint}`;

    const headers: HeadersInit = { 'Content-Type': 'application/json' };
    if (token) headers['Authorization'] = `Bearer ${token}`;

    try {
        console.log(`Fetching from: ${apiUrl}`);
        const response = await fetch(apiUrl, {
            headers,
            cache: 'no-store',
            credentials: 'include', // Include cookies for auth
        });

        if (!response.ok) {
            console.error(`API request failed: ${response.status} - ${await response.text()}`);
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