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

        // Create metrics lookup object
        const serviceMetrics = {};

        // Fetch metrics for each node with ICMP services
        for (const node of nodes) {
            const icmpServices = node.services?.filter(s => s.type === 'icmp') || [];

            if (icmpServices.length > 0) {

                // Fetch all metrics for this node (one fetch per node is more efficient)
                try {
                    const metricsResponse = await fetch(`${backendUrl}/api/nodes/${node.node_id}/metrics`, {
                        headers: { 'X-API-Key': apiKey },
                        cache: 'no-store',
                    });

                    if (!metricsResponse.ok) {
                        continue;
                    }

                    const allNodeMetrics = await metricsResponse.json();

                    // Filter and organize metrics for each ICMP service
                    for (const service of icmpServices) {
                        const serviceMetricsData = allNodeMetrics.filter(m => m.service_name === service.name);
                        const key = `${node.node_id}-${service.name}`;
                        serviceMetrics[key] = serviceMetricsData;
                    }
                } catch (error) {
                    console.error(`Error fetching metrics for ${node.node_id}:`, error);
                }
            }
        }

        return { nodes, serviceMetrics };
    } catch (error) {
        return { nodes: [], serviceMetrics: {} };
    }
}

export default async function NodesPage() {
    // Fetch all required data from the server
    const { nodes, serviceMetrics } = await fetchNodesWithMetrics();

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