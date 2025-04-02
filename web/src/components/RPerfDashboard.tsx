// src/components/RPerfDashboard.tsx
"use client";

import React, { useState, useEffect, useCallback } from "react"; // Import useCallback
import {
    AreaChart,
    Area,
    XAxis,
    YAxis,
    CartesianGrid,
    Tooltip,
    Legend,
    ResponsiveContainer,
} from "recharts";
import { useRouter, useSearchParams } from "next/navigation";
import { useAuth } from "@/components/AuthProvider";
import { RperfMetric } from "@/types/rperf";
import { AlertCircle, RefreshCw } from "lucide-react";

const REFRESH_INTERVAL = 10000;

const RperfDashboard: React.FC<{
    nodeId: string;
    serviceName: string;
    initialData?: RperfMetric[];
    initialTimeRange?: string;
}> = ({ nodeId, serviceName, initialData = [], initialTimeRange = "1h" }) => {
    const router = useRouter();
    const searchParams = useSearchParams();
    const { token } = useAuth();
    const [rperfData, setRperfData] = useState<RperfMetric[]>(initialData);
    const [timeRange, setTimeRange] = useState<string>(
        searchParams.get("timeRange") || initialTimeRange,
    );
    const [chartHeight, setChartHeight] = useState<number>(384);
    // Adjust initial loading state: true if initialData is empty/null
    const [loading, setLoading] = useState<boolean>(!initialData || initialData.length === 0);
    const [error, setError] = useState<string | null>(null);
    const [refreshing, setRefreshing] = useState<boolean>(false);

    // Chart resizing effect (no changes needed)
    useEffect(() => {
        const handleResize = () => {
            const width = window.innerWidth;
            if (width < 640) setChartHeight(250);
            else if (width < 1024) setChartHeight(300);
            else setChartHeight(384);
        };
        handleResize();
        window.addEventListener("resize", handleResize);
        return () => window.removeEventListener("resize", handleResize);
    }, []);

    // --- Stabilize fetchRperfData with useCallback ---
    const fetchRperfData = useCallback(async () => {
        // console.log(`Workspaceing rperf data for ${nodeId} with timeRange ${timeRange}`); // Debug log
        const end = new Date();
        const start = new Date();
        switch (timeRange) {
            case "1h": start.setHours(end.getHours() - 1); break;
            case "6h": start.setHours(end.getHours() - 6); break;
            case "24h": start.setHours(end.getHours() - 24); break;
            default: start.setHours(end.getHours() - 1); // Default to 1h
        }

        // Ensure start/end are valid before fetching
        if (isNaN(start.getTime()) || isNaN(end.getTime())) {
            console.error("Invalid start/end date for fetch");
            setError("Invalid time range specified.");
            setLoading(false);
            setRefreshing(false);
            return;
        }

        setRefreshing(true); // Indicate refresh start
        // No need to set loading=true here if data already exists

        try {
            const headers: HeadersInit = { "Content-Type": "application/json" };
            if (token) headers["Authorization"] = `Bearer ${token}`;

            const response = await fetch(
                `/api/nodes/${nodeId}/rperf?start=${start.toISOString()}&end=${end.toISOString()}`,
                { headers, cache: "no-store" },
            );

            if (!response.ok) {
                const errorText = await response.text();
                console.error(`Rperf fetch failed: ${response.status} - ${errorText}`); // Log error details
                throw new Error(`Failed to fetch rperf data: ${response.status}`); // Simpler error message for user
            }

            const data: RperfMetric[] = await response.json();
            // console.log("Raw rperf data received:", data); // Debug log

            setRperfData(data); // Update the data state
            setError(null); // Clear any previous error on success
        } catch (err) {
            console.error("Error fetching rperf data:", err);
            setError((err as Error).message || "Failed to fetch rperf metrics");
            // Don't clear existing data on error, show last known good state if possible
        } finally {
            setLoading(false); // Ensure loading is false after fetch attempt
            setRefreshing(false); // Indicate refresh end
        }
        // Add dependencies needed *inside* the fetch logic
    }, [nodeId, timeRange, token]);


    // --- Revised Data Fetching Effect ---
    useEffect(() => {
        // Fetch data immediately when the effect runs
        fetchRperfData();

        // Set up the interval for periodic fetching
        const interval = setInterval(fetchRperfData, REFRESH_INTERVAL);

        // Cleanup function to clear the interval when the component unmounts or dependencies change
        return () => clearInterval(interval);
        // Depend only on the stable fetchRperfData function now
    }, [fetchRperfData]);


    // --- REMOVED this problematic effect ---
    // useEffect(() => {
    //     setRperfData(initialData);
    //     setLoading(false);
    // }, [initialData]);
    // --- END REMOVAL ---

    const handleTimeRangeChange = (range: string) => {
        setTimeRange(range);
        const params = new URLSearchParams(searchParams.toString());
        params.set("timeRange", range);
        // Use router.replace to avoid adding unnecessary history entries for time range changes
        router.replace(`/service/${nodeId}/${serviceName}?${params.toString()}`, { scroll: false });
        // Fetch immediately on time range change
        // fetchRperfData(); // fetchRperfData will be called automatically by the useEffect dependency change
    };

    // --- Chart Data Processing (Added check for valid points) ---
    const chartData = rperfData
        .filter(point => point && typeof point.timestamp === 'string' && !isNaN(new Date(point.timestamp).getTime())) // Filter out invalid points
        .map((point) => ({
            timestamp: new Date(point.timestamp).getTime(),
            bandwidth: (point.bits_per_second ?? 0) / 1e6, // Convert to Mbps, default to 0 if null/undefined
            jitter: point.jitter_ms ?? 0, // Default to 0
            loss: point.loss_percent ?? 0,   // Default to 0
        }))
        .sort((a, b) => a.timestamp - b.timestamp); // Ensure data is sorted by time

    // --- Render Logic (minor adjustments for clarity/robustness) ---

    // Show loading skeleton only if truly loading initial data
    if (loading && rperfData.length === 0) {
        return (
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 sm:p-6 transition-colors animate-pulse">
                <div className="h-6 bg-gray-200 dark:bg-gray-700 rounded w-40 mb-4"></div>
                <div className="h-64 bg-gray-100 dark:bg-gray-700 rounded"></div>
            </div>
        );
    }

    // Show error prominently if loading failed and there's no data
    if (error && rperfData.length === 0) {
        return (
            <div className="bg-red-50 dark:bg-red-900/30 p-4 sm:p-6 rounded-lg shadow transition-colors">
                <div className="flex items-center mb-2">
                    <AlertCircle className="h-5 w-5 text-red-500 dark:text-red-400 mr-2 flex-shrink-0" />
                    <div className="text-red-600 dark:text-red-300 font-medium">
                        Error loading Rperf metrics
                    </div>
                </div>
                <p className="text-sm text-red-500 dark:text-red-400 ml-7 mb-3">{error}</p>
                <button
                    onClick={fetchRperfData} // Use the memoized fetch function
                    className="ml-7 px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-800 dark:text-gray-100 hover:bg-gray-300 dark:hover:bg-gray-600 rounded transition-colors flex items-center text-sm"
                    disabled={refreshing}
                >
                    <RefreshCw className={`mr-2 h-4 w-4 ${refreshing ? 'animate-spin': ''}`} />
                    Retry
                </button>
            </div>
        );
    }

    return (
        <div className="space-y-4 sm:space-y-6 transition-colors">
            {/* Header with Time Range and Refresh */}
            <div className="flex flex-col sm:flex-row justify-between items-center gap-2 bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                <h3 className="text-lg font-semibold text-gray-800 dark:text-gray-100">
                    Rperf Metrics ({serviceName} on {nodeId})
                </h3>
                <div className="flex items-center gap-2 flex-wrap justify-center sm:justify-end">
                    {/* Refresh Button */}
                    <button
                        onClick={fetchRperfData} // Use the memoized fetch function
                        className={`p-2 rounded-full bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600 transition-colors ${
                            refreshing ? "animate-spin" : ""
                        }`}
                        disabled={refreshing}
                        aria-label="Refresh Rperf data"
                    >
                        <RefreshCw className="h-5 w-5" />
                    </button>
                    {/* Time Range Buttons */}
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

            {/* Display error message subtly if fetch failed but we still have old data */}
            {error && rperfData.length > 0 && (
                <div className="bg-yellow-50 dark:bg-yellow-900/30 p-3 rounded-lg shadow transition-colors text-sm">
                    <div className="flex items-center">
                        <AlertCircle className="h-4 w-4 text-yellow-600 dark:text-yellow-400 mr-2 flex-shrink-0" />
                        <div className="text-yellow-700 dark:text-yellow-300">
                            Warning: Could not refresh data. Showing last available metrics. ({error})
                        </div>
                    </div>
                </div>
            )}

            {/* Charts Section */}
            {chartData.length === 0 ? (
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 sm:p-6 transition-colors">
                    <p className="text-gray-600 dark:text-gray-400 text-center py-10">
                        No rperf metrics available for the selected time range ({timeRange}).
                        {loading ? " Loading..." : " Data might be collecting."}
                    </p>
                </div>
            ) : (
                <>
                    {/* Render chart for each metric type */}
                    {["bandwidth", "jitter", "loss"].map((metricType) => {
                        const unit = metricType === "bandwidth" ? "Mbps" : metricType === "jitter" ? "ms" : "%";
                        const color =
                            metricType === "bandwidth" ? "#8884d8" : metricType === "jitter" ? "#82ca9d" : "#ff7300";

                        // Check if there's actually data for this metric type
                        const hasDataForMetric = chartData.some(d => typeof d[metricType as keyof typeof d] === 'number' && !isNaN(d[metricType as keyof typeof d]));

                        if (!hasDataForMetric) {
                            return (
                                <div key={metricType} className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 transition-colors">
                                    <h4 className="text-md font-medium mb-2 text-gray-800 dark:text-gray-100">
                                        {metricType.charAt(0).toUpperCase() + metricType.slice(1)} ({unit})
                                    </h4>
                                    <p className="text-sm text-gray-500 dark:text-gray-400 h-20 flex items-center justify-center">No data points for {metricType} in this time range.</p>
                                </div>
                            );
                        }

                        return (
                            <div
                                key={metricType}
                                className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 transition-colors"
                            >
                                <h4 className="text-md font-medium mb-2 text-gray-800 dark:text-gray-100">
                                    {metricType.charAt(0).toUpperCase() + metricType.slice(1)} ({unit})
                                </h4>
                                <div style={{ height: `${chartHeight}px` }}>
                                    <ResponsiveContainer width="100%" height="100%">
                                        <AreaChart data={chartData} margin={{ top: 5, right: 10, left: -15, bottom: 5 }}>
                                            <CartesianGrid strokeDasharray="3 3" strokeOpacity={0.3} />
                                            <XAxis
                                                dataKey="timestamp"
                                                type="number" // Timestamps are numbers
                                                domain={['dataMin', 'dataMax']} // Let Recharts determine domain
                                                tickFormatter={(ts) => new Date(ts).toLocaleTimeString()}
                                                tick={{ fontSize: 10 }}
                                                axisLine={false}
                                                tickLine={false}
                                            />
                                            <YAxis
                                                // unit={` ${unit}`} // Adding unit here can crowd the axis
                                                domain={['auto', 'auto']}
                                                tick={{ fontSize: 10 }}
                                                axisLine={false}
                                                tickLine={false}
                                                allowDecimals={true}
                                                width={40} // Give Y-axis some space
                                            />
                                            <Tooltip
                                                labelFormatter={(ts) => new Date(ts).toLocaleString()}
                                                formatter={(value: number, name: string) => [ // Explicitly type value
                                                    // Use optional chaining and nullish coalescing for safety
                                                    `${(value ?? 0).toFixed(2)} ${unit}`,
                                                    // Capitalize the metric name for the tooltip title
                                                    name.charAt(0).toUpperCase() + name.slice(1)
                                                ]}
                                                contentStyle={{
                                                    backgroundColor: 'rgba(255, 255, 255, 0.8)',
                                                    border: '1px solid #ccc',
                                                    borderRadius: '4px',
                                                    fontSize: '12px',
                                                    padding: '5px 10px'
                                                }}
                                                itemStyle={{ color: '#333' }}
                                            />
                                            {/* <Legend verticalAlign="top" height={30} wrapperStyle={{fontSize: "12px"}} /> */}
                                            <Area
                                                type="monotone"
                                                dataKey={metricType as keyof typeof chartData[0]} // Assert key type
                                                stroke={color}
                                                fill={color}
                                                fillOpacity={0.2} // Reduced opacity for better visibility
                                                name={metricType.charAt(0).toUpperCase() + metricType.slice(1)} // Use capitalized name for legend/tooltip
                                                isAnimationActive={false} // Disable animation for performance
                                                dot={false} // Hide dots for cleaner look
                                                strokeWidth={1.5} // Slightly thinner line
                                            />
                                        </AreaChart>
                                    </ResponsiveContainer>
                                </div>
                            </div>
                        );
                    })}

                    {/* Data Table Section (Optional - keep if needed) */}
                    <div className="bg-white dark:bg-gray-800 rounded-lg shadow overflow-x-auto transition-colors">
                        <h4 className="text-md font-medium p-4 text-gray-800 dark:text-gray-100">
                            Latest Data Points (Raw)
                        </h4>
                        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                            <thead className="bg-gray-50 dark:bg-gray-700">
                            <tr>
                                <th className="px-4 py-2 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">Metric</th>
                                <th className="px-4 py-2 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">Target</th>
                                <th className="px-4 py-2 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">Bandwidth (Mbps)</th>
                                <th className="px-4 py-2 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">Jitter (ms)</th>
                                <th className="px-4 py-2 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">Loss (%)</th>
                                <th className="px-4 py-2 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">Timestamp</th>
                            </tr>
                            </thead>
                            <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                            {/* Show latest 5 entries, ensure they are valid */}
                            {rperfData
                                .filter(metric => metric && metric.timestamp) // Ensure metric and timestamp exist
                                .sort((a, b) => new Date(b.timestamp).getTime() - new Date(a.timestamp).getTime()) // Sort descending by time
                                .slice(0, 5) // Take the latest 5
                                .map((metric, index) => (
                                    <tr key={index} className="hover:bg-gray-50 dark:hover:bg-gray-700/50">
                                        <td className="px-4 py-2 whitespace-nowrap text-xs text-gray-700 dark:text-gray-200">{metric.name}</td>
                                        <td className="px-4 py-2 whitespace-nowrap text-xs text-gray-700 dark:text-gray-200">{metric.target}</td>
                                        <td className="px-4 py-2 whitespace-nowrap text-xs text-gray-700 dark:text-gray-200">{( (metric.bits_per_second ?? 0) / 1e6).toFixed(2)}</td>
                                        <td className="px-4 py-2 whitespace-nowrap text-xs text-gray-700 dark:text-gray-200">{(metric.jitter_ms ?? 0).toFixed(2)}</td>
                                        <td className="px-4 py-2 whitespace-nowrap text-xs text-gray-700 dark:text-gray-200">{(metric.loss_percent ?? 0).toFixed(2)}</td>
                                        <td className="px-4 py-2 whitespace-nowrap text-xs text-gray-500 dark:text-gray-400">{new Date(metric.timestamp).toLocaleString()}</td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>
                </>
            )}
        </div>
    );
};

export default RperfDashboard;