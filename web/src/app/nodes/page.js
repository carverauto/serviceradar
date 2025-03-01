// src/app/nodes/page.js
import { Suspense } from 'react';
import NodeList from '../../components/NodeList';

// Server component that fetches data
async function fetchNodes() {
    try {
        // When running on the server, use the full backend URL
        const backendUrl = process.env.NEXT_PUBLIC_BACKEND_URL || 'http://localhost:8090';
        const apiKey = process.env.API_KEY || '';

        const response = await fetch(`${backendUrl}/api/nodes`, {
            headers: {
                'X-API-Key': apiKey
            },
            cache: 'no-store', // For real-time data
        });

        if (!response.ok) {
            throw new Error(`Nodes API request failed: ${response.status}`);
        }

        return await response.json();
    } catch (error) {
        console.error('Error fetching nodes:', error);
        return [];
    }
}

// Fetch metrics for a specific node and service
async function fetchMetricsForService(nodeId, serviceName) {
    try {
        const backendUrl = process.env.NEXT_PUBLIC_BACKEND_URL || 'http://localhost:8090';
        const apiKey = process.env.API_KEY || '';

        const response = await fetch(`${backendUrl}/api/nodes/${nodeId}/metrics`, {
            headers: {
                'X-API-Key': apiKey
            },
            cache: 'no-store',
        });

        if (!response.ok) {
            return [];
        }

        const allMetrics = await response.json();
        // Filter the metrics for this specific service
        return allMetrics.filter(m => m.service_name === serviceName);
    } catch (error) {
        console.error(`Error fetching metrics for ${nodeId}/${serviceName}:`, error);
        return [];
    }
}

export default async function NodesPage() {
    // Fetch all nodes first
    const nodes = await fetchNodes();

    // Fetch metrics for ICMP services
    const serviceMetrics = {};

    for (const node of nodes) {
        const icmpServices = node.services?.filter(s => s.type === 'icmp') || [];

        for (const service of icmpServices) {
            const metrics = await fetchMetricsForService(node.node_id, service.name);
            const key = `${node.node_id}-${service.name}`;
            serviceMetrics[key] = metrics;
        }
    }

    return (
        <div>
            <Suspense fallback={<div className="flex justify-center items-center h-64">
                <div className="text-lg text-gray-600 dark:text-gray-300">Loading nodes...</div>
            </div>}>
                <NodeList initialNodes={nodes} serviceMetrics={serviceMetrics} />
            </Suspense>
        </div>
    );
}