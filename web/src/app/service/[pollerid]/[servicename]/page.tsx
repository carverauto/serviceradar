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
import { Poller, ServiceMetric, ServicePayload } from "@/types/types";
import { SnmpDataPoint } from "@/types/snmp";
import { fetchFromAPI } from "@/lib/api";
import { SysmonData } from "@/types/sysmon"; // Keep this import for the final SysmonData type
import { fetchSystemData } from "@/components/Metrics/data-service"; // Import fetchSystemData

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
    let service: ServicePayload | null = null;
    let metrics: ServiceMetric[] = [];
    const snmpData: SnmpDataPoint[] = [];
    let sysmonData: SysmonData | Record<string, never> = {}; // Initialize with default empty object or full structure

    try {
        // Fetch the specific service payload directly using fetchFromAPI.
        service = await fetchFromAPI<ServicePayload>(
            `/pollers/${pollerId}/services/${serviceName}`,
            token
        );

        if (!service) {
            // Return all properties, even if service is null
            return { error: "Service not found or failed to fetch", service: null, metrics, snmpData, sysmonData, timeRange };
        }

        // Fetch poller information (still potentially needed if other parts of the page or ServiceDashboard expect Poller data)
        const pollers: Poller[] | null = await fetchFromAPI<Poller[]>("/pollers", token);
        const poller = pollers?.find((n) => n.poller_id === pollerId);

        if (!poller) {
            // Return all properties if poller data is inconsistent
            return { error: "Poller data for service not found", service, metrics, snmpData, sysmonData, timeRange };
        }

        // Fetch metrics for this poller
        const allPollerMetrics: ServiceMetric[] | null = await fetchFromAPI<ServiceMetric[]>(
            `/pollers/${pollerId}/metrics`,
            token
        );
        if (allPollerMetrics) {
            metrics = allPollerMetrics;
        } else {
            console.warn(`Metrics API failed for poller ${pollerId}: No data or error fetching.`);
        }

        const serviceMetrics = metrics.filter(
            (m) => m.service_name === serviceName,
        );

        if (service.type === "snmp") {
            // If SNMP data is needed on initial load, fetch it here
            // For now, it will use `initialSnmpData=[]` from props default in ServiceDashboard
        }

        // If the service is 'sysmon', fetch the full SysmonData using the dedicated function
        if (serviceName.toLowerCase() === "sysmon") {
            try {
                // Call fetchSystemData which already fetches and processes all Sysmon metrics
                const fetchedSysmonData: SysmonData | null = await fetchSystemData(pollerId, timeRange);
                if (fetchedSysmonData) {
                    sysmonData = fetchedSysmonData;
                } else {
                    console.warn(`fetchSystemData returned null for poller ${pollerId}.`);
                }
            } catch (sysmonError) {
                console.error("Error fetching Sysmon data with fetchSystemData:", sysmonError);
                // On error, sysmonData remains its default empty object
            }
        }

        return { service, metrics: serviceMetrics, snmpData, sysmonData, timeRange };
    } catch (err) {
        console.error("Error fetching data:", err);
        // Ensure all properties are returned, even on top-level error
        return { error: (err as Error).message, service, metrics, snmpData, sysmonData, timeRange };
    }
}

export async function generateMetadata({ params }: { params: Params }) {
    const { pollerid, servicename } = await params;
    return {
        title: `${servicename} on ${pollerid} - ServiceRadar`,
    };
}

export default async function Page(props: PageProps) {
    const { params, searchParams } = props;
    const { pollerid, servicename } = await params;
    const resolvedSearchParams = await searchParams;
    const timeRange = resolvedSearchParams.timeRange || "1h";
    const cookieStore = await cookies();
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
                    initialSysmonData={initialData.sysmonData || {}} // This now correctly receives SysmonData or {}
                    initialError={initialData.error}
                    initialTimeRange={initialData.timeRange || "1h"}
                />
            </Suspense>
        </div>
    );
}