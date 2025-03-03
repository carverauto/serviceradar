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

// src/app/page.tsx (Server Component)
import { Suspense } from 'react';
import Dashboard from '../components/Dashboard';

// This runs only on the server
async function fetchStatus() {
    try {
        // Direct server-to-server call with API key
        const backendUrl = process.env.NEXT_PUBLIC_BACKEND_URL || 'http://localhost:8090';
        const apiKey = process.env.API_KEY || '';

        const response = await fetch(`${backendUrl}/api/status`, {
            headers: {
                'X-API-Key': apiKey
            },
            cache: 'no-store' // For fresh data on each request
        });

        if (!response.ok) {
            throw new Error(`Status API request failed: ${response.status}`);
        }

        return await response.json();
    } catch (error) {
        console.error('Error fetching status:', error);
        return null;
    }
}

// Server Component
export default async function HomePage() {
    // Data fetching happens server-side
    const initialData = await fetchStatus();

    return (
        <div>
            <h1 className="text-2xl font-bold mb-6">Dashboard</h1>
            <Suspense fallback={<div>Loading dashboard...</div>}>
                {/* Pass pre-fetched data to client component */}
                <Dashboard initialData={initialData} />
            </Suspense>
        </div>
    );
}