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

// src/components/ServiceDashboard.tsx
"use client";

import React, { useState, useEffect } from "react";
import { useRouter } from "next/navigation";
import {
    XAxis,
    YAxis,
    Tooltip,
    Legend,
    Area,
    AreaChart,
    CartesianGrid,
    ResponsiveContainer,
} from "recharts";
import NetworkSweepView from "../Network/NetworkSweepView";
import { PingStatus } from "../Network/NetworkStatus";
import SNMPDashboard from "../Network/SNMPDashboard";
import { ArrowLeft } from "lucide-react";
import { ServiceMetric, ServiceDetails, ServicePayload } from "@/types/types";
import { SnmpDataPoint } from "@/types/snmp";
import { SysmonData } from "@/types/sysmon";
import RPerfDashboard from "@/components/Network/RPerfDashboard";
import LanDiscoveryDashboard from "@/components/Network/LANDiscoveryDashboard";
import SysmonVmDetails from "@/components/Service/SysmonVmDetails";


// Define props interface
interface ServiceDashboardProps {
    pollerId: string;
    serviceName: string;
    initialService?: ServicePayload | null;
    initialMetrics?: ServiceMetric[];
    initialSnmpData?: SnmpDataPoint[];
    initialSysmonData?: SysmonData | Record<string, never>;
    initialError?: string | null;
    initialTimeRange?: string;
}

const Dashboard: React.FC<ServiceDashboardProps> = ({
                                                               pollerId,
                                                               serviceName,
                                                               initialService = null,
                                                               initialMetrics = [],
                                                               initialSnmpData = [],
                                                               initialError = null,
                                                               initialTimeRange = "1h",
                                                           }) => {
    const router = useRouter();
    const [chartHeight, setChartHeight] = useState<number>(256);

    // Use props directly instead of copying to state
    const serviceData = initialService;
    const metricsData = initialMetrics;
    const snmpData = initialSnmpData;
    const loading = !initialService && !initialError;
    const error = initialError;
    const selectedTimeRange = initialTimeRange;

    // Check if we need to redirect
    const shouldRedirectToMetrics = serviceName.toLowerCase() === "sysmon";

    // Handle redirect for sysmon service
    useEffect(() => {
        if (shouldRedirectToMetrics) {
            router.push(`/metrics?pollerId=${pollerId}`);
        }
    }, [shouldRedirectToMetrics, pollerId, router]);

    // Adjust chart height based on screen size
    useEffect(() => {
        const handleResize = () => {
            const width = window.innerWidth;
            if (width < 640) {
                setChartHeight(200);
            } else if (width < 1024) {
                setChartHeight(220);
            } else {
                setChartHeight(256);
            }
        };

        handleResize();
        window.addEventListener("resize", handleResize);
        return () => window.removeEventListener("resize", handleResize);
    }, []);

    useEffect(() => {
        return () => console.log("ServiceDashboard unmounted");
    }, [pollerId, serviceName, initialSnmpData]);

    const filterDataByTimeRange = (
        data: { timestamp: string; response_time: number }[],
        range: string,
    ) => {
        const now = Date.now();
        const ranges: { [key: string]: number } = {
            "1h": 60 * 60 * 1000,
            "6h": 6 * 60 * 60 * 1000,
            "24h": 24 * 60 * 60 * 1000,
        };
        const timeLimit = now - ranges[range];
        return data.filter(
            (point) => new Date(point.timestamp).getTime() >= timeLimit,
        );
    };

    const renderMetricsChart = () => {
        if (!metricsData.length) return null;

        const chartData = filterDataByTimeRange(
            metricsData.map((metric) => ({
                timestamp: metric.timestamp,
                response_time: metric.response_time / 1000000,
            })),
            selectedTimeRange,
        ).map((data) => ({
            timestamp: new Date(data.timestamp).getTime(),
            response_time: data.response_time,
        }));

        if (chartData.length === 0) {
            return (
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 sm:p-6 transition-colors">
                    <div className="flex flex-col sm:flex-row sm:justify-between sm:items-center mb-4 gap-2">
                        <h3 className="text-lg font-semibold text-gray-800 dark:text-gray-100">
                            Response Time
                        </h3>
                    </div>
                    <div className="h-32 sm:h-64 flex items-center justify-center text-gray-500 dark:text-gray-400">
                        No data available for the selected time range
                    </div>
                </div>
            );
        }

        return (
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 sm:p-6 transition-colors">
                <div className="flex flex-col sm:flex-row sm:justify-between sm:items-center mb-4 gap-2">
                    <h3 className="text-lg font-semibold text-gray-800 dark:text-gray-100">
                        Response Time
                    </h3>
                </div>
                <div style={{ height: `${chartHeight}px` }} className="h-48 sm:h-64">
                    <ResponsiveContainer width="100%" height="100%">
                        <AreaChart data={chartData}>
                            <CartesianGrid strokeDasharray="3 3" />
                            <XAxis
                                dataKey="timestamp"
                                type="number"
                                domain={["auto", "auto"]}
                                tickFormatter={(ts: number) => new Date(ts).toLocaleTimeString()}
                            />
                            <YAxis unit="ms" domain={["auto", "auto"]} />
                            <Tooltip
                                labelFormatter={(ts: number) => new Date(ts).toLocaleString()}
                                formatter={(value: number) => [
                                    `${value.toFixed(2)} ms`,
                                    "Response Time",
                                ]}
                            />
                            <Legend />
                            <defs>
                                <linearGradient
                                    id="responseTimeGradient"
                                    x1="0"
                                    y1="0"
                                    x2="0"
                                    y2="1"
                                >
                                    <stop offset="5%" stopColor="#8884d8" stopOpacity={0.8} />
                                    <stop offset="95%" stopColor="#8884d8" stopOpacity={0.2} />
                                </linearGradient>
                            </defs>
                            <Area
                                type="monotone"
                                dataKey="response_time"
                                stroke="#8884d8"
                                strokeWidth={2}
                                fill="url(#responseTimeGradient)"
                                dot={false}
                                name="Response Time"
                                isAnimationActive={false}
                            />
                        </AreaChart>
                    </ResponsiveContainer>
                </div>
            </div>
        );
    };

    const renderServiceContent = () => {
        if (!serviceData) return null;

        // Handle LAN Discovery service
        if (serviceData.name === 'lan_discovery_via_mapper' || serviceData.type === 'network_discovery') {
            return (
                <LanDiscoveryDashboard
                    pollerId={pollerId}
                    serviceName={serviceName}
                    initialService={serviceData} // Now serviceData is of type ServicePayload
                    initialError={null}
                    initialTimeRange={initialTimeRange}
                />
            );
        }

        if (serviceData.type === "snmp") {
            return (
                <SNMPDashboard
                    pollerId={pollerId}
                    serviceName={serviceName}
                    initialData={snmpData}
                    initialTimeRange={initialTimeRange}
                />
            );
        }

        if (serviceData.type === "sweep") {
            return (
                <NetworkSweepView pollerId={pollerId} service={serviceData} standalone />
            );
        }

        if (serviceData.type === "icmp") {
            return (
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 sm:p-6 transition-colors">
                    <h3 className="text-lg font-semibold mb-4 text-gray-800 dark:text-gray-100">
                        ICMP Status
                    </h3>
                    <PingStatus
                        details={serviceData.details ?? ''}
                        pollerId={pollerId}
                        serviceName={serviceName}
                    />
                </div>
            );
        }

        if (serviceData.type === "grpc" && serviceName === "rperf-checker") {
            return (
                <RPerfDashboard
                    pollerId={pollerId}
                    serviceName={serviceName}
                    initialTimeRange={initialTimeRange}
                />
            );
        }

        if (serviceName.toLowerCase() === "sysmon") {
            // Show a loading state while redirecting
            return (
                <div className="bg-white dark:bg-gray-800 rounded-lg p-6 text-center shadow">
                    <div className="flex justify-center mb-4">
                        <div className="w-12 h-12 border-4 border-blue-500 border-t-transparent rounded-full animate-spin"></div>
                    </div>
                    <h3 className="text-lg font-semibold mb-4 text-gray-800 dark:text-gray-100">
                        Redirecting to System Metrics Dashboard...
                    </h3>
                </div>
            );
        }

        if (
            serviceData &&
            (serviceData.service_name === "sysmon-vm" || serviceData.name === "sysmon-vm")
        ) {
            return (
                <SysmonVmDetails
                    service={serviceData}
                    details={serviceData.details ?? {}}
                />
            );
        }

        let details: ServiceDetails = {};
        try {
            details =
                typeof serviceData.details === "string"
                    ? JSON.parse(serviceData.details)
                    : (serviceData.details as ServiceDetails) || {};
        } catch (e) {
            console.error("Error parsing service details:", e);
            return null;
        }

        if (!details) return null;

        return (
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                {Object.entries(details)
                    .filter(([key]) => key !== "history")
                    .map(([key, value]) => (
                        <div
                            key={key}
                            className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 sm:p-6 transition-colors"
                        >
                            <h3 className="text-lg font-semibold mb-2 text-gray-800 dark:text-gray-100">
                                {key
                                    .split("_")
                                    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
                                    .join(" ")}
                            </h3>
                            <div className="text-base sm:text-lg break-all text-gray-700 dark:text-gray-100">
                                {typeof value === "boolean"
                                    ? value
                                        ? "Yes"
                                        : "No"
                                    : String(value)}
                            </div>
                        </div>
                    ))}
            </div>
        );
    };

    if (loading) {
        return (
            <div className="space-y-4">
                <div className="flex justify-between items-center">
                    <div className="h-8 bg-gray-200 dark:bg-gray-700 rounded w-32 sm:w-64 animate-pulse"></div>
                    <div className="h-8 bg-gray-200 dark:bg-gray-700 rounded w-20 sm:w-32 animate-pulse"></div>
                </div>
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 sm:p-6">
                    <div className="h-6 bg-gray-200 dark:bg-gray-700 rounded w-24 sm:w-40 mb-4 animate-pulse"></div>
                    <div className="flex justify-between">
                        <div className="h-8 bg-gray-200 dark:bg-gray-700 rounded w-16 sm:w-24 animate-pulse"></div>
                    </div>
                </div>
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 sm:p-6">
                    <div className="h-6 bg-gray-200 dark:bg-gray-700 rounded w-24 sm:w-40 mb-4 animate-pulse"></div>
                    <div className="h-32 sm:h-64 bg-gray-100 dark:bg-gray-700 rounded animate-pulse"></div>
                </div>
            </div>
        );
    }

    if (error) {
        return (
            <div className="bg-red-50 dark:bg-red-900 p-4 sm:p-6 rounded-lg shadow text-red-600 dark:text-red-200">
                <h2 className="text-xl font-bold mb-4">Error Loading Service</h2>
                <p className="mb-4">{error}</p>
                <button
                    onClick={() => router.push("/dashboard")}
                    className="mt-2 px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-800 dark:text-gray-100 hover:bg-gray-300 dark:hover:bg-gray-600 rounded transition-colors flex items-center"
                >
                    <ArrowLeft className="mr-2 h-4 w-4" />
                    Back to Dashboard
                </button>
            </div>
        );
    }

    // For LAN Discovery service, render only the dashboard component
    if (serviceData && (serviceData.name === 'lan_discovery_via_mapper' || serviceData.type === 'network_discovery')) {
        return renderServiceContent();
    }

    return (
        <div className="space-y-4 sm:space-y-6 transition-colors">
            <div className="flex flex-col sm:flex-row sm:justify-between sm:items-center gap-2">
                <h2 className="text-xl sm:text-2xl font-bold text-gray-800 dark:text-gray-100">
                    {serviceName} Service Status
                </h2>
                <button
                    onClick={() => router.push("/dashboard")}
                    className="px-4 py-2 bg-gray-100 dark:bg-gray-700 dark:text-gray-100 hover:bg-gray-200 dark:hover:bg-gray-600 rounded transition-colors flex items-center self-start"
                >
                    <ArrowLeft className="mr-2 h-4 w-4" />
                    Back to Dashboard
                </button>
            </div>
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 sm:p-6 transition-colors">
                <div className="flex items-center justify-between">
                    <h3 className="text-lg font-semibold text-gray-800 dark:text-gray-100">
                        Service Status
                    </h3>
                    <div
                        className={`px-3 py-1 rounded transition-colors ${
                            serviceData?.available
                                ? "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-100"
                                : "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-100"
                        }`}
                    >
                        {serviceData?.available ? "Online" : "Offline"}
                    </div>
                </div>
            </div>
            {renderMetricsChart()}
            {renderServiceContent()}
        </div>
    );
};

export default React.memo(Dashboard);
