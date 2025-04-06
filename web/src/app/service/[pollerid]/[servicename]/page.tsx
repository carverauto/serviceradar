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

// src/app/service/[pollerid]/[servicename]/page.tsx
import { Suspense } from "react";
import ServiceDashboard from "../../../../components/ServiceDashboard";
import { cookies } from "next/headers";
import { Poller, ServiceMetric } from "@/types/types";
import { SnmpDataPoint } from "@/types/snmp";
import { getApiUrl } from "@/lib/urlUtils";

// Define the params type as a Promise
type Params = Promise<{ pollerid: string; servicename: string }>;

// Define props type
interface PageProps {
    params: Promise<Params>;
    searchParams: Promise<{ timeRange?: string }>;
}

export const revalidate = 0;

async function fetchServiceData(
    pollerId: string,
    serviceName: string,
    timeRange = "1h",
    token?: string,
) {
    try {
        const backendUrl = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8090";
        const apiKey = process.env.API_KEY || "";

        const pollersUrl = getApiUrl("pollers");

        // Use relative URL for the API route
        const pollersResponse = await fetch(pollersUrl, {
            headers: {
                "X-API-Key": apiKey,
                ...(token ? { Authorization: `Bearer ${token}` } : {}),
            },
            cache: "no-store",
        });

        if (!pollersResponse.ok) {
            throw new Error(`Pollers API request failed: ${pollersResponse.status}`);
        }

        const pollers: Poller[] = await pollersResponse.json();
        const poller = pollers.find((n) => n.poller_id === pollerId);

        if (!poller) return { error: "Poller not found", service: null };

        const service = poller.services?.find((s) => s.name === serviceName) || null;
        if (!service) return { error: "Service not found", service: null };

        let metrics: ServiceMetric[] = [];
        try {
            const metricsResponse = await fetch(
                `${backendUrl}/api/pollers/${pollerId}/metrics`,
                {
                    headers: {
                        "X-API-Key": apiKey,
                        ...(token ? { Authorization: `Bearer ${token}` } : {}),
                    },
                    cache: "no-store",
                },
            );

            if (!metricsResponse.ok) {
                console.error(`Metrics API failed: ${metricsResponse.status}`);
            } else {
                metrics = await metricsResponse.json();
            }
        } catch (metricsError) {
            console.error("Error fetching metrics data:", metricsError);
        }

        const serviceMetrics = metrics.filter(
            (m) => m.service_name === serviceName,
        );

        const snmpData: SnmpDataPoint[] = [];
        if (service.type === "snmp") {
            // Add SNMP logic here if needed
        }

        return { service, metrics: serviceMetrics, snmpData, timeRange };
    } catch (err) {
        console.error("Error fetching data:", err);
        return { error: (err as Error).message, service: null };
    }
}

export async function generateMetadata({ params }: { params: Params }) {
    const { pollerid, servicename } = await params; // Await the params
    return {
        title: `${servicename} on ${pollerid} - ServiceRadar`,
    };
}

// Update the Page component to await params
export default async function Page(props: PageProps) {
    const { params, searchParams } = props;
    const { pollerid, servicename } = await params; // Await the params
    const resolvedSearchParams = await searchParams;
    const timeRange = resolvedSearchParams.timeRange || "1h";
    const cookieStore = await cookies(); // Await the cookies() promise
    const token = cookieStore.get("accessToken")?.value;
    const initialData = await fetchServiceData(pollerid, servicename, timeRange, token);

    return (
        <div>
            <Suspense
                fallback={
                    <div className="flex justify-center items-center h-64">
                        <div className="text-lg text-gray-600 dark:text-gray-300">
                            Loading service data...
                        </div>
                    </div>
                }
            >
                <ServiceDashboard
                    pollerId={pollerid}
                    serviceName={servicename}
                    initialService={initialData.service}
                    initialMetrics={initialData.metrics || []}
                    initialSnmpData={initialData.snmpData || []}
                    initialError={initialData.error}
                    initialTimeRange={initialData.timeRange || "1h"}
                />
            </Suspense>
        </div>
    );
}