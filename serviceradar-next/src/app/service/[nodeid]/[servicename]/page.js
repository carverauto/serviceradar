// src/app/service/[nodeid]/[servicename]/page.js
import { Suspense } from 'react';
import ServiceDashboard from '../../../../components/ServiceDashboard';

export const revalidate = 30; // Increase revalidation time from 10 to 30 seconds

// Async function to fetch data on the server with API key authentication
async function fetchServiceData(nodeId, serviceName) {
    try {
        // When running on the server, use the full backend URL
        const backendUrl = process.env.NEXT_PUBLIC_BACKEND_URL;
        const apiKey = process.env.API_KEY;

        // Fetch nodes list
        const nodesResponse = await fetch(`${backendUrl}/api/nodes`, {
            headers: {
                'X-API-Key': apiKey
            },
            next: { revalidate: 30 } // Cache for 30 seconds
        });

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
            const metricsResponse = await fetch(`${backendUrl}/api/nodes/${nodeId}/metrics`, {
                headers: {
                    'X-API-Key': apiKey
                },
                next: { revalidate: 30 } // Cache for 30 seconds
            });

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

// Generate dynamic metadata for the page
export async function generateMetadata(props) {
    // Next.js now requires us to await the params object
    const params = await props.params;

    // Now we can safely destructure
    const nodeid = params.nodeid;
    const servicename = params.servicename;

    return {
        title: `${servicename} on ${nodeid} - ServiceRadar`,
    };
}

export default async function Page(props) {
    // Access params using the props object
    const params = props.params;

    // Now use the params after they're fully resolved
    const nodeid = params.nodeid;
    const servicename = params.servicename;

    // Fetch data
    const initialData = await fetchServiceData(nodeid, servicename);

    return (
        <div>
            <Suspense fallback={<div className="flex justify-center items-center h-64">
                <div className="text-lg text-gray-600 dark:text-gray-300">Loading service data...</div>
            </div>}>
                <ServiceDashboard
                    nodeId={nodeid}
                    serviceName={servicename}
                    initialService={initialData.service}
                    initialMetrics={initialData.metrics}
                    initialError={initialData.error}
                />
            </Suspense>
        </div>
    );
}