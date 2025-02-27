import React, {useCallback, useEffect, useRef, useState} from 'react';
import {CartesianGrid, Legend, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis} from 'recharts';

const SNMPDashboard = ({ nodeId, serviceName }) => {
    const [snmpData, setSNMPData] = useState([]);
    const [processedData, setProcessedData] = useState([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState(null);
    const [timeRange, setTimeRange] = useState('1h');
    const [selectedMetric, setSelectedMetric] = useState(null);
    const [availableMetrics, setAvailableMetrics] = useState([]);

    // Use refs to prevent state updates during render cycles
    const dataRef = useRef(snmpData);
    const fetchingRef = useRef(false);
    const timerId = useRef(null);

    // Process SNMP counter data to show rates instead of raw values
    const processCounterData = useCallback((data) => {
        if (!data || data.length < 2) return data || [];

        try {
            // Process the data points to calculate rates
            return data.map((point, index) => {
                if (index === 0) return {...point, rate: 0};

                const prevPoint = data[index - 1];
                const timeDiff = (new Date(point.timestamp) - new Date(prevPoint.timestamp)) / 1000;

                // Safely parse values
                const currentValue = parseFloat(point.value) || 0;
                const prevValue = parseFloat(prevPoint.value) || 0;

                // Handle counter wrapping
                let rate = 0;
                if (currentValue >= prevValue) {
                    rate = (currentValue - prevValue) / timeDiff;
                } else {
                    // Counter wrapped, assume 32-bit counter
                    rate = ((4294967295 - prevValue) + currentValue) / timeDiff;
                }

                return {
                    ...point,
                    rate: rate
                };
            });
        } catch (error) {
            console.error("Error processing counter data:", error);
            return data;
        }
    }, []);

    // The main data fetching function - separated to avoid re-creation on every render
    const fetchSNMPData = useCallback(async () => {
        // Prevent concurrent fetches
        if (fetchingRef.current) return;
        fetchingRef.current = true;

        try {
            // Only show loading on initial fetch
            if (!dataRef.current.length) {
                setLoading(true);
            }

            const end = new Date();
            const start = new Date();

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

            // Directly use fetch to avoid any potential issues with the cache
            const response = await fetch(
                `/api/nodes/${nodeId}/snmp?start=${start.toISOString()}&end=${end.toISOString()}`,
                {
                    headers: {
                        'X-API-Key': process.env.NEXT_PUBLIC_API_KEY || '',
                        'Cache-Control': 'no-cache'
                    },
                    cache: 'no-store'
                }
            );

            if (!response.ok) {
                throw new Error(`Server returned ${response.status} ${response.statusText}`);
            }

            const data = await response.json();

            // Handle empty or invalid data
            if (!data || !Array.isArray(data)) {
                console.warn("Received invalid SNMP data format");
                fetchingRef.current = false;
                return;
            }

            // Don't update state if component is unmounting or not mounted
            if (!dataRef.current) return;

            // Extract unique OID names
            const metrics = [...new Set(data.map(item => item.oid_name))];

            // Update our state safely
            setSNMPData(data);
            dataRef.current = data;
            setAvailableMetrics(metrics);

            if (!selectedMetric && metrics.length > 0) {
                setSelectedMetric(metrics[0]);
            }

            setLoading(false);
            setError(null);
        } catch (err) {
            console.error('Error fetching SNMP data:', err);

            // Only show error if we don't have any data yet
            if (!dataRef.current.length) {
                setError(err.message || "Failed to fetch SNMP data");
                setLoading(false);
            }
        } finally {
            fetchingRef.current = false;
        }
    }, [nodeId, timeRange, selectedMetric]);

    // Initial data load
    useEffect(() => {
        // Reset state when parameters change
        setSNMPData([]);
        dataRef.current = [];
        setLoading(true);
        setError(null);

        fetchSNMPData().catch(err => console.error("Initial fetch error:", err));

        return () => {
            // Clear any pending timers on unmount
            if (timerId.current) clearTimeout(timerId.current);
        };
    }, [fetchSNMPData, nodeId, timeRange]);

    // Set up polling - in a separate effect to avoid interfering with data fetching
    useEffect(() => {
        const pollInterval = 30000; // 30 seconds

        // Set up polling with manual setTimeout instead of setInterval
        const pollData = () => {
            fetchSNMPData()
                .catch(err => console.error("Poll error:", err))
                .finally(() => {
                    // Only schedule next poll if component is still mounted
                    if (dataRef.current !== null) {
                        timerId.current = setTimeout(pollData, pollInterval);
                    }
                });
        };

        // Start polling
        timerId.current = setTimeout(pollData, pollInterval);

        // Clean up on unmount
        return () => {
            dataRef.current = null; // Signal that we're unmounting
            if (timerId.current) clearTimeout(timerId.current);
        };
    }, [fetchSNMPData]);

    // Process metric data when selected metric changes
    useEffect(() => {
        if (snmpData.length > 0 && selectedMetric) {
            try {
                const metricData = snmpData.filter(item => item.oid_name === selectedMetric);
                const processed = processCounterData(metricData);
                setProcessedData(processed);
            } catch (err) {
                console.error('Error processing metric data:', err);
            }
        }
    }, [selectedMetric, snmpData, processCounterData]);

    const formatRate = (rate) => {
        if (rate === undefined || rate === null || isNaN(rate)) return "N/A";

        const absRate = Math.abs(rate);
        if (absRate >= 1000000000) {
            return `${(rate / 1000000000).toFixed(2)} GB/s`;
        } else if (absRate >= 1000000) {
            return `${(rate / 1000000).toFixed(2)} MB/s`;
        } else if (absRate >= 1000) {
            return `${(rate / 1000).toFixed(2)} KB/s`;
        } else {
            return `${rate.toFixed(2)} B/s`;
        }
    };

    // Error state
    if (error) {
        return (
            <div className="bg-red-50 dark:bg-red-900 p-6 rounded-lg text-red-600 dark:text-red-200">
                <h3 className="font-bold mb-2">Error Loading SNMP Data</h3>
                <p>{error}</p>
                <button
                    onClick={() => {
                        setError(null);
                        setLoading(true);
                        fetchSNMPData().catch(err => {
                            setError(err.message);
                            setLoading(false);
                        });
                    }}
                    className="mt-4 px-4 py-2 bg-red-100 dark:bg-red-800 text-red-800 dark:text-red-100 rounded hover:bg-red-200 dark:hover:bg-red-700"
                >
                    Retry
                </button>
            </div>
        );
    }

    // Loading state
    if (loading) {
        return (
            <div className="flex justify-center items-center h-64">
                <div className="text-lg text-gray-800 dark:text-gray-100">
                    Loading SNMP data...
                </div>
            </div>
        );
    }

    // Empty data state
    if (!processedData.length) {
        return (
            <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
                <h3 className="text-lg font-semibold mb-4 text-gray-800 dark:text-gray-200">
                    No SNMP Data Available
                </h3>
                <p className="text-gray-600 dark:text-gray-400">
                    No metrics found for the selected time range and OID.
                </p>
                <div className="mt-4">
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
                        Select Time Range
                    </label>
                    <div className="flex gap-2">
                        {['1h', '6h', '24h'].map((range) => (
                            <button
                                key={range}
                                onClick={() => setTimeRange(range)}
                                className={`px-3 py-1 rounded transition-colors ${
                                    timeRange === range
                                        ? 'bg-blue-500 text-white'
                                        : 'bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-100'
                                }`}
                            >
                                {range}
                            </button>
                        ))}
                    </div>
                </div>
            </div>
        );
    }

    return (
        <div className="space-y-6">
            {/* Controls */}
            <div className="flex justify-between items-center bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                <div className="flex gap-4">
                    <select
                        value={selectedMetric || ''}
                        onChange={(e) => setSelectedMetric(e.target.value)}
                        className="px-3 py-2 border rounded text-gray-800 dark:text-gray-200
                     dark:bg-gray-700 dark:border-gray-600"
                    >
                        {availableMetrics.map(metric => (
                            <option key={metric} value={metric}>
                                {metric}
                            </option>
                        ))}
                    </select>
                    <div className="flex gap-2">
                        {['1h', '6h', '24h'].map((range) => (
                            <button
                                key={range}
                                onClick={() => setTimeRange(range)}
                                className={`px-3 py-1 rounded transition-colors ${
                                    timeRange === range
                                        ? 'bg-blue-500 text-white'
                                        : 'bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-100'
                                }`}
                            >
                                {range}
                            </button>
                        ))}
                    </div>
                </div>
            </div>

            {/* Chart */}
            {processedData.length > 0 && (
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4">
                    <div className="h-96">
                        <ResponsiveContainer width="100%" height="100%">
                            <LineChart data={processedData}>
                                <CartesianGrid strokeDasharray="3 3" />
                                <XAxis
                                    dataKey="timestamp"
                                    tickFormatter={(ts) => new Date(ts).toLocaleTimeString()}
                                />
                                <YAxis
                                    tickFormatter={(value) => formatRate(value)}
                                    domain={['auto', 'auto']}
                                    scale="linear"
                                />
                                <Tooltip
                                    labelFormatter={(ts) => new Date(ts).toLocaleString()}
                                    formatter={(value, name) => [
                                        formatRate(value),
                                        name === 'rate' ? 'Transfer Rate' : name
                                    ]}
                                />
                                <Legend />
                                <Line
                                    type="monotone"
                                    dataKey="rate"
                                    stroke="#8884d8"
                                    dot={false}
                                    name="Transfer Rate"
                                    isAnimationActive={false}
                                />
                            </LineChart>
                        </ResponsiveContainer>
                    </div>
                </div>
            )}

            {/* Latest Values Table */}
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow overflow-hidden">
                <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                    <thead className="bg-gray-50 dark:bg-gray-700">
                    <tr>
                        <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                            Metric Name
                        </th>
                        <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                            Current Rate
                        </th>
                        <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                            Last Update
                        </th>
                    </tr>
                    </thead>
                    <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                    {availableMetrics.map(metric => {
                        try {
                            const metricData = processCounterData(
                                snmpData.filter(item => item.oid_name === metric)
                            );

                            if (!metricData || !metricData.length) return null;

                            const latestDataPoint = metricData[metricData.length - 1];

                            return latestDataPoint ? (
                                <tr key={metric}>
                                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-800 dark:text-gray-200">
                                        {metric}
                                    </td>
                                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-800 dark:text-gray-200">
                                        {formatRate(latestDataPoint.rate)}
                                    </td>
                                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-800 dark:text-gray-200">
                                        {new Date(latestDataPoint.timestamp).toLocaleString()}
                                    </td>
                                </tr>
                            ) : null;
                        } catch (err) {
                            console.error(`Error processing metric ${metric}:`, err);
                            return null;
                        }
                    })}
                    </tbody>
                </table>
            </div>
        </div>
    );
};

export default SNMPDashboard;