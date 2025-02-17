import React, { useState, useEffect } from 'react';
import {
    LineChart, Line, XAxis, YAxis, CartesianGrid,
    Tooltip, Legend, ResponsiveContainer
} from 'recharts';

const SNMPDashboard = ({ nodeId, serviceName }) => {
    const [snmpData, setSNMPData] = useState([]);
    const [processedData, setProcessedData] = useState([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState(null);
    const [timeRange, setTimeRange] = useState('1h');
    const [selectedMetric, setSelectedMetric] = useState(null);
    const [availableMetrics, setAvailableMetrics] = useState([]);

    // Calculate rate between two counter values
    const calculateRate = (current, previous, timeDiff) => {
        if (!previous || !current || timeDiff <= 0) return 0;
        const valueDiff = current - previous;
        // Convert to per-second rate
        return valueDiff / timeDiff;
    };

    // Process SNMP counter data to show rates instead of raw values
    const processCounterData = (data) => {
        if (!data || data.length < 2) return data;

        // Process the data points to calculate rates
        const processedData = data.map((point, index) => {
            if (index === 0) return { ...point, rate: 0 };

            const prevPoint = data[index - 1];
            const timeDiff = (new Date(point.timestamp) - new Date(prevPoint.timestamp)) / 1000;
            const currentValue = parseFloat(point.value);
            const prevValue = parseFloat(prevPoint.value);

            // Handle counter wrapping
            let rate = 0;
            if (currentValue >= prevValue) {
                rate = (currentValue - prevValue) / timeDiff;
            } else {
                // Counter wrapped, assume 32-bit counter
                rate = ((4294967295 - prevValue) + currentValue) / timeDiff;
            }

            // Convert to bytes/sec if dealing with network interfaces
            if (point.oid_name.toLowerCase().includes('octets')) {
                rate = rate;  // Already in bytes/sec
            }

            return {
                ...point,
                rate: rate
            };
        });

        // Filter out anomalous spikes
        const rates = processedData.map(d => d.rate).filter(r => !isNaN(r) && isFinite(r));
        const mean = rates.reduce((a, b) => a + b, 0) / rates.length;
        const stdDev = Math.sqrt(rates.reduce((a, b) => a + Math.pow(b - mean, 2), 0) / rates.length);
        const threshold = mean + (3 * stdDev); // 3 standard deviations

        return processedData.map(point => ({
            ...point,
            rate: point.rate > threshold ? mean : point.rate
        }));
    };

    useEffect(() => {
        const fetchSNMPData = async () => {
            try {
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

                const response = await fetch(
                    `/api/nodes/${nodeId}/snmp?start=${start.toISOString()}&end=${end.toISOString()}`
                );

                if (!response.ok) {
                    throw new Error('Failed to fetch SNMP data');
                }

                const data = await response.json();
                console.log('Fetched SNMP data:', data);

                // Extract unique OID names
                const metrics = [...new Set(data.map(item => item.oid_name))];
                setAvailableMetrics(metrics);

                if (!selectedMetric && metrics.length > 0) {
                    setSelectedMetric(metrics[0]);
                }

                setSNMPData(data);

                // Process the data for the selected metric
                const metricData = data.filter(item => item.oid_name === selectedMetric);
                const processed = processCounterData(metricData);
                setProcessedData(processed);

                setLoading(false);
            } catch (err) {
                console.error('Error fetching SNMP data:', err);
                setError(err.message);
                setLoading(false);
            }
        };

        fetchSNMPData();
        const interval = setInterval(fetchSNMPData, 10000);
        return () => clearInterval(interval);
    }, [nodeId, timeRange, serviceName, selectedMetric]);

    useEffect(() => {
        if (snmpData.length > 0 && selectedMetric) {
            const metricData = snmpData.filter(item => item.oid_name === selectedMetric);
            const processed = processCounterData(metricData);
            setProcessedData(processed);
        }
    }, [selectedMetric, snmpData]);

    const formatRate = (rate) => {
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

    // Rest of your component code remains the same until the chart rendering
    if (loading) {
        return (
            <div className="flex justify-center items-center h-64">
                <div className="text-lg text-gray-800 dark:text-gray-100">
                    Loading SNMP data...
                </div>
            </div>
        );
    }

    if (error) {
        return (
            <div className="flex justify-center items-center h-64">
                <div className="text-red-500 dark:text-red-400 text-lg">
                    Error: {error}
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
                        const metricData = processCounterData(
                            snmpData.filter(item => item.oid_name === metric)
                        );
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
                    })}
                    </tbody>
                </table>
            </div>
        </div>
    );
};

export default SNMPDashboard;