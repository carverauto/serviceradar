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

import React, { useState, useEffect, useCallback } from "react";
import {
    LineChart,
    Line,
    XAxis,
    YAxis,
    CartesianGrid,
    Tooltip,
    ResponsiveContainer,
    ReferenceLine
} from "recharts";
import { RefreshCw, AlertCircle, ArrowLeft } from "lucide-react";
import { useRouter } from "next/navigation";
import { useAuth } from "@/components/AuthProvider";
import { RperfMetric } from "@/types/rperf";

interface RPerfDashboardProps {
    nodeId: string;
    serviceName: string;
    initialTimeRange?: string;
}

interface ChartDataPoint {
    timestamp: number;
    formattedTime: string;
    bandwidth: number;
    jitter: number;
    loss: number;
    target: string;
    success: boolean;
}

const RperfDashboard = ({
                            nodeId,
                            serviceName,
                            initialTimeRange = "1h"
                        }: RPerfDashboardProps) => {
    const router = useRouter();
    const { token, refreshToken } = useAuth();
    const [rperfData, setRperfData] = useState<ChartDataPoint[]>([]);
    const [timeRange, setTimeRange] = useState(initialTimeRange);
    const [isLoading, setIsLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);
    const [averages, setAverages] = useState({
        bandwidth: 0,
        jitter: 0,
        loss: 0
    });
    const [lastRefreshed, setLastRefreshed] = useState(new Date());
    const [targetName, setTargetName] = useState("Unknown Target");

    // Wrap smoothData in its own useCallback to avoid recreation on each render
    const smoothData = useCallback((data: ChartDataPoint[]): ChartDataPoint[] => {
        if (data.length <= 5) return data;

        const smoothed = data.map((point, index, arr) => {
            const startBwJitter = Math.max(0, index - 2);
            const endBwJitter = Math.min(arr.length, index + 3);
            const windowBwJitter = arr.slice(startBwJitter, endBwJitter);

            const startLoss = Math.max(0, index - 4);
            const endLoss = Math.min(arr.length, index + 5);
            const windowLoss = arr.slice(startLoss, endLoss);

            const avgBandwidth = windowBwJitter.reduce((sum, p) => sum + p.bandwidth, 0) / windowBwJitter.length;
            const avgJitter = windowBwJitter.reduce((sum, p) => sum + p.jitter, 0) / windowBwJitter.length;
            const avgLoss = windowLoss.reduce((sum, p) => sum + p.loss, 0) / windowLoss.length;

            return {
                ...point,
                bandwidth: avgBandwidth,
                jitter: avgJitter,
                loss: avgLoss
            };
        });

        return smoothed;
    }, []); // No dependencies as this is a pure function

    const fetchData = useCallback(async () => {
        setIsLoading(true);
        try {
            const end = new Date();
            const start = new Date();
            switch (timeRange) {
                case "6h": start.setHours(end.getHours() - 6); break;
                case "24h": start.setHours(end.getHours() - 24); break;
                default: start.setHours(end.getHours() - 1);
            }

            // Construct the API URL properly
            const url = `/api/nodes/${nodeId}/rperf?start=${start.toISOString()}&end=${end.toISOString()}`;

            // Use simpler headers - let the middleware handle authentication
            const headers: HeadersInit = {
                "Content-Type": "application/json",
            };

            // Only add token if we have it from context
            if (token) {
                headers["Authorization"] = `Bearer ${token}`;
            }

            console.log(`Fetching rperf data from: ${url}`);

            const response = await fetch(url, {
                method: 'GET',
                headers,
                // This is important - ensure we send cookies
                credentials: 'include',
                // Disable cache for fresh data
                cache: "no-store"
            });

            // Let's log the response status for debugging
            console.log(`Rperf API response status: ${response.status}`);

            if (!response.ok) {
                if (response.status === 401) {
                    console.error("Authentication error fetching RPerfData - attempting token refresh");
                    const refreshed = await refreshToken();
                    if (refreshed === true) {
                        console.log("Token refreshed successfully, retrying request");
                        return fetchData(); // Retry with new token
                    } else {
                        console.error("Token refresh failed");
                        throw new Error("Authentication failed");
                    }
                } else {
                    throw new Error(`Failed to fetch Rperf data: ${response.status}`);
                }
            }

            const data: RperfMetric[] = await response.json();
            console.log(`Received rperf data: ${data.length} records`);

            if (data.length === 0) {
                console.log("No rperf data received");
                setRperfData([]);
                setAverages({ bandwidth: 0, jitter: 0, loss: 0 });
                setTargetName("No Data");
                setLastRefreshed(new Date());
                setIsLoading(false);
                return;
            }

            // Process data as before
            const filteredData = data.map(point => ({
                timestamp: new Date(point.timestamp).getTime(),
                formattedTime: new Date(point.timestamp).toLocaleTimeString(),
                bandwidth: point.bits_per_second / 1000000, // Convert to Mbps
                jitter: point.jitter_ms,
                loss: point.loss_percent,
                target: point.target,
                success: point.success
            }));

            const smoothedData = smoothData(filteredData);

            // Calculate averages
            const totalBandwidth = smoothedData.reduce((sum, point) => sum + point.bandwidth, 0);
            const totalJitter = smoothedData.reduce((sum, point) => sum + point.jitter, 0);
            const totalLoss = smoothedData.reduce((sum, point) => sum + point.loss, 0);
            const count = smoothedData.length || 1;

            setAverages({
                bandwidth: totalBandwidth / count,
                jitter: totalJitter / count,
                loss: totalLoss / count
            });

            if (smoothedData.length > 0) {
                setTargetName(smoothedData[0].target || "Unknown Target");
            }

            setRperfData(smoothedData);
            setLastRefreshed(new Date());
            setError(null);
            console.log("Successfully processed rperf data:", smoothedData.length, "records");
        } catch (err) {
            console.error("Error fetching rperf data:", err);
            setError("Failed to fetch Rperf data");
            setRperfData([]);
        } finally {
            setIsLoading(false);
        }
    }, [timeRange, nodeId, token, refreshToken, smoothData]);

    useEffect(() => {
        fetchData();
        const interval = setInterval(fetchData, 60000); // Refresh every minute
        return () => clearInterval(interval);
    }, [fetchData]);

    const handleRefresh = () => fetchData();

    const handleTimeRangeChange = (range: string) => setTimeRange(range);

    const handleBackToNodes = () => router.push("/nodes");

    const formatBandwidth = (value: number | undefined) =>
        value === undefined || value === null ? "N/A" : value >= 1000 ? `${(value / 1000).toFixed(2)} Gbps` : `${value.toFixed(2)} Mbps`;
    const formatJitter = (value: number | undefined) =>
        value === undefined || value === null ? "N/A" : `${value.toFixed(2)} ms`;
    const formatLoss = (value: number | undefined) =>
        value === undefined || value === null ? "N/A" : `${value.toFixed(2)}%`;
    const formatTimestamp = (timestamp: number) => new Date(timestamp).toLocaleTimeString();

    return (
        <div className="space-y-6">
            <div className="flex flex-col sm:flex-row justify-between items-center gap-4 bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                <div className="flex items-center gap-2">
                    <button
                        onClick={handleBackToNodes}
                        className="p-2 rounded-full bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600 transition-colors"
                    >
                        <ArrowLeft className="h-5 w-5" />
                        <span className="sr-only">Back to Nodes</span>
                    </button>
                    <h3 className="text-lg font-semibold text-gray-800 dark:text-gray-100">
                        Rperf Metrics Dashboard - {serviceName} ({targetName})
                    </h3>
                </div>
                <div className="flex items-center gap-3">
                    <button
                        onClick={handleRefresh}
                        disabled={isLoading}
                        className="p-2 rounded-full bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600 transition-colors"
                        aria-label="Refresh data"
                    >
                        <RefreshCw className={`h-5 w-5 ${isLoading ? 'animate-spin' : ''}`} />
                    </button>
                    <div className="flex gap-1 bg-gray-100 dark:bg-gray-700 p-1 rounded-md">
                        {["1h", "6h", "24h"].map((range) => (
                            <button
                                key={range}
                                onClick={() => handleTimeRangeChange(range)}
                                className={`px-3 py-1 rounded-md text-sm transition-colors ${
                                    timeRange === range
                                        ? "bg-blue-500 text-white shadow-sm"
                                        : "text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600"
                                }`}
                            >
                                {range}
                            </button>
                        ))}
                    </div>
                </div>
            </div>

            {error && (
                <div className="bg-red-50 dark:bg-red-900/30 p-4 rounded-lg shadow">
                    <div className="flex items-center">
                        <AlertCircle className="h-5 w-5 text-red-500 dark:text-red-400 mr-2" />
                        <div className="text-red-600 dark:text-red-300 font-medium">{error}</div>
                    </div>
                </div>
            )}

            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                    <div className="text-sm text-gray-500 dark:text-gray-400">Average Bandwidth</div>
                    <div className="text-2xl font-bold text-gray-800 dark:text-gray-100 mt-1">
                        {formatBandwidth(averages.bandwidth)}
                    </div>
                    <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">Target: 8 Mbps</div>
                </div>
                <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                    <div className="text-sm text-gray-500 dark:text-gray-400">Average Jitter</div>
                    <div className="text-2xl font-bold text-gray-800 dark:text-gray-100 mt-1">
                        {formatJitter(averages.jitter)}
                    </div>
                    <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">Target: &lt; 2.0 ms</div>
                </div>
                <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                    <div className="text-sm text-gray-500 dark:text-gray-400">Average Packet Loss</div>
                    <div className="text-2xl font-bold text-gray-800 dark:text-gray-100 mt-1">
                        {formatLoss(averages.loss)}
                    </div>
                    <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">Target: &lt; 0.5%</div>
                </div>
            </div>

            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4">
                <h4 className="text-md font-medium mb-2 text-gray-800 dark:text-gray-100">Bandwidth (Mbps)</h4>
                <div className="h-64">
                    <ResponsiveContainer width="100%" height="100%">
                        <LineChart data={rperfData} margin={{ top: 5, right: 10, left: 0, bottom: 5 }}>
                            <CartesianGrid strokeDasharray="3 3" strokeOpacity={0.2} />
                            <XAxis
                                dataKey="timestamp"
                                type="number"
                                domain={['dataMin', 'dataMax']}
                                tickFormatter={formatTimestamp}
                                tick={{ fontSize: 10 }}
                                axisLine={false}
                                tickLine={false}
                            />
                            <YAxis
                                domain={[0, (dataMax: number) => Math.max(10, dataMax * 1.1)]}
                                tick={{ fontSize: 10 }}
                                axisLine={false}
                                tickLine={false}
                            />
                            <Tooltip
                                labelFormatter={(label) => formatTimestamp(label as number)}
                                formatter={(value: number, name: string) => [
                                    name === "Bandwidth" ? formatBandwidth(value) :
                                        name === "Jitter" ? formatJitter(value) :
                                            formatLoss(value),
                                    name
                                ]}
                            />
                            <ReferenceLine y={8} stroke="#8884d8" strokeDasharray="3 3" />
                            <Line
                                type="monotone"
                                dataKey="bandwidth"
                                name="Bandwidth"
                                stroke="#8884d8"
                                strokeWidth={2}
                                dot={false}
                                activeDot={{ r: 5 }}
                                isAnimationActive={false}
                            />
                        </LineChart>
                    </ResponsiveContainer>
                </div>
            </div>

            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4">
                <h4 className="text-md font-medium mb-2 text-gray-800 dark:text-gray-100">Jitter (ms)</h4>
                <div className="h-64">
                    <ResponsiveContainer width="100%" height="100%">
                        <LineChart data={rperfData} margin={{ top: 5, right: 10, left: 0, bottom: 5 }}>
                            <CartesianGrid strokeDasharray="3 3" strokeOpacity={0.2} />
                            <XAxis
                                dataKey="timestamp"
                                type="number"
                                domain={['dataMin', 'dataMax']}
                                tickFormatter={formatTimestamp}
                                tick={{ fontSize: 10 }}
                                axisLine={false}
                                tickLine={false}
                            />
                            <YAxis
                                domain={[0, (dataMax: number) => Math.max(5, dataMax * 1.2)]}
                                tick={{ fontSize: 10 }}
                                axisLine={false}
                                tickLine={false}
                            />
                            <Tooltip
                                labelFormatter={(label) => formatTimestamp(label as number)}
                                formatter={(value: number, name: string) => [
                                    name === "Bandwidth" ? formatBandwidth(value) :
                                        name === "Jitter" ? formatJitter(value) :
                                            formatLoss(value),
                                    name
                                ]}
                            />
                            <ReferenceLine y={2} stroke="#82ca9d" strokeDasharray="3 3" />
                            <Line
                                type="monotone"
                                dataKey="jitter"
                                name="Jitter"
                                stroke="#82ca9d"
                                strokeWidth={2}
                                dot={false}
                                activeDot={{ r: 5 }}
                                isAnimationActive={false}
                            />
                        </LineChart>
                    </ResponsiveContainer>
                </div>
            </div>

            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4">
                <h4 className="text-md font-medium mb-2 text-gray-800 dark:text-gray-100">Packet Loss (%)</h4>
                <div className="h-64">
                    <ResponsiveContainer width="100%" height="100%">
                        <LineChart data={rperfData} margin={{ top: 5, right: 10, left: 0, bottom: 5 }}>
                            <CartesianGrid strokeDasharray="3 3" strokeOpacity={0.2} />
                            <XAxis
                                dataKey="timestamp"
                                type="number"
                                domain={['dataMin', 'dataMax']}
                                tickFormatter={formatTimestamp}
                                tick={{ fontSize: 10 }}
                                axisLine={false}
                                tickLine={false}
                            />
                            <YAxis
                                domain={[0, (dataMax: number) => Math.max(20, dataMax * 1.2)]}
                                tick={{ fontSize: 10 }}
                                axisLine={false}
                                tickLine={false}
                            />
                            <Tooltip
                                labelFormatter={(label) => formatTimestamp(label as number)}
                                formatter={(value: number, name: string) => [
                                    name === "Bandwidth" ? formatBandwidth(value) :
                                        name === "Jitter" ? formatJitter(value) :
                                            formatLoss(value),
                                    name
                                ]}
                            />
                            <ReferenceLine y={0.5} stroke="#ff7300" strokeDasharray="3 3" />
                            <Line
                                type="stepAfter"
                                dataKey="loss"
                                name="Packet Loss"
                                stroke="#ff7300"
                                strokeWidth={2}
                                dot={false}
                                activeDot={{ r: 5 }}
                                isAnimationActive={false}
                            />
                        </LineChart>
                    </ResponsiveContainer>
                </div>
            </div>

            <div className="text-right text-xs text-gray-500 dark:text-gray-400">
                Last updated: {lastRefreshed.toLocaleString()}
            </div>
        </div>
    );
};

export default RperfDashboard;