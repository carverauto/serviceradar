import React, { useState, useEffect } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer } from 'recharts';

const ServiceDashboard = () => {
    const { nodeId, serviceName } = useParams();
    const navigate = useNavigate();
    const [serviceData, setServiceData] = useState(null);
    const [metricsData, setMetricsData] = useState([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState(null);
    const [selectedTimeRange, setSelectedTimeRange] = useState('1h');

    useEffect(() => {
        const fetchData = async () => {
            try {
                // Fetch nodes list for service details
                const nodesResponse = await fetch('/api/nodes');
                if (!nodesResponse.ok) throw new Error('Failed to fetch nodes');
                const nodes = await nodesResponse.json();

                // Find the specific node
                const node = nodes.find(n => n.node_id === nodeId);
                if (!node) {
                    throw new Error('Node not found');
                }

                // Find the specific service
                const service = node.services?.find(s => s.name === serviceName);
                if (!service) {
                    throw new Error('Service not found');
                }

                setServiceData(service);

                // Fetch metrics data
                const metricsResponse = await fetch(`/api/nodes/${nodeId}/metrics`);
                if (metricsResponse.ok) {
                    const metrics = await metricsResponse.json();
                    const serviceMetrics = metrics.filter(m => m.service_name === serviceName);
                    setMetricsData(serviceMetrics);
                }

                setLoading(false);
            } catch (err) {
                console.error('Error fetching data:', err);
                setError(err.message);
                setLoading(false);
            }
        };

        fetchData();
        const interval = setInterval(fetchData, 10000);
        return () => clearInterval(interval);
    }, [nodeId, serviceName]);

    const filterDataByTimeRange = (data, range) => {
        const now = Date.now();
        const ranges = {
            '1h': 60 * 60 * 1000,
            '6h': 6 * 60 * 60 * 1000,
            '24h': 24 * 60 * 60 * 1000
        };

        const timeLimit = now - ranges[range];
        return data.filter(point => new Date(point.timestamp).getTime() >= timeLimit);
    };

    const renderMetricsChart = () => {
        if (!metricsData.length) return null;

        // Convert metrics data for the chart and filter by time range
        const chartData = filterDataByTimeRange(
            metricsData.map(metric => ({
                timestamp: new Date(metric.timestamp).getTime(),
                response_time: metric.response_time / 1000000, // Convert to milliseconds
            })),
            selectedTimeRange
        );

        return (
            <div className="bg-white rounded-lg shadow p-6">
                <div className="flex justify-between items-center mb-4">
                    <h3 className="text-lg font-semibold">Response Time</h3>
                    <div className="flex gap-2">
                        {['1h', '6h', '24h'].map(range => (
                            <button
                                key={range}
                                onClick={() => setSelectedTimeRange(range)}
                                className={`px-3 py-1 rounded ${
                                    selectedTimeRange === range
                                        ? 'bg-blue-500 text-white'
                                        : 'bg-gray-100'
                                }`}
                            >
                                {range}
                            </button>
                        ))}
                    </div>
                </div>
                <div className="h-64">
                    <ResponsiveContainer width="100%" height="100%">
                        <LineChart data={chartData}>
                            <CartesianGrid strokeDasharray="3 3" />
                            <XAxis
                                dataKey="timestamp"
                                type="number"
                                domain={['auto', 'auto']}
                                tickFormatter={(ts) => new Date(ts).toLocaleTimeString()}
                            />
                            <YAxis
                                unit="ms"
                                domain={['auto', 'auto']}
                            />
                            <Tooltip
                                labelFormatter={(ts) => new Date(ts).toLocaleString()}
                                formatter={(value) => [`${value.toFixed(2)} ms`, 'Response Time']}
                            />
                            <Legend />
                            <Line
                                type="monotone"
                                dataKey="response_time"
                                stroke="#8884d8"
                                dot={false}
                                name="Response Time"
                            />
                        </LineChart>
                    </ResponsiveContainer>
                </div>
            </div>
        );
    };

    const renderServiceDetails = () => {
        if (!serviceData?.details) return null;

        let details;
        try {
            details = typeof serviceData.details === 'string'
                ? JSON.parse(serviceData.details)
                : serviceData.details;

            // Handle special case for sweep service
            if (serviceData.type === 'sweep' && details.hosts) {
                return (
                    <div className="bg-white rounded-lg shadow p-6">
                        <h3 className="text-lg font-semibold mb-4">Network Sweep Results</h3>
                        <div className="grid grid-cols-2 gap-4 mb-4">
                            <div>
                                <h4 className="font-medium">Network</h4>
                                <p>{details.network || 'N/A'}</p>
                            </div>
                            <div>
                                <h4 className="font-medium">Total Hosts</h4>
                                <p>{details.total_hosts || 0}</p>
                            </div>
                            <div>
                                <h4 className="font-medium">Available Hosts</h4>
                                <p>{details.available_hosts || 0}</p>
                            </div>
                            <div>
                                <h4 className="font-medium">Last Sweep</h4>
                                <p>{new Date(details.last_sweep * 1000).toLocaleString()}</p>
                            </div>
                        </div>

                        {details.ports && details.ports.length > 0 && (
                            <div className="mt-6">
                                <h4 className="font-medium mb-2">Port Status</h4>
                                <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
                                    {details.ports.map(port => (
                                        <div key={port.port} className="bg-gray-50 p-3 rounded">
                                            <div className="font-medium">Port {port.port}</div>
                                            <div className="text-sm text-gray-600">
                                                {port.available} hosts responding
                                            </div>
                                            <div className="mt-1 bg-gray-200 rounded-full h-2">
                                                <div
                                                    className="bg-blue-500 rounded-full h-2"
                                                    style={{
                                                        width: `${(port.available / details.total_hosts) * 100}%`
                                                    }}
                                                />
                                            </div>
                                        </div>
                                    ))}
                                </div>
                            </div>
                        )}

                        {details.hosts && details.hosts.length > 0 && (
                            <div className="mt-6">
                                <h4 className="font-medium mb-2">Host Details</h4>
                                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                                    {details.hosts
                                        .filter(host => host.available)
                                        .map(host => (
                                            <div key={host.host} className="bg-gray-50 p-4 rounded">
                                                <div className="flex justify-between items-center mb-2">
                                                    <span className="font-medium">{host.host}</span>
                                                    <span className={`px-2 py-1 text-sm rounded ${
                                                        host.available
                                                            ? 'bg-green-100 text-green-800'
                                                            : 'bg-red-100 text-red-800'
                                                    }`}>
                                                        {host.available ? 'Online' : 'Offline'}
                                                    </span>
                                                </div>
                                                {host.port_results && (
                                                    <div className="mt-2">
                                                        <div className="text-sm font-medium">Open Ports</div>
                                                        <div className="flex flex-wrap gap-2 mt-1">
                                                            {host.port_results
                                                                .filter(port => port.available)
                                                                .map(port => (
                                                                    <span
                                                                        key={port.port}
                                                                        className="px-2 py-1 bg-gray-200 rounded text-sm"
                                                                    >
                                                                        {port.port}
                                                                    </span>
                                                                ))
                                                            }
                                                        </div>
                                                    </div>
                                                )}
                                            </div>
                                        ))
                                    }
                                </div>
                            </div>
                        )}
                    </div>
                );
            }
        } catch (e) {
            console.error('Error parsing service details:', e);
            return null;
        }

        // If the service has history data, create a separate visualization
        if (details.history) {
            const historyData = details.history;
            const chartKeys = Object.keys(historyData[0] || {}).filter(key => key !== 'timestamp');

            return (
                <>
                    {/* Service-specific metrics */}
                    <div className="bg-white rounded-lg shadow p-6">
                        <h3 className="text-lg font-semibold mb-4">Service Metrics</h3>
                        <div className="h-64">
                            <ResponsiveContainer width="100%" height="100%">
                                <LineChart data={historyData}>
                                    <CartesianGrid strokeDasharray="3 3" />
                                    <XAxis
                                        dataKey="timestamp"
                                        tickFormatter={(ts) => new Date(ts).toLocaleTimeString()}
                                    />
                                    <YAxis />
                                    <Tooltip
                                        labelFormatter={(ts) => new Date(ts).toLocaleString()}
                                    />
                                    <Legend />
                                    {chartKeys.map((key, index) => (
                                        <Line
                                            key={key}
                                            type="monotone"
                                            dataKey={key}
                                            stroke={`hsl(${index * 137.508}, 70%, 50%)`}
                                            dot={false}
                                            name={key.split('_').map(word =>
                                                word.charAt(0).toUpperCase() + word.slice(1)
                                            ).join(' ')}
                                        />
                                    ))}
                                </LineChart>
                            </ResponsiveContainer>
                        </div>
                    </div>

                    {/* Service-specific status details */}
                    <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                        {Object.entries(details)
                            .filter(([key]) => key !== 'history')
                            .map(([key, value]) => (
                                <div key={key} className="bg-white rounded-lg shadow p-6">
                                    <h3 className="text-lg font-semibold mb-2">
                                        {key.split('_').map(word =>
                                            word.charAt(0).toUpperCase() + word.slice(1)
                                        ).join(' ')}
                                    </h3>
                                    <div className="text-lg break-all">
                                        {typeof value === 'boolean'
                                            ? (value ? 'Yes' : 'No')
                                            : value}
                                    </div>
                                </div>
                            ))}
                    </div>
                </>
            );
        }

        // For services without history data, just show the details
        return (
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                {Object.entries(details).map(([key, value]) => (
                    <div key={key} className="bg-white rounded-lg shadow p-6">
                        <h3 className="text-lg font-semibold mb-2">
                            {key.split('_').map(word =>
                                word.charAt(0).toUpperCase() + word.slice(1)
                            ).join(' ')}
                        </h3>
                        <div className="text-lg break-all">
                            {typeof value === 'boolean'
                                ? (value ? 'Yes' : 'No')
                                : value}
                        </div>
                    </div>
                ))}
            </div>
        );
    };

    if (loading) {
        return (
            <div className="flex justify-center items-center h-64">
                <div className="text-lg">Loading...</div>
            </div>
        );
    }

    if (error) {
        return (
            <div className="flex justify-center items-center h-64">
                <div className="text-red-500 text-lg">{error}</div>
            </div>
        );
    }

    return (
        <div className="space-y-6">
            {/* Header */}
            <div className="flex justify-between items-center">
                <h2 className="text-2xl font-bold">
                    {serviceName} Service Status
                </h2>
                <button
                    onClick={() => navigate('/nodes')}
                    className="px-4 py-2 bg-gray-100 hover:bg-gray-200 rounded"
                >
                    Back to Nodes
                </button>
            </div>

            {/* Main Status */}
            <div className="bg-white rounded-lg shadow p-6">
                <div className="flex items-center justify-between">
                    <h3 className="text-lg font-semibold">Service Status</h3>
                    <div className={`px-3 py-1 rounded ${
                        serviceData?.available
                            ? 'bg-green-100 text-green-800'
                            : 'bg-red-100 text-red-800'
                    }`}>
                        {serviceData?.available ? 'Online' : 'Offline'}
                    </div>
                </div>
            </div>

            {/* Response Time Metrics */}
            {renderMetricsChart()}

            {/* Service-specific Details and Metrics */}
            {renderServiceDetails()}
        </div>
    );
};

export default ServiceDashboard;