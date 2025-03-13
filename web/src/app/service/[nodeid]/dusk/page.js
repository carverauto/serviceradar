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

// src/app/service/[nodeid]/dusk/page.js
import { Suspense } from 'react';
import DuskDashboard from '../../../../components/DuskDashboard';

export const revalidate = 0;

async function fetchDuskData(nodeId) {
    try {
        const backendUrl = process.env.NEXT_PUBLIC_BACKEND_URL || 'http://localhost:8090';
        const apiKey = process.env.API_KEY || '';

        console.log(`Fetching Dusk data for node ${nodeId}`);

        // Fetch node info
        const nodesResponse = await fetch(`${backendUrl}/api/nodes`, {
            headers: { 'X-API-Key': apiKey },
            cache: 'no-store',
        });

        if (!nodesResponse.ok) {
            throw new Error(`Nodes API request failed: ${nodesResponse.status}`);
        }

        const nodes = await nodesResponse.json();
        const node = nodes.find((n) => n.node_id === nodeId);

        if (!node) return { error: 'Node not found' };

        const duskService = node.services?.find((s) => s.name === 'dusk');
        if (!duskService) return { error: 'Dusk service not found on this node' };

        // Get any additional metrics if needed
        let metrics = [];
        try {
            const metricsResponse = await fetch(`${backendUrl}/api/nodes/${nodeId}/metrics`, {
                headers: { 'X-API-Key': apiKey },
                cache: 'no-store',
            });

            if (metricsResponse.ok) {
                const allMetrics = await metricsResponse.json();
                metrics = allMetrics.filter((m) => m.service_name === 'dusk');
            }
        } catch (metricsError) {
            console.error('Error fetching metrics data:', metricsError);
        }

        console.log(`Successfully fetched Dusk service for node ${nodeId}`);
        return { duskService, metrics };
    } catch (err) {
        console.error('Error fetching data:', err);
        return { error: err.message };
    }
}

export function generateMetadata({ params }) {
    const { nodeid } = params;
    return {
        title: `Dusk Monitor - ${nodeid} - ServiceRadar`,
    };
}

export default async function DuskPage({ params }) {
    const { nodeid } = params;
    const initialData = await fetchDuskData(nodeid);

    return (
        <div>
            <Suspense
                fallback={
                    <div className="flex justify-center items-center h-64">
                        <div className="text-lg text-gray-600 dark:text-gray-300">Loading Dusk data...</div>
                    </div>
                }
            >
                <DuskDashboard
                    nodeId={nodeid}
                    initialDuskService={initialData.duskService}
                    initialMetrics={initialData.metrics || []}
                    initialError={initialData.error}
                />
            </Suspense>
        </div>
    );
}