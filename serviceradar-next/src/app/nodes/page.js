import { Suspense } from 'react';
import NodeList from '../../components/NodeList';

export const revalidate = 10; // Revalidate this page every 10 seconds

// Async function to fetch data on the server
async function fetchNodes() {
    try {
        // When running on the server, use the full backend URL
        const backendUrl = process.env.NEXT_PUBLIC_BACKEND_URL || 'http://localhost:8090';
        const response = await fetch(`${backendUrl}/api/nodes`);

        if (!response.ok) {
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

    return (
        <div>
            <Suspense fallback={<div>Loading nodes...</div>}>
                <NodeList initialNodes={initialNodes} />
            </Suspense>
        </div>
    );
}