// src/app/nodes/page.js
import { Suspense } from 'react';
import NodeList from '../../components/NodeList';

// Async function to fetch data on the server with API key authentication
async function fetchNodes() {
    try {
        // When running on the server, use the full backend URL
        const backendUrl = process.env.NEXT_PUBLIC_BACKEND_URL;
        const apiKey = process.env.API_KEY;

        const response = await fetch(`${backendUrl}/api/nodes`, {
            headers: {
                'X-API-Key': apiKey
            },
            cache: 'no-store' // Don't cache this request
        });

        if (!response.ok) {
            console.error('Nodes API fetch failed:', {
                status: response.status,
                statusText: response.statusText
            });

            throw new Error(`Nodes API request failed: ${response.status}`);
        }

        return await response.json();
    } catch (error) {
        console.error('Error fetching nodes:', error);
        return [];
    }
}

export default async function NodesPage() {
    const initialNodes = await fetchNodes();

    console.log("NodesPage rendered with initialNodes length:", initialNodes.length);

    return (
        <div>
            <Suspense fallback={<div className="flex justify-center items-center h-64">
                <div className="text-lg text-gray-600 dark:text-gray-300">Loading nodes...</div>
            </div>}>
                <NodeList initialNodes={initialNodes} />
            </Suspense>
        </div>
    );
}