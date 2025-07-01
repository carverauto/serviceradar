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

// src/app/service/device/[deviceid]/[servicename]/page.tsx
import { Suspense } from "react";
import DeviceServiceDashboard from "../../../../../components/Device/ServiceDashboard";
import SNMPDashboard from "../../../../../components/Network/SNMPDashboard";
import { cookies } from "next/headers";
import { fetchFromAPI } from "@/lib/api";
import { SnmpDataPoint } from "@/types/snmp";

type Params = Promise<{ deviceid: string; servicename: string }>;

interface PageProps {
    params: Promise<Params>;
    searchParams: Promise<{ timeRange?: string }>;
}

export const revalidate = 0;

async function fetchDeviceServiceData(
    deviceId: string,
    serviceName: string,
    timeRange = "1h",
    token?: string,
) {
    try {
        console.log(`fetchDeviceServiceData called with: deviceId="${deviceId}", serviceName="${serviceName}", timeRange="${timeRange}"`);
        
        // For device-based services, we'll fetch data directly using device metrics endpoints
        // This replaces the old poller-based service lookup
        
        if (serviceName.toLowerCase() === "snmp") {
            // Fetch SNMP data for the device
            // deviceId is already URL-encoded from the route params
            const hours = parseInt(timeRange.replace('h', ''));
            const endTime = new Date();
            // Get more data points by extending the time range for better rate calculation
            const startTime = new Date(endTime.getTime() - Math.max(hours, 2) * 60 * 60 * 1000);
            
            console.log(`Fetching SNMP data for device: ${deviceId}`);
            console.log(`API URL: /devices/${deviceId}/metrics?type=snmp&start=${startTime.toISOString()}&end=${endTime.toISOString()}`);
            
            const snmpData = await fetchFromAPI(
                `/devices/${deviceId}/metrics?type=snmp&start=${startTime.toISOString()}&end=${endTime.toISOString()}`,
                token
            );
            
            console.log(`SNMP data received:`, snmpData);
            console.log(`SNMP data type:`, typeof snmpData);
            console.log(`SNMP data is array:`, Array.isArray(snmpData));
            
            // Transform data to match SNMPDashboard expected format
            const transformedData = (snmpData || []).map(item => ({
                ...item,
                oid_name: item.if_index !== undefined ? `${item.name}_${item.if_index}` : item.name,
                // Ensure other fields are compatible
                value: item.value,
                timestamp: item.timestamp
            }));
            
            console.log(`Transformed SNMP data:`, transformedData.slice(0, 3));
            
            return { 
                deviceId, 
                serviceName, 
                timeRange,
                data: transformedData,
                error: null,
                type: 'snmp'
            };
        }
        
        if (serviceName.toLowerCase() === "sysmon") {
            // Fetch sysmon data for the device
            // deviceId is already URL-encoded from the route params
            const hours = timeRange.replace('h', '');
            const endTime = new Date();
            const startTime = new Date(endTime.getTime() - parseInt(hours) * 60 * 60 * 1000);
            
            const sysmonData = await fetchFromAPI(
                `/devices/${deviceId}/metrics?type=sysmon&start=${startTime.toISOString()}&end=${endTime.toISOString()}`,
                token
            );
            
            return { 
                deviceId, 
                serviceName, 
                timeRange,
                data: sysmonData || [],
                error: null,
                type: 'sysmon'
            };
        }
        
        return { 
            deviceId, 
            serviceName, 
            timeRange,
            data: [],
            error: `Service type '${serviceName}' not supported for device-based routing`,
            type: 'unknown'
        };
        
    } catch (err) {
        console.error("Error fetching device service data:", err);
        console.error("Error details:", {
            message: (err as Error).message,
            stack: (err as Error).stack,
            deviceId,
            serviceName,
            timeRange
        });
        return { 
            deviceId, 
            serviceName, 
            timeRange,
            data: [],
            error: (err as Error).message,
            type: 'error'
        };
    }
}

export async function generateMetadata({ params }: { params: Params }) {
    const { deviceid, servicename } = await params;
    return {
        title: `${servicename} on ${deviceid} - ServiceRadar`,
    };
}

export default async function Page(props: PageProps) {
    const { params, searchParams } = props;
    const { deviceid, servicename } = await params;
    const resolvedSearchParams = await searchParams;
    const timeRange = resolvedSearchParams.timeRange || "1h";
    const cookieStore = await cookies();
    const token = cookieStore.get("accessToken")?.value;

    const initialData = await fetchDeviceServiceData(deviceid, servicename, timeRange, token);

    return (
        <div>
            <Suspense
                fallback={
                    <div className="flex justify-center items-center h-64">
                        <div className="text-lg text-gray-600 dark:text-gray-300">
                            Loading device service data...
                        </div>
                    </div>
                }
            >
                {initialData.type === 'snmp' ? (
                    <SNMPDashboard
                        pollerId={deviceid}
                        serviceName={servicename}
                        initialData={initialData.data as SnmpDataPoint[]}
                        initialTimeRange={initialData.timeRange}
                        useDeviceId={true}
                    />
                ) : (
                    <DeviceServiceDashboard
                        deviceId={deviceid}
                        serviceName={servicename}
                        initialData={initialData.data}
                        initialError={initialData.error}
                        initialTimeRange={initialData.timeRange}
                    />
                )}
            </Suspense>
        </div>
    );
}