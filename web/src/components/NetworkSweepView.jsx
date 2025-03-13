import { useState, useMemo } from 'react';
import ExportButton from './ExportButton';
import { Filter, Search, ChevronDown, ChevronUp, Info, X } from 'lucide-react';

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
    const [expanded, setExpanded] = useState(false);

    const formatResponseTime = (ns) => {
        if (!ns || ns === 0) return 'N/A';
        const ms = ns / 1000000; // Convert nanoseconds to milliseconds
        return `${ms.toFixed(2)}ms`;
    };

    const toggleExpanded = () => {
        setExpanded(!expanded);
    };

    return (
        <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow transition-colors">
            <div className="flex justify-between items-center">
                <h4 className="text-base sm:text-lg font-semibold text-gray-800 dark:text-gray-200">
                    {host.host}
                </h4>
                <div className="flex items-center gap-2">
                    <span
                        className={`px-2 py-1 text-xs sm:text-sm rounded transition-colors ${
                            host.available
                                ? 'bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-100'
                                : 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-100'
                        }`}
                    >
                        {host.available ? 'Online' : 'Offline'}
                    </span>
                    <button
                        onClick={toggleExpanded}
                        className="p-1 rounded-full hover:bg-gray-100 dark:hover:bg-gray-700 sm:hidden"
                    >
                        {expanded ? <ChevronUp size={16} /> : <ChevronDown size={16} />}
                    </button>
                </div>
            </div>

            {/* Always visible on desktop, toggle on mobile */}
            <div className={`mt-3 ${expanded ? 'block' : 'hidden sm:block'}`}>
                {/* ICMP Status Section */}
                {host.icmp_status && (
                    <div className="mt-3 bg-gray-50 dark:bg-gray-700 p-3 rounded transition-colors">
                        <h5 className="font-medium mb-2 text-gray-800 dark:text-gray-200">
                            ICMP Status
                        </h5>
                        <div className="grid grid-cols-1 sm:grid-cols-2 gap-2 text-sm">
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
                        <div className="grid grid-cols-1 sm:grid-cols-2 gap-2 mt-2">
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
        </div>
    );
};

const NetworkSweepView = ({ nodeId, service, standalone = false }) => {
    const [viewMode, setViewMode] = useState('summary');
    const [searchTerm, setSearchTerm] = useState('');
    const [showFilters, setShowFilters] = useState(false);
    const [currentPage, setCurrentPage] = useState(1);
    const [networkSearchTerm, setNetworkSearchTerm] = useState('');
    const [showNetworkInfo, setShowNetworkInfo] = useState(false);
    const hostsPerPage = 10;

    // Parse sweep details from service
    const sweepDetails = typeof service.details === 'string'
        ? JSON.parse(service.details)
        : service.details;

    // Network list handling
    const networks = useMemo(() => {
        if (!sweepDetails?.network) return [];
        return sweepDetails.network.split(',');
    }, [sweepDetails]);

    // Network count for UI display
    const networkCount = networks.length;

    // Filtered networks based on search
    const filteredNetworks = useMemo(() => {
        if (networkSearchTerm === '') return networks.slice(0, 5); // Just show first 5 by default
        return networks.filter(network =>
            network.toLowerCase().includes(networkSearchTerm.toLowerCase())
        ).slice(0, 10); // Show max of 10 matches
    }, [networks, networkSearchTerm]);

    // Sort and filter hosts
    const sortAndFilterHosts = (hosts) => {
        if (!hosts) return [];
        return [...hosts]
            .filter((host) =>
                host.host.toLowerCase().includes(searchTerm.toLowerCase())
            )
            .sort((a, b) => compareIPAddresses(a.host, b.host));
    };

    // Get hosts that are responding
    const getRespondingHosts = (hosts) => {
        if (!hosts) return [];

        return hosts.filter((host) => {
            // If the host is explicitly marked as available, include it
            if (host.available) {
                return true;
            }

            // Check for available port results
            const hasOpenPorts = host.port_results?.some((port) => port.available);

            // Simpler ICMP check that doesn't impose arbitrary time limits
            const hasICMPResponse = host.icmp_status?.available === true;

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

    // Paginate filtered hosts for display
    const paginatedHosts = useMemo(() => {
        const startIndex = (currentPage - 1) * hostsPerPage;
        return filteredHosts.slice(startIndex, startIndex + hostsPerPage);
    }, [filteredHosts, currentPage]);

    // Calculate total pages for pagination
    const totalPages = Math.ceil(filteredHosts.length / hostsPerPage);

    const toggleFilters = () => {
        setShowFilters(!showFilters);
    };

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
                <div className="flex flex-col sm:flex-row sm:justify-between sm:items-center gap-3 mb-4">
                    <div>
                        <h3 className="text-lg font-semibold text-gray-800 dark:text-gray-200 mb-2">
                            Network Sweep
                        </h3>

                        {/* Network Summary with Toggle */}
                        <div className="flex items-center gap-2">
                            <span className="text-sm text-gray-600 dark:text-gray-400">
                                {networkCount} {networkCount === 1 ? 'network' : 'networks'} scanned
                            </span>
                            <button
                                onClick={() => setShowNetworkInfo(!showNetworkInfo)}
                                className="text-blue-500 hover:text-blue-700 dark:text-blue-400 dark:hover:text-blue-300"
                            >
                                <Info size={16} />
                            </button>
                        </div>
                    </div>

                    <div className="flex flex-col sm:flex-row items-start sm:items-center gap-2">
                        <div className="flex flex-wrap gap-2">
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
                        <div className="hidden sm:block">
                            <ExportButton sweepDetails={sweepDetails}/>
                        </div>
                    </div>
                </div>

                {/* Network Information Panel (Collapsible) */}
                {showNetworkInfo && (
                    <div className="bg-blue-50 dark:bg-blue-900/30 p-4 rounded-lg mb-4 relative">
                        <button
                            onClick={() => setShowNetworkInfo(false)}
                            className="absolute top-2 right-2 text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
                        >
                            <X size={16} />
                        </button>

                        <h4 className="text-md font-medium text-gray-800 dark:text-gray-200 mb-2">
                            Networks Being Monitored
                        </h4>

                        {/* Network Search */}
                        <div className="relative mb-3">
                            <input
                                type="text"
                                placeholder="Search networks..."
                                className="w-full px-3 py-2 border rounded text-gray-700 dark:text-gray-200 dark:bg-gray-800 border-gray-300 dark:border-gray-600 pl-8"
                                value={networkSearchTerm}
                                onChange={(e) => setNetworkSearchTerm(e.target.value)}
                            />
                            <Search className="absolute left-2 top-2.5 h-4 w-4 text-gray-400" />
                        </div>

                        {/* Network List */}
                        <div className="max-h-40 overflow-y-auto bg-white dark:bg-gray-800 rounded p-2 mb-2">
                            {filteredNetworks.length > 0 ? (
                                <ul className="list-disc list-inside">
                                    {filteredNetworks.map((network, index) => (
                                        <li key={index} className="text-sm text-gray-700 dark:text-gray-300 py-1">
                                            {network}
                                        </li>
                                    ))}
                                </ul>
                            ) : (
                                <p className="text-sm text-gray-500 dark:text-gray-400 italic">
                                    No matching networks found
                                </p>
                            )}
                        </div>

                        {/* Show count of total vs displayed */}
                        {networkSearchTerm === '' && networkCount > 5 && (
                            <p className="text-xs text-gray-500 dark:text-gray-400">
                                Showing 5 of {networkCount} networks. Use the search to find specific networks.
                            </p>
                        )}

                        {networkSearchTerm !== '' && filteredNetworks.length < networkCount && (
                            <p className="text-xs text-gray-500 dark:text-gray-400">
                                Showing {filteredNetworks.length} of {networkCount} networks matching "{networkSearchTerm}".
                            </p>
                        )}
                    </div>
                )}

                {viewMode === 'hosts' && (
                    <div className="flex items-center gap-2 mt-4">
                        <div className="relative flex-1">
                            <input
                                type="text"
                                placeholder="Search hosts..."
                                className="w-full p-2 border rounded text-gray-700 dark:text-gray-200 dark:bg-gray-800 border-gray-300 dark:border-gray-600 pl-8"
                                value={searchTerm}
                                onChange={(e) => {
                                    setSearchTerm(e.target.value);
                                    setCurrentPage(1); // Reset to first page on search
                                }}
                            />
                            <Search className="absolute left-2 top-2.5 h-4 w-4 text-gray-400" />
                        </div>
                        <button
                            onClick={toggleFilters}
                            className="sm:hidden p-2 border rounded text-gray-700 dark:text-gray-200 dark:bg-gray-800 border-gray-300 dark:border-gray-600"
                        >
                            <Filter className="h-4 w-4" />
                        </button>
                    </div>
                )}

                <div className="sm:hidden mt-4">
                    <ExportButton sweepDetails={sweepDetails} />
                </div>

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
                    <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
                        {/* ICMP Responding */}
                        <div className="bg-gray-50 dark:bg-gray-700 p-4 rounded transition-colors">
                            <div className="text-sm text-gray-600 dark:text-gray-400">
                                ICMP Responding
                            </div>
                            <div className="text-xl sm:text-2xl font-bold text-gray-800 dark:text-gray-100">
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
                            <div className="text-xl sm:text-2xl font-bold text-gray-800 dark:text-gray-100">
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
                            <div className="text-xl sm:text-2xl font-bold text-gray-800 dark:text-gray-100">
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
                    <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
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
                <>
                    {/* Host Detail Cards */}
                    <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                        {paginatedHosts.map((host) => (
                            <HostDetailsView key={host.host} host={host} />
                        ))}
                    </div>

                    {/* Pagination Controls */}
                    {totalPages > 1 && (
                        <div className="flex justify-center mt-4">
                            <div className="flex items-center space-x-2">
                                <button
                                    onClick={() => setCurrentPage(prev => Math.max(prev - 1, 1))}
                                    disabled={currentPage === 1}
                                    className={`px-3 py-1 rounded ${
                                        currentPage === 1
                                            ? 'bg-gray-200 dark:bg-gray-700 text-gray-400 dark:text-gray-500 cursor-not-allowed'
                                            : 'bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-200 hover:bg-gray-200 dark:hover:bg-gray-600'
                                    }`}
                                >
                                    Previous
                                </button>

                                <div className="text-sm text-gray-600 dark:text-gray-400">
                                    Page {currentPage} of {totalPages}
                                </div>

                                <button
                                    onClick={() => setCurrentPage(prev => Math.min(prev + 1, totalPages))}
                                    disabled={currentPage === totalPages}
                                    className={`px-3 py-1 rounded ${
                                        currentPage === totalPages
                                            ? 'bg-gray-200 dark:bg-gray-700 text-gray-400 dark:text-gray-500 cursor-not-allowed'
                                            : 'bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-200 hover:bg-gray-200 dark:hover:bg-gray-600'
                                    }`}
                                >
                                    Next
                                </button>
                            </div>
                        </div>
                    )}

                    {/* Results Count */}
                    <div className="text-center text-sm text-gray-500 dark:text-gray-400">
                        Showing {filteredHosts.length > 0 ? (currentPage - 1) * hostsPerPage + 1 : 0}-
                        {Math.min(currentPage * hostsPerPage, filteredHosts.length)} of {filteredHosts.length} hosts
                    </div>
                </>
            )}
        </div>
    );
};

export default NetworkSweepView;