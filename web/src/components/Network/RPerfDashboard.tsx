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

import React, { useState, useEffect, useCallback, useMemo } from "react";
import {
    LineChart,
    BarChart,
    Bar,
    Line,
    XAxis,
    YAxis,
    CartesianGrid,
    Tooltip,
    ResponsiveContainer,
    ReferenceLine,
    ReferenceArea
} from "recharts";
import { RefreshCw, AlertCircle, ArrowLeft } from "lucide-react";
import { useRouter } from "next/navigation";
import { useAuth } from "@/components/AuthProvider";
import { useRperfData } from '@/hooks/useRperfData';

interface RPerfDashboardProps {
    pollerId: string;
    serviceName: string;
    initialTimeRange?: string;
}

interface ChartDataPoint {
    timestamp: number;
    formattedTime: string;
    bandwidth: number;
    jitter: number;
    loss: number;
    trendLoss?: number;
    target: string;
    success: boolean;
}

interface AggregatedDataPoint {
    timestamp: number;
    formattedTime: string;
    loss: number;
    trendLoss?: number;
}

const RperfDashboard = ({
                            pollerId,
                            serviceName,
                            initialTimeRange = "1h"
                        }: RPerfDashboardProps) => {
    const router = useRouter();
    const { token } = useAuth();
    const [rperfData, setRperfData] = useState<ChartDataPoint[]>([]);
    const [aggregatedPacketLossData, setAggregatedPacketLossData] = useState<AggregatedDataPoint[]>([]);
    const [timeRange, setTimeRange] = useState(initialTimeRange);
    const [averages, setAverages] = useState({
        bandwidth: 0,
        jitter: 0,
        loss: 0
    });
    const [lastRefreshed, setLastRefreshed] = useState(new Date());
    const [targetName, setTargetName] = useState("Unknown Target");

    // Memoize time range to prevent infinite re-renders
    const { start, end } = useMemo(() => {
        const endTime = new Date();
        const startTime = new Date();
        switch (timeRange) {
            case "6h": startTime.setHours(endTime.getHours() - 6); break;
            case "24h": startTime.setHours(endTime.getHours() - 24); break;
            default: startTime.setHours(endTime.getHours() - 1);
        }
        return { start: startTime, end: endTime };
    }, [timeRange]); // Recalculate when timeRange changes

    // Use React Query for data fetching
    const { 
        data: rawMetrics = [], 
        isLoading, 
        error: queryError,
        refetch 
    } = useRperfData({
        pollerId,
        startTime: start,
        endTime: end,
        enabled: !!token
    });

    const error = queryError ? queryError.message : null;

    // Filter outliers in packet loss data
    const filterOutliers = useCallback((data: ChartDataPoint[]): ChartDataPoint[] => {
        const losses = data.map(point => point.loss);
        const sortedLosses = [...losses].sort((a, b) => a - b);
        const q1 = sortedLosses[Math.floor(losses.length * 0.25)];
        const q3 = sortedLosses[Math.floor(losses.length * 0.75)];
        const iqr = q3 - q1;
        const upperBound = q3 + 1.5 * iqr;

        return data.map(point => ({
            ...point,
            loss: point.loss > upperBound ? upperBound : point.loss
        }));
    }, []);

    // Smooth data with different window sizes for each metric
    const smoothData = useCallback((data: ChartDataPoint[]): ChartDataPoint[] => {
        if (data.length <= 5) return data;

        const smoothed = data.map((point, index, arr) => {
            const startBwJitter = Math.max(0, index - 2);
            const endBwJitter = Math.min(arr.length, index + 3);
            const windowBwJitter = arr.slice(startBwJitter, endBwJitter);

            const startLoss = Math.max(0, index - 7);
            const endLoss = Math.min(arr.length, index + 8);
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
    }, []);

    // Calculate trend line for packet loss with a larger window
    const calculateTrend = useCallback((data: ChartDataPoint[]): ChartDataPoint[] => {
        const trendWindow = 30;
        return data.map((point, index, arr) => {
            const start = Math.max(0, index - trendWindow / 2);
            const end = Math.min(arr.length, index + trendWindow / 2 + 1);
            const window = arr.slice(start, end);
            const avgLoss = window.reduce((sum, p) => sum + p.loss, 0) / window.length;
            return { ...point, trendLoss: avgLoss };
        });
    }, []);

    // Aggregate packet loss data into time buckets (e.g., every 5 minutes)
    const aggregatePacketLossData = useCallback((data: ChartDataPoint[]): AggregatedDataPoint[] => {
        if (data.length === 0) return [];

        const bucketSize = 5 * 60 * 1000; // 5 minutes in milliseconds
        const aggregated: { [key: number]: { loss: number[], timestamp: number } } = {};

        // Group data into 5-minute buckets
        data.forEach(point => {
            const bucketStart = Math.floor(point.timestamp / bucketSize) * bucketSize;
            if (!aggregated[bucketStart]) {
                aggregated[bucketStart] = { loss: [], timestamp: bucketStart };
            }
            aggregated[bucketStart].loss.push(point.loss);
        });

        // Calculate average loss for each bucket
        const aggregatedData = Object.keys(aggregated).map(bucketStart => {
            const bucket = aggregated[parseInt(bucketStart)];
            const avgLoss = bucket.loss.reduce((sum, val) => sum + val, 0) / bucket.loss.length;
            return {
                timestamp: bucket.timestamp,
                formattedTime: new Date(bucket.timestamp).toLocaleTimeString(),
                loss: avgLoss
            };
        }).sort((a, b) => a.timestamp - b.timestamp);

        // Calculate trend for aggregated data
        const trendWindow = 6; // 6 buckets (30 minutes)
        const aggregatedWithTrend = aggregatedData.map((point, index, arr) => {
            const start = Math.max(0, index - trendWindow / 2);
            const end = Math.min(arr.length, index + trendWindow / 2 + 1);
            const window = arr.slice(start, end);
            const avgLoss = window.reduce((sum, p) => sum + p.loss, 0) / window.length;
            return { ...point, trendLoss: avgLoss };
        });

        return aggregatedWithTrend;
    }, []);


    // Process raw metrics data when it changes
    useEffect(() => {
        if (!rawMetrics || rawMetrics.length === 0) {
            setRperfData([]);
            setAggregatedPacketLossData([]);
            setAverages({ bandwidth: 0, jitter: 0, loss: 0 });
            setTargetName("No Data");
            setLastRefreshed(new Date());
            return;
        }

        // Process data
        const processedData = rawMetrics.map(point => ({
            timestamp: new Date(point.timestamp).getTime(),
            formattedTime: new Date(point.timestamp).toLocaleTimeString(),
            bandwidth: point.bits_per_second / 1000000,
            jitter: point.jitter_ms,
            loss: point.loss_percent,
            target: point.target,
            success: point.success
        }));

        // Filter outliers, smooth data, and calculate trend
        const filteredData = filterOutliers(processedData);
        const smoothedData = smoothData(filteredData);
        const smoothedDataWithTrend = calculateTrend(smoothedData);

        // Aggregate packet loss data for bar chart
        const aggregatedLossData = aggregatePacketLossData(smoothedDataWithTrend);

        // Calculate averages
        const totalBandwidth = smoothedDataWithTrend.reduce((sum, d) => sum + d.bandwidth, 0);
        const totalJitter = smoothedDataWithTrend.reduce((sum, d) => sum + d.jitter, 0);
        const totalLoss = smoothedDataWithTrend.reduce((sum, d) => sum + d.loss, 0);

        setRperfData(smoothedDataWithTrend);
        setAggregatedPacketLossData(aggregatedLossData);
        setAverages({
            bandwidth: Math.round(totalBandwidth / smoothedDataWithTrend.length),
            jitter: Math.round(totalJitter / smoothedDataWithTrend.length * 100) / 100,
            loss: Math.round(totalLoss / smoothedDataWithTrend.length * 100) / 100
        });

        // Determine the target name
        const targetNames = [...new Set(rawMetrics.map(d => d.target))];
        setTargetName(targetNames.length === 1 ? targetNames[0] : `${targetNames.length} Targets`);

        setLastRefreshed(new Date());
    }, [rawMetrics, filterOutliers, smoothData, calculateTrend, aggregatePacketLossData]);

    const handleRefresh = () => refetch();

    const handleTimeRangeChange = (range: string) => setTimeRange(range);

    const handleBackToDashboard = () => router.push("/dashboard");

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
                        onClick={handleBackToDashboard}
                        className="p-2 rounded-full bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600 transition-colors"
                    >
                        <ArrowLeft className="h-5 w-5" />
                        <span className="sr-only">Back to Dashboard</span>
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
                        <BarChart data={aggregatedPacketLossData} margin={{ top: 5, right: 10, left: 0, bottom: 5 }}>
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
                                domain={[0, (dataMax: number) => Math.min(20, Math.max(5, dataMax * 1.2))]}
                                tick={{ fontSize: 10 }}
                                axisLine={false}
                                tickLine={false}
                            />
                            <Tooltip
                                labelFormatter={(label) => formatTimestamp(label as number)}
                                formatter={(value: number, name: string) => [
                                    formatLoss(value),
                                    name
                                ]}
                            />
                            <ReferenceLine y={0.5} stroke="#ff7300" strokeDasharray="3 3" />
                            <ReferenceArea
                                y1={0.5}
                                y2={Math.min(20, Math.max(5, Math.max(...aggregatedPacketLossData.map(d => d.loss)) * 1.2))}
                                fill="#ff7300"
                                fillOpacity={0.1}
                                ifOverflow="extendDomain"
                            />
                            <Bar
                                dataKey="loss"
                                name="Packet Loss"
                                fill="#ff7300"
                                barSize={10}
                                isAnimationActive={false}
                            />
                            <Line
                                type="monotone"
                                dataKey="trendLoss"
                                name="Packet Loss Trend"
                                stroke="#ffaa00"
                                strokeWidth={1}
                                strokeDasharray="5 5"
                                dot={false}
                                isAnimationActive={false}
                            />
                        </BarChart>
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