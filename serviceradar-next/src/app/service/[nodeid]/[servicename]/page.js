import { Suspense } from 'react';
import ServiceDashboard from '../../../../components/ServiceDashboard';

export const revalidate = 10; // Revalidate this page every 10 seconds

// Async function to fetch data on the server
async function fetchServiceData(nodeId, serviceName) {
    try {
        // When running on the server, use the full backend URL
        const backendUrl = process.env.NEXT_PUBLIC_BACKEND_URL || 'http://localhost:8090';

        // Fetch nodes list
        const nodesResponse = await fetch(`${backendUrl}/api/nodes`);
        if (!nodesResponse.ok) {
            throw new Error(`Nodes API request failed: ${nodesResponse.status}`);
        }
        const nodes = await nodesResponse.json();

        // Find the specific node
        const node = nodes.find((n) => n.node_id === nodeId);
        if (!node) {
            return { error: 'Node not found' };
        }

        // Find the specific service
        const service = node.services?.find((s) => s.name === serviceName);
        if (!service) {
            return { error: 'Service not found' };
        }

        // Fetch metrics data
        try {
            const metricsResponse = await fetch(`${backendUrl}/api/nodes/${nodeId}/metrics`);
            if (!metricsResponse.ok) {
                throw new Error(`Metrics API request failed: ${metricsResponse.status}`);
            }

            const metrics = await metricsResponse.json();
            const serviceMetrics = metrics.filter(
                (m) => m.service_name === serviceName
            );

            return { service, metrics: serviceMetrics };
        } catch (metricsError) {
            console.error('Error fetching metrics data:', metricsError);
            // Don't fail the whole request if metrics fail
            return { service, metrics: [] };
        }
    } catch (err) {
        console.error('Error fetching data:', err);
        return { error: err.message };
    }
}

export default async function ServicePage({ params }) {
    const { nodeId, serviceName } = params;
    const initialData = await fetchServiceData(nodeId, serviceName);

    return (
        <div>
            <Suspense fallback={<div>Loading service data...</div>}>
                <ServiceDashboard
                    nodeId={nodeId}
                    serviceName={serviceName}
                    initialService={initialData.service}
                    initialMetrics={initialData.metrics}
                    initialError={initialData.error}
                />
            </Suspense>
        </div>
    );
}