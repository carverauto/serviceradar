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

// src/app/service/[pollerid]/dusk/page.js
import { Suspense } from 'react';
import DuskDashboard from '@/components/Checkers/DuskDashboard';

export const revalidate = 0;

async function fetchDuskData(pollerId) {
    try {
        const backendUrl = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:8090';
        const apiKey = process.env.API_KEY || '';

        // Fetch poller info
        const pollersResponse = await fetch(`${backendUrl}/api/pollers`, {
            headers: { 'X-API-Key': apiKey },
            cache: 'no-store',
        });

        if (!pollersResponse.ok) {
            throw new Error(`Pollers API request failed: ${pollersResponse.status}`);
        }

        const pollers = await pollersResponse.json();

        const poller = pollers.find((n) => n.poller_id === pollerId);

        if (!poller) return { error: 'Poller not found' };

        const duskService = poller.services?.find((s) => s.name === 'dusk');
        if (!duskService) return { error: 'Dusk service not found on this poller' };

        // Get any additional metrics if needed
        let metrics = [];
        try {
            const metricsResponse = await fetch(`${backendUrl}/api/pollers/${pollerId}/metrics`, {
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

        return { duskService, metrics };
    } catch (err) {
        console.error('Error fetching data:', err);
        return { error: err.message };
    }
}

export async function generateMetadata(props) {
    const params = await props.params;
    // Properly await the params object
    const pollerid = params.pollerid;
    return {
        title: `Dusk Monitor - ${pollerid} - ServiceRadar`,
    };
}

export default async function DuskPage(props) {
    const params = await props.params;
    const pollerid = params.pollerid;
    const initialData = await fetchDuskData(pollerid);

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
                    pollerId={pollerid}
                    initialDuskService={initialData.duskService}
                    initialMetrics={initialData.metrics || []}
                    initialError={initialData.error}
                />
            </Suspense>
        </div>
    );
}