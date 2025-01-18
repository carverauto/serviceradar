import React, { useState, useEffect } from 'react';
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts';

const NetworkSweepView = ({ nodeId, service }) => {
    const [timelineData, setTimelineData] = useState([]);
    const [selectedPort, setSelectedPort] = useState(null);

    // Get sweep details from service
    const sweepStatus = service?.details;

    useEffect(() => {
        // Only set timeline data if we have valid sweep details
        if (sweepStatus?.available_hosts !== undefined) {
            setTimelineData([{
                timestamp: Date.now(),
                value: sweepStatus.available_hosts
            }]);
        }
    }, [sweepStatus]);

    // Early return if no service or sweep details
    if (!service || !sweepStatus) {
        console.log('No sweep data available:', { service, sweepStatus });
        return <div className="bg-white rounded-lg shadow p-4">Loading sweep data...</div>;
    }

    console.log('Rendering sweep data:', sweepStatus);

    // Get port stats and sort by availability
    const portStats = sweepStatus.ports ? [...sweepStatus.ports].sort((a, b) => b.available - a.available) : [];

    return (
        <div className="bg-white rounded-lg shadow p-4">
            <div className="flex justify-between items-center mb-4">
                <div>
                    <h3 className="font-semibold">Network Sweep: {sweepStatus.network}</h3>
                    <p className="text-sm text-gray-600">
                        {sweepStatus.available_hosts} of {sweepStatus.total_hosts} hosts responding
                    </p>
                </div>
                <div className="text-sm text-gray-500">
                    Last sweep: {new Date(sweepStatus.last_sweep * 1000).toLocaleString()}
                </div>
            </div>

            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                {/* Port status grid */}
                <div className="grid grid-cols-2 gap-2">
                    {portStats.map((port) => (
                        <div
                            key={port.port}
                            className={`p-3 rounded-lg cursor-pointer transition-colors ${
                                selectedPort === port.port
                                    ? 'bg-blue-50 border border-blue-200'
                                    : 'bg-gray-50 hover:bg-gray-100'
                            }`}
                            onClick={() => setSelectedPort(port.port === selectedPort ? null : port.port)}
                        >
                            <div className="font-medium">Port {port.port}</div>
                            <div className="text-sm text-gray-600">
                                {port.available} hosts responding
                            </div>
                            <div className="mt-1 bg-gray-200 rounded-full h-2">
                                <div
                                    className="bg-blue-500 rounded-full h-2"
                                    style={{
                                        width: `${(port.available / sweepStatus.total_hosts) * 100}%`
                                    }}
                                />
                            </div>
                        </div>
                    ))}
                </div>

                {/* Timeline chart */}
                {timelineData.length > 0 && (
                    <div className="h-64">
                        <ResponsiveContainer width="100%" height="100%">
                            <LineChart data={timelineData}>
                                <CartesianGrid strokeDasharray="3 3" />
                                <XAxis
                                    dataKey="timestamp"
                                    type="number"
                                    domain={['auto', 'auto']}
                                    tickFormatter={(ts) => new Date(ts).toLocaleTimeString()}
                                />
                                <YAxis />
                                <Tooltip
                                    labelFormatter={(ts) => new Date(ts).toLocaleString()}
                                    formatter={(value) => [value + ' hosts', 'Available']}
                                />
                                <Line
                                    type="monotone"
                                    dataKey="value"
                                    stroke="#3b82f6"
                                    dot={false}
                                    name="Available Hosts"
                                />
                            </LineChart>
                        </ResponsiveContainer>
                    </div>
                )}
            </div>

            {/* Selected port details */}
            {selectedPort && (
                <div className="mt-4">
                    <h4 className="font-semibold mb-2">Port {selectedPort} Details</h4>
                    <div className="bg-gray-50 p-4 rounded">
                        {portStats.find(p => p.port === selectedPort)?.available || 0} hosts have this port open
                    </div>
                </div>
            )}
        </div>
    );
};

export default NetworkSweepView;