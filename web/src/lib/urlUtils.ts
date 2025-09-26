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

// src/lib/urlUtils.ts
export function getApiUrl(endpoint: string, isServerSide = typeof window === 'undefined'): string {
    // Normalize the endpoint
    const normalizedEndpoint = endpoint.replace(/^\/+/, "");

    if (isServerSide) {
        // Server-side context - need absolute URL and correct upstream host
        const rawBaseUrl =
            process.env.NEXT_INTERNAL_API_URL ||
            process.env.NEXT_PUBLIC_API_URL ||
            'http://localhost:8090';

        const baseUrl = normalizeBaseUrl(rawBaseUrl);

        return `${baseUrl}/api/${normalizedEndpoint}`;
    } else {
        // Client-side context - use relative URL
        return `/api/${normalizedEndpoint}`;
    }
}

function normalizeBaseUrl(url: string): string {
    const withProtocol = url.startsWith('http') ? url : `http://${url}`;
    const withoutTrailingSlash = withProtocol.replace(/\/+$/, '');
    return withoutTrailingSlash.replace(/\/api$/, '');
}
