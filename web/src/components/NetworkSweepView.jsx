import React, { useState, useEffect } from 'react';
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts';
import ExportButton from './ExportButton';

// Host details subcomponent
const HostDetailsView = ({ host }) => (
    <div className="bg-white p-4 rounded-lg shadow">
        <div className="flex justify-between items-center">
            <h4 className="text-lg font-semibold">{host.host}</h4>
            <span className={`px-2 py-1 rounded ${
                host.available ? 'bg-green-100 text-green-800' : 'bg-red-100 text-red-800'
            }`}>
                {host.available ? 'Online' : 'Offline'}
            </span>
        </div>

        {/* Port Results */}
        {host.port_results?.length > 0 && (
            <div className="mt-4">
                <h5 className="font-medium">Open Ports</h5>
                <div className="grid grid-cols-2 gap-2 mt-2">
                    {host.port_results
                        .filter(port => port.available)
                        .map(port => (
                            <div key={port.port} className="text-sm bg-gray-50 p-2 rounded">
                                <span className="font-medium">Port {port.port}</span>
                                {port.service && (
                                    <span className="text-gray-600 ml-1">({port.service})</span>
                                )}
                            </div>
                        ))
                    }
                </div>
            </div>
        )}

        <div className="mt-4 text-xs text-gray-500">
            <div>First seen: {new Date(host.first_seen).toLocaleString()}</div>
            <div>Last seen: {new Date(host.last_seen).toLocaleString()}</div>
        </div>
    </div>
);

const NetworkSweepView = ({ nodeId, service, standalone = false }) => {
    const [viewMode, setViewMode] = useState('summary');
    const [searchTerm, setSearchTerm] = useState('');
    const [showOffline, setShowOffline] = useState(false);

    // Parse sweep details from service
    const sweepDetails = typeof service.details === 'string'
        ? JSON.parse(service.details)
        : service.details;

    // Sort hosts by IP
    const sortHosts = (hosts) => {
        return [...hosts].sort((a, b) => {
            const aMatch = a.host.match(/(\d+)$/);
            const bMatch = b.host.match(/(\d+)$/);
            if (aMatch && bMatch) {
                return parseInt(aMatch[1]) - parseInt(bMatch[1]);
            }
            return a.host.localeCompare(b.host);
        });
    };

    // Filter and sort hosts
    const filteredHosts = sweepDetails.hosts
        ? sortHosts(sweepDetails.hosts).filter(host =>
            (showOffline || host.available) &&
            host.host.toLowerCase().includes(searchTerm.toLowerCase())
        )
        : [];

    return (
        <div className={`space-y-4 ${!standalone && 'bg-white rounded-lg shadow p-4'}`}>
            {/* Header */}
            <div className={`${standalone ? 'bg-white rounded-lg shadow p-4' : ''}`}>
                <div className="flex justify-between items-center mb-4">
                    <div>
                        <h3 className="text-lg font-semibold">Network Sweep: {sweepDetails.network}</h3>
                        <p className="text-sm text-gray-600">
                            {sweepDetails.available_hosts} of {sweepDetails.total_hosts} hosts responding
                        </p>
                    </div>
                    <div className="flex items-center gap-4">
                        <div className="space-x-2">
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
                        <ExportButton sweepDetails={sweepDetails} />
                    </div>
                </div>

                {viewMode === 'hosts' && (
                    <div className="flex items-center gap-4 mt-4">
                        <input
                            type="text"
                            placeholder="Search hosts..."
                            className="flex-1 p-2 border rounded"
                            value={searchTerm}
                            onChange={(e) => setSearchTerm(e.target.value)}
                        />
                        <label className="flex items-center gap-2">
                            <input
                                type="checkbox"
                                checked={showOffline}
                                onChange={(e) => setShowOffline(e.target.checked)}
                                className="form-checkbox"
                            />
                            <span className="text-sm">Show Offline Hosts</span>
                        </label>
                    </div>
                )}

                <div className="text-sm text-gray-500 mt-2">
                    Last sweep: {new Date(sweepDetails.last_sweep * 1000).toLocaleString()}
                </div>
            </div>

            {/* Views */}
            {viewMode === 'summary' ? (
                <div className={`${standalone ? 'bg-white rounded-lg shadow p-4' : ''}`}>
                    <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
                        {sweepDetails.ports
                            ?.sort((a, b) => b.available - a.available)
                            .map(port => (
                                <div key={port.port} className="bg-gray-50 p-3 rounded">
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
                            ))
                        }
                    </div>
                </div>
            ) : (
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    {filteredHosts.map(host => (
                        <HostDetailsView key={host.host} host={host} />
                    ))}
                </div>
            )}
        </div>
    );
};

export default NetworkSweepView;