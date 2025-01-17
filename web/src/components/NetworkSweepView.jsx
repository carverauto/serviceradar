import React, { useState } from 'react';
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts';

const NetworkSweepView = ({ nodeId, sweepStatus }) => {
    const [selectedPort, setSelectedPort] = useState(null);

    if (!sweepStatus) return null;

    const portStats = sweepStatus.ports.sort((a, b) => b.available - a.available);

    return (
        <div className="bg-white rounded-lg shadow p-4">
            <div className="flex justify-between items-center mb-4">
                <div>
                    <h3 className="font-semibold">Network Sweep: {sweepStatus.network}</h3>
                    <p className="text-sm text-gray-600">
                        {sweepStatus.availableHosts} of {sweepStatus.totalHosts} hosts responding
                    </p>
                </div>
                <div className="text-sm text-gray-500">
                    Last sweep: {new Date(sweepStatus.lastSweep * 1000).toLocaleString()}
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
                                        width: `${(port.available / sweepStatus.totalHosts) * 100}%`
                                    }}
                                />
                            </div>
                        </div>
                    ))}
                </div>

                {/* Timeline chart */}
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
                            />
                            <Line
                                type="monotone"
                                dataKey="value"
                                stroke="#3b82f6"
                                dot={false}
                            />
                        </LineChart>
                    </ResponsiveContainer>
                </div>
            </div>

            {/* Detailed host list when a port is selected */}
            {selectedPort && (
                <div className="mt-4">
                    <h4 className="font-semibold mb-2">Hosts with Port {selectedPort} Open</h4>
                    <div className="grid grid-cols-2 md:grid-cols-4 gap-2">
                        {hostList.map((host) => (
                            <div key={host.ip} className="text-sm bg-gray-50 p-2 rounded">
                                {host.ip}
                                <span className="text-gray-500 text-xs block">
                                    {host.responseTime}ms
                                </span>
                            </div>
                        ))}
                    </div>
                </div>
            )}
        </div>
    );
};

export default NetworkSweepView;