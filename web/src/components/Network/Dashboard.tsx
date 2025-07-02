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

import React, { useState, useMemo, useEffect, useCallback } from 'react';
import { Poller, Service } from '@/types/types';
import { Device, DevicesApiResponse, Pagination } from '@/types/devices';
import { useAuth } from '@/components/AuthProvider';
import { useRouter } from 'next/navigation';
import {
    Router as RouterIcon,
    Network,
    Scan,
    Server,
    ChevronRight,
    Activity,
    Globe,
    Rss,
    AlertTriangle,
    Search
} from 'lucide-react';
import { useDebounce } from 'use-debounce';
import { cachedQuery } from '@/lib/cached-query';
import DeviceBasedDiscoveryDashboard from './DeviceBasedDiscoveryDashboard';
import DeviceTable from '@/components/Devices/DeviceTable';

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

// SNMP Devices View using shared DeviceTable component
const SNMPDevicesView: React.FC = React.memo(() => {
    const { token } = useAuth();
    const [devices, setDevices] = useState<Device[]>([]);
    const [pagination, setPagination] = useState<Pagination | null>(null);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);
    const [searchTerm, setSearchTerm] = useState('');
    const [debouncedSearchTerm] = useDebounce(searchTerm, 300);
    const [sortBy, setSortBy] = useState<'ip' | 'hostname' | 'last_seen' | 'first_seen' | 'poller_id'>('last_seen');
    const [sortOrder, setSortOrder] = useState<'asc' | 'desc'>('desc');

    const postQuery = useCallback(async <T extends DevicesApiResponse>(
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
            const whereClauses = ["discovery_sources LIKE '%\"source\":\"snmp\"%'"];

            if (debouncedSearchTerm) {
                whereClauses.push(`(ip LIKE '%${debouncedSearchTerm}%' OR hostname LIKE '%${debouncedSearchTerm}%')`);
            }

            const query = `SHOW DEVICES WHERE ${whereClauses.join(' AND ')} ORDER BY ${sortBy} ${sortOrder.toUpperCase()}`;
            const data = await postQuery<DevicesApiResponse>(query, cursor, direction);

            setDevices(data.results || []);
            setPagination(data.pagination || null);
        } catch (e) {
            setError(e instanceof Error ? e.message : "An unknown error occurred.");
        } finally {
            setLoading(false);
        }
    }, [postQuery, debouncedSearchTerm, sortBy, sortOrder]);

    useEffect(() => {
        fetchDevices();
    }, [fetchDevices]);

    const handleSort = (key: 'ip' | 'hostname' | 'last_seen' | 'first_seen' | 'poller_id') => {
        setSortBy(key);
        setSortOrder(sortBy === key && sortOrder === 'desc' ? 'asc' : 'desc');
    };

    const handlePagination = (cursor: string | undefined, direction: 'next' | 'prev') => {
        fetchDevices(cursor, direction);
    };

    if (loading) {
        return (
            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-8">
                <div className="text-center">
                    <div className="animate-pulse flex space-x-4">
                        <div className="rounded-full bg-gray-200 dark:bg-gray-700 h-12 w-12"></div>
                        <div className="flex-1 space-y-2 py-1">
                            <div className="h-4 bg-gray-200 dark:bg-gray-700 rounded w-3/4"></div>
                            <div className="h-4 bg-gray-200 dark:bg-gray-700 rounded w-1/2"></div>
                        </div>
                    </div>
                </div>
            </div>
        );
    }

    if (error) {
        return (
            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-8">
                <div className="text-center text-red-500 dark:text-red-400">
                    <AlertTriangle className="mx-auto h-6 w-6 mb-2" />
                    {error}
                </div>
            </div>
        );
    }

    return (
        <div className="space-y-4">
            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg">
                <div className="p-4 border-b border-gray-200 dark:border-gray-700">
                    <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
                        <h3 className="text-lg font-semibold text-gray-900 dark:text-white">
                            SNMP Devices ({devices.length})
                        </h3>
                        <div className="relative w-full sm:w-1/3">
                            <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 h-5 w-5 text-gray-400" />
                            <input
                                type="text"
                                placeholder="Search SNMP devices..."
                                value={searchTerm}
                                onChange={(e) => setSearchTerm(e.target.value)}
                                className="w-full pl-10 pr-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-teal-500 focus:border-teal-500"
                            />
                        </div>
                    </div>
                </div>

                {devices.length === 0 ? (
                    <div className="text-center p-8 text-gray-600 dark:text-gray-400">
                        No SNMP devices found.
                    </div>
                ) : (
                    <div>
                        <DeviceTable
                            devices={devices}
                            onSort={handleSort}
                            sortBy={sortBy}
                            sortOrder={sortOrder}
                        />

                        {/* Pagination */}
                        {pagination && (pagination.prev_cursor || pagination.next_cursor) && (
                            <div className="p-4 flex items-center justify-between border-t border-gray-200 dark:border-gray-700">
                                <button
                                    onClick={() => handlePagination(pagination.prev_cursor, 'prev')}
                                    disabled={!pagination.prev_cursor || loading}
                                    className="px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-white rounded-md disabled:opacity-50"
                                >
                                    Previous
                                </button>
                                <button
                                    onClick={() => handlePagination(pagination.next_cursor, 'next')}
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
});

SNMPDevicesView.displayName = 'SNMPDevicesView';


// Main Network Dashboard Component
const Dashboard: React.FC<NetworkDashboardProps> = ({ initialPollers }) => {
    const [activeTab, setActiveTab] = useState<TabName>('overview');
    const [deviceStats, setDeviceStats] = useState<{ total: number; online: number; offline: number }>({ total: 0, online: 0, offline: 0 });
    const [loadingStats, setLoadingStats] = useState(true);
    const router = useRouter();
    const { token } = useAuth();

    // Click handlers for stat cards
    const handleDiscoveredDevicesClick = () => {
        router.push('/query?q=' + encodeURIComponent('SHOW DEVICES WHERE discovery_sources IS NOT NULL'));
    };

    const handleDiscoveredInterfacesClick = () => {
        router.push('/query?q=' + encodeURIComponent('SHOW INTERFACES'));
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

    const [discoveryStats, setDiscoveryStats] = useState<{ discoveredDevices: number; discoveredInterfaces: number }>({ 
        discoveredDevices: 0, 
        discoveredInterfaces: 0 
    });
    const [loadingDiscoveryStats, setLoadingDiscoveryStats] = useState(true);

    const fetchDiscoveryStats = useCallback(async () => {
        setLoadingDiscoveryStats(true);
        try {
            // Use cached queries to prevent duplicates
            const [devicesRes, interfacesRes] = await Promise.all([
                cachedQuery<{ results: [{ 'count()': number }] }>(
                    "COUNT DEVICES WHERE discovery_sources IS NOT NULL",
                    token || undefined,
                    30000 // 30 second cache
                ),
                cachedQuery<{ results: [{ 'count()': number }] }>(
                    "COUNT INTERFACES",
                    token || undefined,
                    30000
                ),
            ]);

            setDiscoveryStats({
                discoveredDevices: devicesRes.results[0]?.['count()'] || 0,
                discoveredInterfaces: interfacesRes.results[0]?.['count()'] || 0,
            });
        } catch (error) {
            console.error('Failed to fetch discovery stats:', error);
        } finally {
            setLoadingDiscoveryStats(false);
        }
    }, [token]);

    const fetchDeviceStats = useCallback(async () => {
        setLoadingStats(true);
        try {
            // Use cached queries to prevent duplicates
            const [totalRes, onlineRes, offlineRes] = await Promise.all([
                cachedQuery<{ results: [{ 'count()': number }] }>(
                    "COUNT DEVICES",
                    token || undefined,
                    30000 // 30 second cache
                ),
                cachedQuery<{ results: [{ 'count()': number }] }>(
                    "COUNT DEVICES WHERE is_available = true",
                    token || undefined,
                    30000
                ),
                cachedQuery<{ results: [{ 'count()': number }] }>(
                    "COUNT DEVICES WHERE is_available = false",
                    token || undefined,
                    30000
                ),
            ]);

            setDeviceStats({
                total: totalRes.results[0]?.['count()'] || 0,
                online: onlineRes.results[0]?.['count()'] || 0,
                offline: offlineRes.results[0]?.['count()'] || 0,
            });
        } catch (error) {
            console.error('Failed to fetch device stats:', error);
        } finally {
            setLoadingStats(false);
        }
    }, [token]);

    useEffect(() => {
        fetchDeviceStats();
        fetchDiscoveryStats();
    }, [fetchDeviceStats, fetchDiscoveryStats]);

    const renderTabContent = () => {
        switch (activeTab) {
            case 'overview':
                return (
                    <div className="space-y-6">
                        <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
                            <StatCard
                                title="Discovered Devices"
                                value={discoveryStats.discoveredDevices.toLocaleString()}
                                icon={<RouterIcon size={24} />}
                                isLoading={loadingDiscoveryStats}
                                onClick={handleDiscoveredDevicesClick}
                            />
                            <StatCard
                                title="Discovered Interfaces"
                                value={discoveryStats.discoveredInterfaces.toLocaleString()}
                                icon={<Network size={24} />}
                                isLoading={loadingDiscoveryStats}
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
                                value={deviceStats.total.toLocaleString()}
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
                return <DeviceBasedDiscoveryDashboard />;

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
                        {/* Use shared DeviceTable component for SNMP devices */}
                        {activeTab === 'snmp' && !loadingStats && (
                            <SNMPDevicesView />
                        )}
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