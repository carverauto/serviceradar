// src/app/page.tsx
import { Suspense } from 'react';
import Dashboard from '../components/Dashboard';

async function fetchStatus() {
    try {
        // When running on the server, use the full backend URL
        const backendUrl = process.env.NEXT_PUBLIC_BACKEND_URL;
        const apiKey = process.env.API_KEY || '';

        const response = await fetch(`${backendUrl}/api/status`, {
            headers: {
                'X-API-Key': apiKey
            }
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

export default async function HomePage() {
    const initialData = await fetchStatus();

    return (
        <div>
            <h1 className="text-2xl font-bold mb-6">Dashboard</h1>
            <Suspense fallback={<div>Loading dashboard...</div>}>
                <Dashboard initialData={initialData} />
            </Suspense>
        </div>
    );
}