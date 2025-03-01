// Server component that fetches data
import {Suspense} from "react";
import NodeList from "../../components/NodeList";

// Disable static generation, always fetch latest data
export const revalidate = 0;

// Server component that fetches all data needed
async function fetchNodesWithMetrics() {
    try {
        const backendUrl = process.env.NEXT_PUBLIC_BACKEND_URL || 'http://localhost:8090';
        const apiKey = process.env.API_KEY || '';

        // Fetch all nodes first
        const nodesResponse = await fetch(`${backendUrl}/api/nodes`, {
            headers: { 'X-API-Key': apiKey },
            cache: 'no-store', // Prevent caching
        });

        if (!nodesResponse.ok) {
            throw new Error(`Nodes API request failed: ${nodesResponse.status}`);
        }

        const nodes = await nodesResponse.json();
        console.log(`Fetched ${nodes.length} nodes`);

        // Create metrics lookup object
        const serviceMetrics = {};

        // Fetch metrics for each node with ICMP services
        for (const node of nodes) {
            const icmpServices = node.services?.filter(s => s.type === 'icmp') || [];

            if (icmpServices.length > 0) {
                console.log(`Node ${node.node_id} has ${icmpServices.length} ICMP services`);

                // Fetch all metrics for this node (one fetch per node is more efficient)
                try {
                    const metricsResponse = await fetch(`${backendUrl}/api/nodes/${node.node_id}/metrics`, {
                        headers: { 'X-API-Key': apiKey },
                        cache: 'no-store',
                    });

                    if (!metricsResponse.ok) {
                        console.error(`Metrics API failed for ${node.node_id}: ${metricsResponse.status}`);
                        continue;
                    }

                    const allNodeMetrics = await metricsResponse.json();
                    console.log(`Received ${allNodeMetrics.length} metrics for ${node.node_id}`);

                    // Filter and organize metrics for each ICMP service
                    for (const service of icmpServices) {
                        const serviceMetricsData = allNodeMetrics.filter(m => m.service_name === service.name);
                        const key = `${node.node_id}-${service.name}`;
                        serviceMetrics[key] = serviceMetricsData;
                        console.log(`${key}: Filtered ${serviceMetricsData.length} metrics`);
                    }
                } catch (error) {
                    console.error(`Error fetching metrics for ${node.node_id}:`, error);
                }
            }
        }

        return { nodes, serviceMetrics };
    } catch (error) {
        console.error('Error fetching nodes data:', error);
        return { nodes: [], serviceMetrics: {} };
    }
}

export default async function NodesPage() {
    // Fetch all required data from the server
    const { nodes, serviceMetrics } = await fetchNodesWithMetrics();

    // Log the metrics data for debugging
    console.log(`Fetched ${Object.keys(serviceMetrics).length} service metric sets`);

    return (
        <div>
            <Suspense fallback={
                <div className="flex justify-center items-center h-64">
                    <div className="text-lg text-gray-600 dark:text-gray-300">Loading nodes...</div>
                </div>
            }>
                <NodeList initialNodes={nodes} serviceMetrics={serviceMetrics} />
            </Suspense>
        </div>
    );
}