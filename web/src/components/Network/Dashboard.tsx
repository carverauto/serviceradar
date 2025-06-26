/*
* Copyright 2025 Carver Automation Corporation.
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

'use client';

import React, { useState, useMemo, useEffect, useCallback, Fragment } from 'react';
import { Poller, Service } from '@/types/types';
import { RawBackendLanDiscoveryData } from '@/types/lan_discovery';
import { Device, DevicesApiResponse, Pagination } from '@/types/devices';
import { useAuth } from '@/components/AuthProvider';
import { useRouter } from 'next/navigation';
import {
    Router as RouterIcon,
    Network,
    Scan,
    Server,
    CheckCircle,
    XCircle,
    ChevronRight,
    Activity,
    Globe,
    Rss,
    
    
    AlertTriangle,
    Loader2,
    Search,
    ArrowUp,
    ArrowDown,
    ChevronDown
} from 'lucide-react';
import ReactJson from '@microlink/react-json-view';
import { useDebounce } from 'use-debounce';

interface NetworkDashboardProps {
    initialPollers: Poller[];
}

interface ServiceWithPoller extends Service {
    poller_id: string;
}

type TabName = 'overview' | 'discovery' | 'sweeps' | 'snmp' | 'applications' | 'netflow';

// Helper: Stat Card Component
const StatCard = ({
                      title,
                      value,
                      icon,
                      isLoading,
                      onClick
                  }: {
    title: string;
    value: string | number;
    icon: React.ReactNode,
    isLoading?: boolean,
    onClick?: () => void
}) => (
    <div 
        className={`bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 p-4 rounded-lg ${
            onClick ? 'cursor-pointer hover:bg-gray-700/30 transition-colors duration-200' : ''
        }`}
        onClick={onClick}
    >
        <div className="flex items-center">
            <div className="p-3 bg-green-100 dark:bg-gray-700/50 rounded-md mr-4 text-green-600 dark:text-green-400">
                {icon}
            </div>
            <div>
                <p className="text-sm text-gray-600 dark:text-gray-400">{title}</p>
                {isLoading ? (
                    <div className="h-7 w-20 bg-gray-200 dark:bg-gray-700 rounded-md animate-pulse mt-1"></div>
                ) : (
                    <p className="text-2xl font-bold text-gray-900 dark:text-white">{value}</p>
                )}
            </div>
        </div>
    </div>
);

// Helper: Tab Button Component
const TabButton = ({
                       label,
                       icon: Icon,
                       isActive,
                       onClick
                   }: {
    label: string;
    icon: React.ElementType;
    isActive: boolean;
    onClick: () => void
}) => (
    <button
        onClick={onClick}
        className={`flex items-center gap-2 px-4 py-2 text-sm font-medium rounded-md transition-colors ${
            isActive ? 'bg-blue-600 text-white' : 'text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700/50'
        }`}
    >
        <Icon className={`h-5 w-5 ${
            isActive ? 'text-white' : 
            label === 'Overview' ? 'text-purple-600 dark:text-purple-400' :
            label === 'Discovery' ? 'text-blue-600 dark:text-blue-400' :
            label === 'Sweeps' ? 'text-green-600 dark:text-green-400' :
            label === 'SNMP' ? 'text-teal-600 dark:text-teal-400' :
            label === 'Applications' ? 'text-orange-600 dark:text-orange-400' :
            label === 'Netflow' ? 'text-indigo-600 dark:text-indigo-400' :
            'text-gray-600 dark:text-gray-400'
        }`} />
        {label}
    </button>
);

// SNMP Device List Component (for the SNMP Tab)
type SortableKeys = 'ip' | 'hostname' | 'last_seen' | 'first_seen' | 'poller_id';

const SNMPDeviceList: React.FC = () => {
    const { token } = useAuth();
    const [devices, setDevices] = useState<Device[]>([]);
    const [pagination, setPagination] = useState<Pagination | null>(null);
    const [stats, setStats] = useState({ online: 0, offline: 0 });
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);
    const [searchTerm, setSearchTerm] = useState('');
    const [debouncedSearchTerm] = useDebounce(searchTerm, 300);
    const [sortBy, setSortBy] = useState<SortableKeys>('last_seen');
    const [sortOrder, setSortOrder] = useState<'asc' | 'desc'>('desc');
    const [expandedRow, setExpandedRow] = useState<string | null>(null);

    const postQuery = useCallback(async <T extends DevicesApiResponse | { results: { 'count()': number }[] | { 'count()': number }[] }>(
        query: string,
        cursor?: string,
        direction?: 'next' | 'prev'
    ): Promise<T> => {
        const body: Record<string, unknown> = { query, limit: 20 };
        if (cursor) body.cursor = cursor;
        if (direction) body.direction = direction;

        const response = await fetch('/api/query', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                ...(token && { Authorization: `Bearer ${token}` })
            },
            body: JSON.stringify(body),
            cache: 'no-store',
        });

        if (!response.ok) {
            throw new Error((await response.json()).error || 'Failed to execute query');
        }
        return response.json();
    }, [token]);

    const fetchDevices = useCallback(async (cursor?: string, direction?: 'next' | 'prev') => {
        setLoading(true);
        setError(null);

        try {
            // Show all devices for now since SNMP array query syntax
            // is not supported in current SRQL version
            const whereClauses = ["device_id IS NOT NULL"];

            if (debouncedSearchTerm) {
                whereClauses.push(`(ip LIKE '%${debouncedSearchTerm}%' OR hostname LIKE '%${debouncedSearchTerm}%')`);
            }

            const query = `SHOW DEVICES WHERE ${whereClauses.join(' AND ')} ORDER BY ${sortBy} ${sortOrder.toUpperCase()}`;
            const data = await postQuery<DevicesApiResponse>(query, cursor, direction);

            setDevices(data.results || []);
            setPagination(data.pagination || null);

            // Fetch stats in parallel (using all devices for now)
            const [onlineRes, offlineRes] = await Promise.all([
                postQuery<{ results: { 'count()': number }[] }>(
                    "COUNT DEVICES WHERE is_available = true"
                ),
                postQuery<{ results: { 'count()': number }[] }>(
                    "COUNT DEVICES WHERE is_available = false"
                ),
            ]);

            setStats({
                online: onlineRes.results[0]?.['count()'] || 0,
                offline: offlineRes.results[0]?.['count()'] || 0,
            });
        } catch (e) {
            setError(e instanceof Error ? e.message : "An unknown error occurred.");
        } finally {
            setLoading(false);
        }
    }, [postQuery, debouncedSearchTerm, sortBy, sortOrder]);

    useEffect(() => {
        fetchDevices();
    }, [fetchDevices]);

    const handleSort = (key: SortableKeys) => {
        setSortBy(key);
        setSortOrder(sortBy === key && sortOrder === 'desc' ? 'asc' : 'desc');
    };

    const formatDate = (dateString: string) => new Date(dateString).toLocaleString();

    const getSourceColor = (source: string) => {
        const lowerSource = source.toLowerCase();
        if (lowerSource.includes('netbox')) return 'bg-blue-600/50 text-blue-200';
        if (lowerSource.includes('sweep')) return 'bg-green-600/50 text-green-200';
        if (lowerSource.includes('snmp')) return 'bg-teal-600/50 text-teal-200';
        return 'bg-gray-600/50 text-gray-200';
    };

    return (
        <div className="space-y-4">
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                <StatCard
                    title="Total Devices"
                    value={(stats.online + stats.offline).toLocaleString()}
                    icon={<Server size={24} />}
                    isLoading={loading}
                />
                <StatCard
                    title="Online"
                    value={stats.online.toLocaleString()}
                    icon={<CheckCircle size={24} />}
                    isLoading={loading}
                />
                <StatCard
                    title="Offline"
                    value={stats.offline.toLocaleString()}
                    icon={<XCircle size={24} />}
                    isLoading={loading}
                />
            </div>

            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg">
                <div className="p-4 border-b border-gray-200 dark:border-gray-700">
                    <div className="relative w-full md:w-1/3">
                        <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 h-5 w-5 text-gray-400" />
                        <input
                            type="text"
                            placeholder="Search devices..."
                            value={searchTerm}
                            onChange={(e) => setSearchTerm(e.target.value)}
                            className="w-full pl-10 pr-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-green-500 focus:border-green-500"
                        />
                    </div>
                </div>

                {loading ? (
                    <div className="text-center p-8">
                        <Loader2 className="h-8 w-8 text-gray-400 animate-spin mx-auto" />
                    </div>
                ) : error ? (
                    <div className="text-center p-8 text-red-500 dark:text-red-400">
                        <AlertTriangle className="mx-auto h-6 w-6 mb-2" />
                        {error}
                    </div>
                ) : devices.length === 0 ? (
                    <div className="text-center p-8 text-gray-600 dark:text-gray-400">
                        No devices found.
                    </div>
                ) : (
                    <div className="overflow-x-auto">
                        <table className="min-w-full divide-y divide-gray-700">
                            <thead className="bg-gray-100 dark:bg-gray-800/50">
                            <tr>
                                <th className="w-12"></th>
                                <th className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                                    Status
                                </th>
                                <th
                                    onClick={() => handleSort('hostname')}
                                    className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider cursor-pointer flex items-center"
                                >
                                    Device
                                    {sortBy === 'hostname' && (
                                        sortOrder === 'asc' ?
                                            <ArrowUp size={12} className="ml-1" /> :
                                            <ArrowDown size={12} className="ml-1" />
                                    )}
                                </th>
                                <th className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                                    Sources
                                </th>
                                <th
                                    onClick={() => handleSort('last_seen')}
                                    className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider cursor-pointer flex items-center"
                                >
                                    Last Seen
                                    {sortBy === 'last_seen' && (
                                        sortOrder === 'asc' ?
                                            <ArrowUp size={12} className="ml-1" /> :
                                            <ArrowDown size={12} className="ml-1" />
                                    )}
                                </th>
                            </tr>
                            </thead>
                            <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                            {devices.map(device => (
                                <Fragment key={device.device_id}>
                                    <tr className="hover:bg-gray-700/30">
                                        <td className="pl-4">
                                            <button
                                                onClick={() => setExpandedRow(expandedRow === device.device_id ? null : device.device_id)}
                                                className="p-1 rounded-full hover:bg-gray-600"
                                            >
                                                {expandedRow === device.device_id ?
                                                    <ChevronDown size={20} /> :
                                                    <ChevronRight size={20} />
                                                }
                                            </button>
                                        </td>
                                        <td className="px-6 py-4">
                                            {device.is_available ?
                                                <CheckCircle className="h-5 w-5 text-green-500" /> :
                                                <XCircle className="h-5 w-5 text-red-500" />
                                            }
                                        </td>
                                        <td className="px-6 py-4">
                                            <div className="text-sm font-medium text-gray-900 dark:text-white">
                                                {device.hostname || device.ip}
                                            </div>
                                            <div className="text-sm text-gray-600 dark:text-gray-400">
                                                {device.hostname ? device.ip : device.mac}
                                            </div>
                                        </td>
                                        <td className="px-6 py-4">
                                            <div className="flex flex-wrap gap-1">
                                                {device.discovery_sources.map(source => (
                                                    <span
                                                        key={source}
                                                        className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${getSourceColor(source)}`}
                                                    >
                                                            {source}
                                                        </span>
                                                ))}
                                            </div>
                                        </td>
                                        <td className="px-6 py-4 text-sm text-gray-700 dark:text-gray-300">
                                            {formatDate(device.last_seen)}
                                        </td>
                                    </tr>
                                    {expandedRow === device.device_id && (
                                        <tr className="bg-gray-100 dark:bg-gray-800/50">
                                            <td colSpan={5} className="p-0">
                                                <div className="p-4">
                                                    <ReactJson
                                                        src={device.metadata}
                                                        theme="pop"
                                                        collapsed={false}
                                                        style={{
                                                            padding: '1rem',
                                                            borderRadius: '0.375rem',
                                                            backgroundColor: '#1C1B22'
                                                        }}
                                                    />
                                                </div>
                                            </td>
                                        </tr>
                                    )}
                                </Fragment>
                            ))}
                            </tbody>
                        </table>

                        {/* Pagination */}
                        {pagination && (pagination.prev_cursor || pagination.next_cursor) && (
                            <div className="p-4 flex items-center justify-between border-t border-gray-200 dark:border-gray-700">
                                <button
                                    onClick={() => fetchDevices(pagination.prev_cursor, 'prev')}
                                    disabled={!pagination.prev_cursor || loading}
                                    className="px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-white rounded-md disabled:opacity-50"
                                >
                                    Previous
                                </button>
                                <button
                                    onClick={() => fetchDevices(pagination.next_cursor, 'next')}
                                    disabled={!pagination.next_cursor || loading}
                                    className="px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-white rounded-md disabled:opacity-50"
                                >
                                    Next
                                </button>
                            </div>
                        )}
                    </div>
                )}
            </div>
        </div>
    );
};

// Main Network Dashboard Component
const Dashboard: React.FC<NetworkDashboardProps> = ({ initialPollers }) => {
    const [activeTab, setActiveTab] = useState<TabName>('overview');
    const [snmpDeviceCount, setSnmpDeviceCount] = useState<number>(0);
    const [loadingStats, setLoadingStats] = useState(true);
    const router = useRouter();
    const { token } = useAuth();

    // Click handlers for stat cards
    const handleDiscoveredDevicesClick = () => {
        router.push('/query?q=' + encodeURIComponent('show devices'));
    };

    const handleDiscoveredInterfacesClick = () => {
        router.push('/query?q=' + encodeURIComponent('show interfaces'));
    };

    const handleActiveSweepsClick = () => {
        router.push('/query?q=' + encodeURIComponent('show sweep_results'));
    };

    const handleSnmpDevicesClick = () => {
        router.push('/query?q=' + encodeURIComponent('show devices where device_id IS NOT NULL'));
    };

    const { discoveryServices, sweepServices, snmpServices, applicationServices } = useMemo(() => {
        const discovery: ServiceWithPoller[] = [];
        const sweep: ServiceWithPoller[] = [];
        const snmp: ServiceWithPoller[] = [];
        const apps: ServiceWithPoller[] = [];

        initialPollers.forEach(poller => {
            poller.services?.forEach(service => {
                const serviceWithPollerId = { ...service, poller_id: poller.poller_id };
                if (service.type === 'network_discovery' || service.name === 'lan_discovery_via_mapper') {
                    discovery.push(serviceWithPollerId);
                } else if (service.type === 'sweep') {
                    sweep.push(serviceWithPollerId);
                } else if (service.type === 'snmp') {
                    snmp.push(serviceWithPollerId);
                } else if (service.type === 'grpc' || ['dusk', 'rusk', 'grpc', 'rperf-checker'].includes(service.name)) {
                    apps.push(serviceWithPollerId);
                }
            });
        });

        return {
            discoveryServices: discovery,
            sweepServices: sweep,
            snmpServices: snmp,
            applicationServices: apps
        };
    }, [initialPollers]);

    const totalDiscoveredDevices = useMemo(() => {
        return discoveryServices.reduce((acc, service) => {
            if (service.details) {
                try {
                    const details: RawBackendLanDiscoveryData = typeof service.details === 'string'
                        ? JSON.parse(service.details)
                        : service.details;

                    const deviceCount = details.total_devices !== undefined
                        ? details.total_devices
                        : Array.isArray(details.devices)
                            ? details.devices.length
                            : 0;

                    return acc + deviceCount;
                } catch {
                    return acc;
                }
            }
            return acc;
        }, 0);
    }, [discoveryServices]);

    const totalDiscoveredInterfaces = useMemo(() => {
        return discoveryServices.reduce((acc, service) => {
            if (service.details) {
                try {
                    const details: RawBackendLanDiscoveryData = typeof service.details === 'string'
                        ? JSON.parse(service.details)
                        : service.details;

                    const ifaceCount = Array.isArray(details.interfaces)
                        ? details.interfaces.length
                        : 0;

                    return acc + ifaceCount;
                } catch {
                    return acc;
                }
            }
            return acc;
        }, 0);
    }, [discoveryServices]);

    useEffect(() => {
        const fetchSnmpCount = async () => {
            setLoadingStats(true);
            try {
                const response = await fetch('/api/query', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                        ...(token && { Authorization: `Bearer ${token}` })
                    },
                    body: JSON.stringify({
                        // Count total devices for now since SNMP array query syntax
                        // is not supported in current SRQL version
                        query: "COUNT DEVICES"
                    }),
                });

                if (!response.ok) {
                    throw new Error('Failed to fetch SNMP device count');
                }

                const data = await response.json();
                setSnmpDeviceCount(data.results[0]?.['count()'] || 0);
            } catch (error) {
                console.error(error);
            } finally {
                setLoadingStats(false);
            }
        };

        fetchSnmpCount();
    }, [token]);

    const renderTabContent = () => {
        switch (activeTab) {
            case 'overview':
                return (
                    <div className="space-y-6">
                        <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
                            <StatCard
                                title="Discovered Devices"
                                value={totalDiscoveredDevices.toLocaleString()}
                                icon={<RouterIcon size={24} />}
                                onClick={handleDiscoveredDevicesClick}
                            />
                            <StatCard
                                title="Discovered Interfaces"
                                value={totalDiscoveredInterfaces.toLocaleString()}
                                icon={<Network size={24} />}
                                onClick={handleDiscoveredInterfacesClick}
                            />
                            <StatCard
                                title="Active Network Sweeps"
                                value={sweepServices.length}
                                icon={<Scan size={24} />}
                                onClick={handleActiveSweepsClick}
                            />
                            <StatCard
                                title="Total Devices"
                                value={snmpDeviceCount.toLocaleString()}
                                icon={<Rss size={24} />}
                                isLoading={loadingStats}
                                onClick={handleSnmpDevicesClick}
                            />
                        </div>

                        <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4">
                            <h3 className="font-semibold text-gray-900 dark:text-white mb-4">Active Network Tasks</h3>
                            <div className="space-y-3">
                                {[...discoveryServices, ...sweepServices, ...snmpServices].map(service => (
                                    <div
                                        key={service.id || service.name}
                                        className="flex items-center justify-between p-3 bg-gray-100 dark:bg-gray-800/50 rounded-md"
                                    >
                                        <div className="flex items-center gap-3">
                                            {service.type === 'network_discovery' ? (
                                                <Globe size={20} className="text-blue-500 dark:text-blue-400" />
                                            ) : service.type === 'sweep' ? (
                                                <Scan size={20} className="text-green-500 dark:text-green-400" />
                                            ) : service.type === 'snmp' ? (
                                                <Rss size={20} className="text-teal-500 dark:text-teal-400" />
                                            ) : (
                                                <Activity size={20} className="text-gray-500 dark:text-gray-400" />
                                            )
                                            }
                                            <div>
                                                <p className="font-medium text-gray-900 dark:text-white">{service.name}</p>
                                                <p className="text-xs text-gray-600 dark:text-gray-400">{service.poller_id}</p>
                                            </div>
                                        </div>
                                        <button
                                            onClick={() => router.push(`/service/${service.poller_id}/${service.name}`)}
                                            className="p-2 rounded-full hover:bg-gray-200 dark:hover:bg-gray-700 text-gray-600 dark:text-gray-400"
                                        >
                                            <ChevronRight size={20} />
                                        </button>
                                    </div>
                                ))}
                            </div>
                        </div>
                    </div>
                );

            case 'discovery':
                return (
                    <div className="space-y-4">
                        {discoveryServices.length === 0 ? (
                            <p className="text-gray-600 dark:text-gray-400 text-center p-8">
                                No Network Discovery services found.
                            </p>
                        ) : (
                            discoveryServices.map(service => (
                                <div
                                    key={service.id || service.name}
                                    className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 flex justify-between items-center"
                                >
                                    <div className="flex items-center gap-3">
                                        <Globe size={24} className="text-blue-600 dark:text-blue-400" />
                                        <div>
                                            <p className="font-semibold text-gray-900 dark:text-white">{service.name}</p>
                                            <p className="text-sm text-gray-600 dark:text-gray-400">{service.poller_id}</p>
                                        </div>
                                    </div>
                                    <button
                                        onClick={() => router.push(`/service/${service.poller_id}/${service.name}`)}
                                        className="text-sm bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-white px-3 py-1.5 rounded-md hover:bg-gray-300 dark:hover:bg-gray-600 transition-colors"
                                    >
                                        View Details
                                    </button>
                                </div>
                            ))
                        )}
                    </div>
                );

            case 'sweeps':
                return (
                    <div className="space-y-4">
                        {sweepServices.length === 0 ? (
                            <p className="text-gray-600 dark:text-gray-400 text-center p-8">
                                No Network Sweep services found.
                            </p>
                        ) : (
                            sweepServices.map(service => (
                                <div
                                    key={service.id || service.name}
                                    className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 flex justify-between items-center"
                                >
                                    <div className="flex items-center gap-3">
                                        <Scan size={24} className="text-green-600 dark:text-green-400" />
                                        <div>
                                            <p className="font-semibold text-gray-900 dark:text-white">{service.name}</p>
                                            <p className="text-sm text-gray-600 dark:text-gray-400">{service.poller_id}</p>
                                        </div>
                                    </div>
                                    <button
                                        onClick={() => router.push(`/service/${service.poller_id}/${service.name}`)}
                                        className="text-sm bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-white px-3 py-1.5 rounded-md hover:bg-gray-300 dark:hover:bg-gray-600 transition-colors"
                                    >
                                        View Results
                                    </button>
                                </div>
                            ))
                        )}
                    </div>
                );

            case 'snmp':
                return (
                    <div className="space-y-6">
                        <div>
                            <h2 className="text-xl font-bold text-gray-900 dark:text-white mb-4">SNMP Services</h2>
                            {snmpServices.length === 0 ? (
                                <div className="text-center p-8 bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg">
                                    <p className="text-gray-600 dark:text-gray-400">No active SNMP monitoring services found.</p>
                                </div>
                            ) : (
                                <div className="space-y-4">
                                    {snmpServices.map(service => (
                                        <div key={service.id || service.name} className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 flex justify-between items-center">
                                            <div className="flex items-center gap-3">
                                                <Rss size={24} className="text-teal-600 dark:text-teal-400" />
                                                <div>
                                                    <p className="font-semibold text-gray-900 dark:text-white">{service.name}</p>
                                                    <p className="text-sm text-gray-600 dark:text-gray-400">{service.poller_id}</p>
                                                </div>
                                            </div>
                                            <button
                                                onClick={() => router.push(`/service/${service.poller_id}/${service.name}`)}
                                                className="text-sm bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-white px-3 py-1.5 rounded-md hover:bg-gray-300 dark:hover:bg-gray-600 transition-colors"
                                            >
                                                View Dashboard
                                            </button>
                                        </div>
                                    ))}
                                </div>
                            )}
                        </div>
                        <SNMPDeviceList />
                    </div>
                );

            case 'applications':
                return (
                    <div className="space-y-4">
                        {applicationServices.length === 0 ? (
                            <p className="text-gray-600 dark:text-gray-400 text-center p-8">
                                No application services found.
                            </p>
                        ) : (
                            applicationServices.map(service => (
                                <div
                                    key={service.id || service.name}
                                    className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 flex justify-between items-center"
                                >
                                    <div className="flex items-center gap-3">
                                        <Server size={24} className="text-orange-600 dark:text-orange-400" />
                                        <div>
                                            <p className="font-semibold text-gray-900 dark:text-white">{service.name}</p>
                                            <p className="text-sm text-gray-600 dark:text-gray-400">{service.poller_id}</p>
                                        </div>
                                    </div>
                                    <button
                                        onClick={() => router.push(`/service/${service.poller_id}/${service.name}`)}
                                        className="text-sm bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-white px-3 py-1.5 rounded-md hover:bg-gray-300 dark:hover:bg-gray-600 transition-colors"
                                    >
                                        {service.name === 'rperf-checker' ? 'View Metrics' : 'View Dashboard'}
                                    </button>
                                </div>
                            ))
                        )}
                    </div>
                );

            case 'netflow':
                return (
                    <div className="text-center p-12 bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg">
                        <p className="text-gray-600 dark:text-gray-400">
                            Netflow data will be available here in a future update.
                        </p>
                    </div>
                );

            default:
                return null;
        }
    };

    return (
        <div className="space-y-6">
            <div className="flex flex-col md:flex-row justify-between items-start md:items-center gap-4">
                <div className="flex flex-wrap items-center gap-2 p-1 bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg">
                    <TabButton
                        label="Overview"
                        icon={Activity}
                        isActive={activeTab === 'overview'}
                        onClick={() => setActiveTab('overview')}
                    />
                    <TabButton
                        label="Discovery"
                        icon={Globe}
                        isActive={activeTab === 'discovery'}
                        onClick={() => setActiveTab('discovery')}
                    />
                    <TabButton
                        label="Sweeps"
                        icon={Scan}
                        isActive={activeTab === 'sweeps'}
                        onClick={() => setActiveTab('sweeps')}
                    />
                    <TabButton
                        label="SNMP"
                        icon={Rss}
                        isActive={activeTab === 'snmp'}
                        onClick={() => setActiveTab('snmp')}
                    />
                    <TabButton
                        label="Applications"
                        icon={Server}
                        isActive={activeTab === 'applications'}
                        onClick={() => setActiveTab('applications')}
                    />
                    <TabButton
                        label="Netflow"
                        icon={Network}
                        isActive={activeTab === 'netflow'}
                        onClick={() => setActiveTab('netflow')}
                    />
                </div>
            </div>
            <div>
                {renderTabContent()}
            </div>
        </div>
    );
};

export default Dashboard;