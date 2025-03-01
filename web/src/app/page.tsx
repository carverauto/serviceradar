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