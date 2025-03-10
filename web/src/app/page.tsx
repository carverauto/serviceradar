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

// src/app/page.tsx (Server Component)
import { Suspense } from 'react';
import Dashboard from '../components/Dashboard';

interface ServiceDetails {
    response_time?: number;
    packet_loss?: number;
    available?: boolean;
    round_trip?: number;
    [key: string]: unknown;
}

interface Service {
    name: string;
    type: string;
    available: boolean;
    details?: ServiceDetails | string;
}

interface Node {
    node_id: string;
    is_healthy: boolean;
    last_update: string;
    services?: Service[];
}

// This runs only on the server
async function fetchStatus() {
    try {
        // Direct server-to-server call with API key
        const backendUrl = process.env.NEXT_PUBLIC_BACKEND_URL || 'http://localhost:8090';
        const apiKey = process.env.API_KEY || '';

        console.log(`Fetching ${backendUrl} ...`);
        console.log(`API Key: ${apiKey}`);

        // Fetch basic status
        const response = await fetch(`${backendUrl}/api/status`, {
            headers: {
                'X-API-Key': apiKey
            },
            cache: 'no-store' // For fresh data on each request
        });

        if (!response.ok) {
            throw new Error(`Status API request failed: ${response.status}`);
        }

        const statusData = await response.json();

        // Fetch all nodes to calculate service stats
        const nodesResponse = await fetch(`${backendUrl}/api/nodes`, {
            headers: {
                'X-API-Key': apiKey
            },
            cache: 'no-store'
        });

        if (!nodesResponse.ok) {
            throw new Error(`Nodes API request failed: ${nodesResponse.status}`);
        }

        const nodesData: Node[] = await nodesResponse.json();

        // Calculate service statistics
        let totalServices = 0;
        let offlineServices = 0;
        let totalResponseTime = 0;
        let servicesWithResponseTime = 0;

        nodesData.forEach((node: Node) => {
            if (node.services && Array.isArray(node.services)) {
                totalServices += node.services.length;

                node.services.forEach((service: Service) => {
                    if (!service.available) {
                        offlineServices++;
                    }

                    // For ICMP services, collect response time data
                    if (service.type === 'icmp' && service.details) {
                        try {
                            const details = typeof service.details === 'string'
                                ? JSON.parse(service.details)
                                : service.details;

                            if (details && details.response_time) {
                                totalResponseTime += details.response_time;
                                servicesWithResponseTime++;
                            }
                        } catch (e) {
                            console.error('Error parsing service details:', e);
                        }
                    }
                });
            }
        });

        // Calculate average response time
        const avgResponseTime = servicesWithResponseTime > 0
            ? totalResponseTime / servicesWithResponseTime
            : 0;

        // Add service stats to the data
        return {
            ...statusData,
            service_stats: {
                total_services: totalServices,
                offline_services: offlineServices,
                avg_response_time: avgResponseTime
            }
        };
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