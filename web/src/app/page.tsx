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

// src/app/page.tsx (server-side)
import { Suspense } from 'react';
import DashboardWrapper from '@/components/DashboardWrapper';
import { fetchFromAPI } from '@/lib/api';
import { SystemStatus, ServiceDetails, Service, Node } from '@/types';
import { unstable_noStore as noStore } from 'next/cache';

async function fetchStatus(token?: string): Promise<SystemStatus | null> {
    noStore();

    try {
        const statusData = await fetchFromAPI<SystemStatus>('/status', token);
        if (!statusData) throw new Error('Failed to fetch status');

        const nodesData = await fetchFromAPI<Node[]>('/nodes', token);
        if (!nodesData) throw new Error('Failed to fetch nodes');

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

                    if (service.type === 'icmp' && service.details) {
                        try {
                            const details = typeof service.details === 'string'
                                ? JSON.parse(service.details)
                                : service.details as ServiceDetails;

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

        const avgResponseTime = servicesWithResponseTime > 0
            ? totalResponseTime / servicesWithResponseTime
            : 0;

        return {
            ...statusData,
            service_stats: {
                total_services: totalServices,
                offline_services: offlineServices,
                avg_response_time: avgResponseTime,
            },
        };
    } catch (error) {
        console.error('Error fetching status:', error);
        return null;
    }
}

export default async function HomePage() {
    // Fetch initial data server-side without token (rely on middleware for API key)
    const initialData: SystemStatus | null = await fetchStatus();

    return (
        <div>
            <h1 className="text-2xl font-bold mb-6">Dashboard</h1>
            <Suspense fallback={<div>Loading dashboard...</div>}>
                <DashboardWrapper initialData={initialData} />
            </Suspense>
        </div>
    );
}