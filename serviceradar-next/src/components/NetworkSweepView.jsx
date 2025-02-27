import { useState } from 'react';
import ExportButton from './ExportButton';

const compareIPAddresses = (ip1, ip2) => {
    // Split IPs into their octets and convert to numbers
    const ip1Parts = ip1.split('.').map(Number);
    const ip2Parts = ip2.split('.').map(Number);

    // Compare each octet
    for (let i = 0; i < 4; i++) {
        if (ip1Parts[i] !== ip2Parts[i]) {
            return ip1Parts[i] - ip2Parts[i];
        }
    }
    return 0;
};

// Host details subcomponent with ICMP and port results
const HostDetailsView = ({ host }) => {
    const formatResponseTime = (ns) => {
        if (!ns || ns === 0) return 'N/A';
        const ms = ns / 1000000; // Convert nanoseconds to milliseconds
        return `${ms.toFixed(2)}ms`;
    };

    return (
        <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow transition-colors">
            <div className="flex justify-between items-center">
                <h4 className="text-lg font-semibold text-gray-800 dark:text-gray-200">
                    {host.host}
                </h4>
                <span
                    className={`px-2 py-1 rounded ${
                        host.available
                            ? 'bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-100'
                            : 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-100'
                    }`}
                >
          {host.available ? 'Online' : 'Offline'}
        </span>
            </div>

            {/* ICMP Status Section */}
            {host.icmp_status && (
                <div className="mt-3 bg-gray-50 dark:bg-gray-700 p-3 rounded transition-colors">
                    <h5 className="font-medium mb-2 text-gray-800 dark:text-gray-200">
                        ICMP Status
                    </h5>
                    <div className="grid grid-cols-2 gap-2 text-sm">
                        <div>
              <span className="text-gray-600 dark:text-gray-400">
                Response Time:
              </span>
                            <span className="ml-2 font-medium text-gray-800 dark:text-gray-200">
                {formatResponseTime(host.icmp_status.round_trip)}
              </span>
                        </div>
                        <div>
              <span className="text-gray-600 dark:text-gray-400">
                Packet Loss:
              </span>
                            <span className="ml-2 font-medium text-gray-800 dark:text-gray-200">
                {host.icmp_status.packet_loss}%
              </span>
                        </div>
                    </div>
                </div>
            )}

            {/* Port Results */}
            {host.port_results?.length > 0 && (
                <div className="mt-4">
                    <h5 className="font-medium text-gray-800 dark:text-gray-200">
                        Open Ports
                    </h5>
                    <div className="grid grid-cols-2 gap-2 mt-2">
                        {host.port_results
                            .filter((port) => port.available)
                            .map((port) => (
                                <div
                                    key={port.port}
                                    className="text-sm bg-gray-50 dark:bg-gray-700 p-2 rounded transition-colors"
                                >
                  <span className="font-medium text-gray-800 dark:text-gray-200">
                    Port {port.port}
                  </span>
                                    {port.service && (
                                        <span className="text-gray-600 dark:text-gray-400 ml-1">
                      ({port.service})
                    </span>
                                    )}
                                </div>
                            ))}
                    </div>
                </div>
            )}

            <div className="mt-4 text-xs text-gray-500 dark:text-gray-400">
                <div>First seen: {new Date(host.first_seen).toLocaleString()}</div>
                <div>Last seen: {new Date(host.last_seen).toLocaleString()}</div>
            </div>
        </div>
    );
};

const NetworkSweepView = ({ nodeId, service, standalone = false }) => {
    const [viewMode, setViewMode] = useState('summary');
    const [searchTerm, setSearchTerm] = useState('');

    // Parse sweep details from service
    const sweepDetails =
        typeof service.details === 'string'
            ? JSON.parse(service.details)
            : service.details;

    // Sort and filter hosts
    const sortAndFilterHosts = (hosts) => {
        if (!hosts) return [];
        return [...hosts]
            .filter((host) =>
                host.host.toLowerCase().includes(searchTerm.toLowerCase())
            )
            .sort((a, b) => compareIPAddresses(a.host, b.host));
    };

    // Get responding hosts only
    const getRespondingHosts = (hosts) => {
        if (!hosts) return [];

        return hosts.filter((host) => {
            const hasOpenPorts = host.port_results?.some((port) => port.available);

            const hasICMPResponse =
                host.icmp_status?.available &&
                host.icmp_status?.packet_loss === 0 &&
                host.icmp_status?.round_trip > 0 &&
                host.icmp_status?.round_trip < 10000000;

            if (hasICMPResponse) {
                console.log(`Host ${host.host} has valid ICMP response:`, host.icmp_status);
            } else if (host.icmp_status) {
                console.log(`Host ${host.host} has invalid ICMP response:`, host.icmp_status);
            }

            return hasOpenPorts || hasICMPResponse;
        });
    };

    const respondingHosts = getRespondingHosts(sweepDetails.hosts);

    // Filter and sort hosts for display
    const filteredHosts = sweepDetails.hosts
        ? sortAndFilterHosts(respondingHosts).filter((host) =>
            host.host.toLowerCase().includes(searchTerm.toLowerCase())
        )
        : [];

    return (
        <div
            className={`space-y-4 ${
                !standalone &&
                'bg-white dark:bg-gray-800 rounded-lg shadow p-4 transition-colors'
            }`}
        >
            {/* Header */}
            <div
                className={`${
                    standalone
                        ? 'bg-white dark:bg-gray-800 rounded-lg shadow p-4 transition-colors'
                        : ''
                }`}
            >
                <div className="flex justify-between items-center mb-4">
                    <div>
                        <h3 className="text-lg font-semibold text-gray-800 dark:text-gray-200">
                            Network Sweep: {sweepDetails.network}
                        </h3>
                        <p className="text-sm text-gray-600 dark:text-gray-400">
                            {respondingHosts.length} of {sweepDetails.total_hosts} hosts
                            responding
                        </p>
                    </div>
                    <div className="flex items-center gap-4">
                        <div className="space-x-2">
                            <button
                                onClick={() => setViewMode('summary')}
                                className={`px-3 py-1 rounded transition-colors ${
                                    viewMode === 'summary'
                                        ? 'bg-blue-500 text-white'
                                        : 'bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-200'
                                }`}
                            >
                                Summary
                            </button>
                            <button
                                onClick={() => setViewMode('hosts')}
                                className={`px-3 py-1 rounded transition-colors ${
                                    viewMode === 'hosts'
                                        ? 'bg-blue-500 text-white'
                                        : 'bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-200'
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
                            className="flex-1 p-2 border rounded text-gray-700 dark:text-gray-200 dark:bg-gray-800 border-gray-300 dark:border-gray-600"
                            value={searchTerm}
                            onChange={(e) => setSearchTerm(e.target.value)}
                        />
                    </div>
                )}

                <div className="text-sm text-gray-500 dark:text-gray-400 mt-2">
                    Last sweep: {new Date(sweepDetails.last_sweep * 1000).toLocaleString()}
                </div>
            </div>

            {/* ICMP Stats Summary */}
            {respondingHosts.length > 0 && (
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 transition-colors">
                    <h4 className="text-lg font-semibold mb-4 text-gray-800 dark:text-gray-200">
                        ICMP Status Summary
                    </h4>
                    <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                        {/* ICMP Responding */}
                        <div className="bg-gray-50 dark:bg-gray-700 p-4 rounded transition-colors">
                            <div className="text-sm text-gray-600 dark:text-gray-400">
                                ICMP Responding
                            </div>
                            <div className="text-2xl font-bold text-gray-800 dark:text-gray-100">
                                {
                                    respondingHosts.filter(
                                        (h) =>
                                            h.icmp_status?.available && h.icmp_status?.packet_loss === 0
                                    ).length
                                }
                                <span className="text-sm text-gray-500 dark:text-gray-300 ml-2">
                  hosts
                </span>
                            </div>
                        </div>

                        {/* Average Response Time */}
                        <div className="bg-gray-50 dark:bg-gray-700 p-4 rounded transition-colors">
                            <div className="text-sm text-gray-600 dark:text-gray-400">
                                Average Response Time
                            </div>
                            <div className="text-2xl font-bold text-gray-800 dark:text-gray-100">
                                {(() => {
                                    const respondingToICMP = respondingHosts.filter(
                                        (h) =>
                                            h.icmp_status?.available &&
                                            h.icmp_status?.packet_loss === 0 &&
                                            h.icmp_status?.round_trip > 0
                                    );
                                    if (respondingToICMP.length === 0) return 'N/A';
                                    const avg =
                                        respondingToICMP.reduce(
                                            (acc, h) => acc + h.icmp_status.round_trip,
                                            0
                                        ) /
                                        respondingToICMP.length /
                                        1000000;
                                    return `${avg.toFixed(2)}ms`;
                                })()}
                            </div>
                        </div>

                        {/* TCP Services */}
                        <div className="bg-gray-50 dark:bg-gray-700 p-4 rounded transition-colors">
                            <div className="text-sm text-gray-600 dark:text-gray-400">
                                Open Services
                            </div>
                            <div className="text-2xl font-bold text-gray-800 dark:text-gray-100">
                                {respondingHosts.reduce(
                                    (acc, host) =>
                                        acc +
                                        (host.port_results?.filter((port) => port.available)
                                            ?.length || 0),
                                    0
                                )}
                                <span className="text-sm text-gray-500 dark:text-gray-300 ml-2">
                  ports
                </span>
                            </div>
                        </div>
                    </div>
                </div>
            )}

            {/* Views */}
            {viewMode === 'summary' ? (
                <div
                    className={`${
                        standalone
                            ? 'bg-white dark:bg-gray-800 rounded-lg shadow p-4 transition-colors'
                            : ''
                    }`}
                >
                    <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
                        {sweepDetails.ports
                            ?.sort((a, b) => b.available - a.available)
                            .map((port) => (
                                <div
                                    key={port.port}
                                    className="bg-gray-50 dark:bg-gray-700 p-3 rounded transition-colors"
                                >
                                    <div className="font-medium text-gray-800 dark:text-gray-200">
                                        Port {port.port}
                                    </div>
                                    <div className="text-sm text-gray-600 dark:text-gray-400">
                                        {port.available} hosts responding
                                    </div>
                                    <div className="mt-1 bg-gray-200 dark:bg-gray-600 rounded-full h-2">
                                        <div
                                            className="bg-blue-500 rounded-full h-2"
                                            style={{
                                                width: `${
                                                    (port.available / sweepDetails.total_hosts) * 100
                                                }%`,
                                            }}
                                        />
                                    </div>
                                </div>
                            ))}
                    </div>
                </div>
            ) : (
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    {filteredHosts.map((host) => (
                        <HostDetailsView key={host.host} host={host} />
                    ))}
                </div>
            )}
        </div>
    );
};

export default NetworkSweepView;
