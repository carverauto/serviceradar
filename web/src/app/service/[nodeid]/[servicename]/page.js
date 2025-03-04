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

// src/app/service/[nodeid]/[servicename]/page.js
import { Suspense } from 'react';
import ServiceDashboard from '../../../../components/ServiceDashboard';

export const revalidate = 0;

async function fetchServiceData(nodeId, serviceName, timeRange = '1h') {
    try {
        const backendUrl = process.env.NEXT_PUBLIC_BACKEND_URL || 'http://localhost:8090';
        const apiKey = process.env.API_KEY || '';

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

        const service = node.services?.find((s) => s.name === serviceName);
        if (!service) return { error: 'Service not found' };

        // Fetch metrics
        let metrics = [];
        try {
            const metricsResponse = await fetch(`${backendUrl}/api/nodes/${nodeId}/metrics`, {
                headers: { 'X-API-Key': apiKey },
                cache: 'no-store',
            });

            if (!metricsResponse.ok) {
                console.error(`Metrics API failed: ${metricsResponse.status}`);
            } else {
                metrics = await metricsResponse.json();
            }
        } catch (metricsError) {
            console.error('Error fetching metrics data:', metricsError);
        }

        const serviceMetrics = metrics.filter((m) => m.service_name === serviceName);

        // Fetch SNMP data if needed
        let snmpData = [];
        if (service.type === 'snmp') {
            try {
                const end = new Date();
                const start = new Date();

                // Adjust start time based on timeRange
                switch (timeRange) {
                    case '1h':
                        start.setHours(end.getHours() - 1);
                        break;
                    case '6h':
                        start.setHours(end.getHours() - 6);
                        break;
                    case '24h':
                        start.setHours(end.getHours() - 24);
                        break;
                    default:
                        start.setHours(end.getHours() - 1);
                }

                const snmpUrl = `${backendUrl}/api/nodes/${nodeId}/snmp?start=${start.toISOString()}&end=${end.toISOString()}`;
                console.log("Fetching SNMP from:", snmpUrl);

                const snmpResponse = await fetch(snmpUrl, {
                    headers: { 'X-API-Key': apiKey },
                    cache: 'no-store',
                });

                if (!snmpResponse.ok) {
                    const errorText = await snmpResponse.text();
                    console.error(`SNMP API failed: ${snmpResponse.status} - ${errorText}`);
                    throw new Error(`SNMP API request failed: ${snmpResponse.status} - ${errorText}`);
                }

                snmpData = await snmpResponse.json();
                console.log("SNMP data fetched:", snmpData.length);
            } catch (snmpError) {
                console.error('Error fetching SNMP data:', snmpError);
            }
        }

        return { service, metrics: serviceMetrics, snmpData, timeRange };
    } catch (err) {
        console.error('Error fetching data:', err);
        return { error: err.message };
    }
}

export async function generateMetadata({ params }) {
    const { nodeid, servicename } = await params;
    return {
        title: `${servicename} on ${nodeid} - ServiceRadar`,
    };
}

export default async function Page({ params, searchParams }) {
    const { nodeid, servicename } = await params;
    const timeRange = searchParams?.timeRange || '1h'; // Get timeRange from query params
    const initialData = await fetchServiceData(nodeid, servicename, timeRange);

    console.log("Page fetched data:", {
        service: !!initialData.service,
        metricsLength: initialData.metrics?.length,
        snmpDataLength: initialData.snmpData?.length,
        error: initialData.error,
        timeRange: initialData.timeRange,
    });

    return (
        <div>
            <Suspense
                fallback={
                    <div className="flex justify-center items-center h-64">
                        <div className="text-lg text-gray-600 dark:text-gray-300">Loading service data...</div>
                    </div>
                }
            >
                <ServiceDashboard
                    nodeId={nodeid}
                    serviceName={servicename}
                    initialService={initialData.service}
                    initialMetrics={initialData.metrics || []}
                    initialSnmpData={initialData.snmpData || []}
                    initialError={initialData.error}
                    initialTimeRange={initialData.timeRange || '1h'}
                />
            </Suspense>
        </div>
    );
}