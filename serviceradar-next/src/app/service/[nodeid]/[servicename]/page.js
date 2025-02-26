// src/app/service/[nodeid]/[servicename]/page.js
import { Suspense } from 'react';
import ServiceDashboard from '../../../../components/ServiceDashboard';

export const revalidate = 30;

async function fetchServiceData(nodeId, serviceName) {
    try {
        const backendUrl = process.env.NEXT_PUBLIC_BACKEND_URL || 'http://localhost:8090';
        const apiKey = process.env.API_KEY || '';

        const nodesResponse = await fetch(`${backendUrl}/api/nodes`, {
            headers: { 'X-API-Key': apiKey },
            next: { revalidate: 30 },
        });
        if (!nodesResponse.ok) {
            throw new Error(`Nodes API request failed: ${nodesResponse.status}`);
        }
        const nodes = await nodesResponse.json();

        const node = nodes.find((n) => n.node_id === nodeId);
        if (!node) return { error: 'Node not found' };

        const service = node.services?.find((s) => s.name === serviceName);
        if (!service) return { error: 'Service not found' };

        let metrics = [];
        try {
            const metricsResponse = await fetch(`${backendUrl}/api/nodes/${nodeId}/metrics`, {
                headers: { 'X-API-Key': apiKey },
                next: { revalidate: 30 },
            });
            if (!metricsResponse.ok) {
                console.error(`Metrics API failed: ${metricsResponse.status} - ${await metricsResponse.text()}`);
            } else {
                metrics = await metricsResponse.json();
            }
        } catch (metricsError) {
            console.error('Error fetching metrics data:', metricsError);
        }
        const serviceMetrics = metrics.filter((m) => m.service_name === serviceName);

        let snmpData = [];
        if (service.type === 'snmp') {
            try {
                const end = new Date();
                const start = new Date();
                start.setHours(end.getHours() - 1);

                const snmpUrl = `${backendUrl}/api/nodes/${nodeId}/snmp?start=${start.toISOString()}&end=${end.toISOString()}`;
                console.log("Fetching SNMP from:", snmpUrl);

                const snmpResponse = await fetch(snmpUrl, {
                    headers: { 'X-API-Key': apiKey },
                    next: { revalidate: 30 },
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

        return { service, metrics: serviceMetrics, snmpData };
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

export default async function Page({ params }) {
    const { nodeid, servicename } = await params;
    const initialData = await fetchServiceData(nodeid, servicename);

    console.log("Page fetched data:", {
        service: !!initialData.service,
        metricsLength: initialData.metrics?.length,
        snmpDataLength: initialData.snmpData?.length,
        error: initialData.error,
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
                />
            </Suspense>
        </div>
    );
}