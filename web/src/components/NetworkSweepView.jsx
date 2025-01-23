import React, { useState, useEffect } from 'react';
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts';

// Host details subcomponent
const HostDetailsView = ({ host }) => {
    return (
        <div className="bg-white p-4 rounded-lg shadow">
            <div className="flex justify-between items-center">
                <h4 className="text-lg font-semibold">{host.host}</h4>
                <span className={`px-2 py-1 rounded ${
                    host.available ? 'bg-green-100 text-green-800' : 'bg-red-100 text-red-800'
                }`}>
                    {host.available ? 'Online' : 'Offline'}
                </span>
            </div>

            {/* ICMP Status */}
            {host.icmp_status && (
                <div className="mt-2">
                    <h5 className="font-medium">ICMP Status</h5>
                    <div className="ml-4 text-sm">
                        <div>Response Time: {(host.icmp_status.round_trip / 1e6).toFixed(2)}ms</div>
                        {host.icmp_status.packet_loss > 0 && (
                            <div>Packet Loss: {host.icmp_status.packet_loss.toFixed(1)}%</div>
                        )}
                    </div>
                </div>
            )}

            {/* Port Results */}
            {host.port_results && host.port_results.length > 0 && (
                <div className="mt-2">
                    <h5 className="font-medium">Open Ports</h5>
                    <div className="ml-4 grid grid-cols-2 gap-2 mt-1">
                        {host.port_results
                            .filter(port => port.available)
                            .map(port => (
                                <div
                                    key={port.port}
                                    className="text-sm bg-gray-50 p-2 rounded"
                                >
                                    <span className="font-medium">Port {port.port}</span>
                                    {port.service && (
                                        <span className="text-gray-600 ml-1">({port.service})</span>
                                    )}
                                    <div className="text-gray-500 text-xs">
                                        {(port.response_time / 1e6).toFixed(2)}ms
                                    </div>
                                </div>
                            ))
                        }
                    </div>
                </div>
            )}

            <div className="mt-2 text-xs text-gray-500">
                First seen: {new Date(host.first_seen).toLocaleString()}
                <br />
                Last seen: {new Date(host.last_seen).toLocaleString()}
            </div>
        </div>
    );
};

const NetworkSweepView = ({ nodeId, service }) => {
    const [timelineData, setTimelineData] = useState([]);
    const [selectedPort, setSelectedPort] = useState(null);
    const [viewMode, setViewMode] = useState('summary');
    const [searchTerm, setSearchTerm] = useState('');
    const [showOffline, setShowOffline] = useState(false);

    // Get sweep details from service
    const sweepDetails = service?.details;

    useEffect(() => {
        console.log('Sweep details:', sweepDetails);
        if (sweepDetails?.available_hosts !== undefined) {
            setTimelineData([{
                timestamp: Date.now(),
                value: sweepDetails.available_hosts
            }]);
        }
    }, [sweepDetails]);

    if (!service || !sweepDetails) {
        console.log('No sweep data available:', { service, sweepDetails });
        return <div className="bg-white rounded-lg shadow p-4">Loading sweep data...</div>;
    }

    const portStats = sweepDetails.ports?.sort((a, b) => b.available - a.available) || [];
    const hosts = sweepDetails.hosts || [];

    const sortHosts = (hosts) => {
        return hosts.sort((a, b) => {
            // Extract the last octet from IP addresses
            const aMatch = a.host.match(/(\d+)$/);
            const bMatch = b.host.match(/(\d+)$/);

            if (aMatch && bMatch) {
                return parseInt(aMatch[1]) - parseInt(bMatch[1]);
            }
            return a.host.localeCompare(b.host);
        });
    };

    // Convert sweepDetails.hosts to array and sort
    const sortedHosts = sweepDetails?.hosts ? sortHosts([...sweepDetails.hosts]) : [];

    // Filter hosts based on search term and online status
    const filteredHosts = sortedHosts.filter(host =>
        (showOffline || host.available) &&
        host.host.toLowerCase().includes(searchTerm.toLowerCase())
    );

    return (
        <div className="space-y-4">
            {/* Control Header */}
            <div className="bg-white rounded-lg shadow p-4">
                <div className="flex justify-between items-center mb-4">
                    <div>
                        <h3 className="text-lg font-semibold">Network Sweep: {sweepDetails.network}</h3>
                        <p className="text-sm text-gray-600">
                            {sweepDetails.available_hosts} of {sweepDetails.total_hosts} hosts responding
                        </p>
                    </div>
                    <div className="space-x-2 flex items-center">
                        <button
                            onClick={() => setViewMode('summary')}
                            className={`px-3 py-1 rounded ${
                                viewMode === 'summary' ? 'bg-blue-500 text-white' : 'bg-gray-100'
                            }`}
                        >
                            Summary
                        </button>
                        <button
                            onClick={() => setViewMode('hosts')}
                            className={`px-3 py-1 rounded ${
                                viewMode === 'hosts' ? 'bg-blue-500 text-white' : 'bg-gray-100'
                            }`}
                        >
                            Host Details
                        </button>
                    </div>
                </div>

                {viewMode === 'hosts' && (
                    <div className="mt-2 space-y-2">
                        <div className="flex items-center space-x-4">
                            <input
                                type="text"
                                placeholder="Search hosts..."
                                className="flex-1 p-2 border rounded"
                                value={searchTerm}
                                onChange={(e) => setSearchTerm(e.target.value)}
                            />
                            <label className="flex items-center space-x-2">
                                <input
                                    type="checkbox"
                                    checked={showOffline}
                                    onChange={(e) => setShowOffline(e.target.checked)}
                                    className="form-checkbox"
                                />
                                <span className="text-sm">Show Offline Hosts</span>
                            </label>
                        </div>
                    </div>
                )}

                <div className="text-sm text-gray-500 mt-2">
                    Last sweep: {new Date(sweepDetails.last_sweep * 1000).toLocaleString()}
                </div>
            </div>

            {/* Summary View */}
            {viewMode === 'summary' && (
                <div className="bg-white rounded-lg shadow p-4">
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
                                                width: `${(port.available / sweepDetails.total_hosts) * 100}%`
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
                </div>
            )}

            {/* Host Details View */}
            {viewMode === 'hosts' && (
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    {filteredHosts
                        .map(host => (
                            <HostDetailsView key={host.host} host={host} />
                        ))
                    }
                </div>
            )}
        </div>
    );
};

export default NetworkSweepView;