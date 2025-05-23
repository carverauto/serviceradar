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

import React, { useState, useEffect, useCallback, useMemo } from 'react';
import { useRouter } from 'next/navigation';
import {
    Network,
    Monitor,
    Router as RouterIcon,
    Activity,
    Clock,
    RefreshCw,
    Search,
    Filter,
    ChevronDown,
    ChevronUp,
    AlertCircle,
    CheckCircle,
    XCircle,
    Wifi,
    Server,
    Globe,
    ArrowLeft
} from 'lucide-react';
import { useAuth } from '@/components/AuthProvider';

interface Device {
    name?: string;
    ip_address?: string;
    mac_address?: string;
    description?: string;
    type?: string;
    vendor?: string;
    last_seen?: string;
    status?: string;
}

interface Interface {
    name?: string;
    ip_address?: string;
    mac_address?: string;
    status?: string;
    type?: string;
    speed?: string;
    duplex?: string;
    mtu?: number;
}

interface NetworkTopology {
    nodes?: any[];
    edges?: any[];
    subnets?: string[];
}

interface LanDiscoveryData {
    devices?: Device[];
    interfaces?: Interface[];
    topology?: NetworkTopology;
    last_discovery?: string;
    discovery_duration?: number;
    total_devices?: number;
    active_devices?: number;
}

interface LanDiscoveryDashboardProps {
    pollerId: string;
    serviceName: string;
    initialService?: any;
    initialError?: string | null;
    initialTimeRange?: string;
}

const LanDiscoveryDashboard: React.FC<LanDiscoveryDashboardProps> = ({
                                                                         pollerId,
                                                                         serviceName,
                                                                         initialService = null,
                                                                         initialError = null,
                                                                         initialTimeRange = '1h'
                                                                     }) => {
    const router = useRouter();
    const { token } = useAuth();
    const [discoveryData, setDiscoveryData] = useState<LanDiscoveryData>({});
    const [isLoading, setIsLoading] = useState(true);
    const [error, setError] = useState<string | null>(initialError);
    const [searchTerm, setSearchTerm] = useState('');
    const [filterType, setFilterType] = useState<'all' | 'devices' | 'interfaces'>('all');
    const [showDetails, setShowDetails] = useState<string | null>(null);
    const [viewMode, setViewMode] = useState<'grid' | 'table'>('grid');
    const [sortBy, setSortBy] = useState<'name' | 'ip' | 'status'>('name');
    const [sortOrder, setSortOrder] = useState<'asc' | 'desc'>('asc');
    const [lastRefreshed, setLastRefreshed] = useState(new Date());
    const [isRefreshing, setIsRefreshing] = useState(false);

    // Parse service details
    const parseServiceDetails = useCallback((service: any) => {
        if (!service || !service.details) return {};

        try {
            const details = typeof service.details === 'string'
                ? JSON.parse(service.details)
                : service.details;

            return {
                devices: Array.isArray(details.devices) ? details.devices : [],
                interfaces: Array.isArray(details.interfaces) ? details.interfaces : [],
                topology: details.topology || {},
                last_discovery: details.last_discovery,
                discovery_duration: details.discovery_duration,
                total_devices: details.devices?.length || 0,
                active_devices: details.devices?.filter((d: Device) =>
                    d.status === 'active' || d.status === 'online'
                ).length || 0
            };
        } catch (e) {
            console.error('Error parsing LAN discovery details:', e);
            return {};
        }
    }, []);

    // Initialize data
    useEffect(() => {
        if (initialService) {
            const parsed = parseServiceDetails(initialService);
            setDiscoveryData(parsed);
            setIsLoading(false);
        }
    }, [initialService, parseServiceDetails]);

    // Fetch latest data
    const fetchLatestData = useCallback(async () => {
        if (!pollerId || !serviceName) return;

        try {
            setIsRefreshing(true);

            const headers: HeadersInit = {
                'Content-Type': 'application/json',
            };

            if (token) {
                headers['Authorization'] = `Bearer ${token}`;
            }

            const response = await fetch(`/api/pollers/${pollerId}/services/${serviceName}`, {
                headers,
                cache: 'no-store',
            });

            if (!response.ok) {
                throw new Error(`Service data request failed: ${response.status}`);
            }

            const serviceData = await response.json();
            const parsed = parseServiceDetails(serviceData);
            setDiscoveryData(parsed);
            setLastRefreshed(new Date());
            setError(null);
        } catch (err) {
            console.error('Error fetching LAN discovery data:', err);
            setError(err instanceof Error ? err.message : 'Failed to fetch data');
        } finally {
            setIsRefreshing(false);
            setIsLoading(false);
        }
    }, [pollerId, serviceName, token, parseServiceDetails]);

    // Auto-refresh
    useEffect(() => {
        const interval = setInterval(() => {
            fetchLatestData();
        }, 30000); // Refresh every 30 seconds

        return () => clearInterval(interval);
    }, [fetchLatestData]);

    // Filter and sort data
    const filteredData = useMemo(() => {
        const devices = discoveryData.devices || [];
        const interfaces = discoveryData.interfaces || [];

        let filteredDevices = devices;
        let filteredInterfaces = interfaces;

        // Apply search filter
        if (searchTerm) {
            const search = searchTerm.toLowerCase();
            filteredDevices = devices.filter(d =>
                d.name?.toLowerCase().includes(search) ||
                d.ip_address?.toLowerCase().includes(search) ||
                d.mac_address?.toLowerCase().includes(search) ||
                d.description?.toLowerCase().includes(search)
            );

            filteredInterfaces = interfaces.filter(i =>
                i.name?.toLowerCase().includes(search) ||
                i.ip_address?.toLowerCase().includes(search) ||
                i.mac_address?.toLowerCase().includes(search)
            );
        }

        // Sort function
        const sortFn = (a: any, b: any) => {
            let aVal, bVal;
            switch (sortBy) {
                case 'ip':
                    aVal = a.ip_address || '';
                    bVal = b.ip_address || '';
                    break;
                case 'status':
                    aVal = a.status || '';
                    bVal = b.status || '';
                    break;
                default:
                    aVal = a.name || a.ip_address || '';
                    bVal = b.name || b.ip_address || '';
            }

            if (sortOrder === 'asc') {
                return aVal.localeCompare(bVal);
            }
            return bVal.localeCompare(aVal);
        };

        filteredDevices.sort(sortFn);
        filteredInterfaces.sort(sortFn);

        return {
            devices: filterType === 'interfaces' ? [] : filteredDevices,
            interfaces: filterType === 'devices' ? [] : filteredInterfaces
        };
    }, [discoveryData, searchTerm, filterType, sortBy, sortOrder]);

    // Get icon for device type
    const getDeviceIcon = (device: Device) => {
        const type = device.type?.toLowerCase() || '';
        if (type.includes('router')) return <RouterIcon className="h-5 w-5" />;
        if (type.includes('switch')) return <Network className="h-5 w-5" />;
        if (type.includes('server')) return <Server className="h-5 w-5" />;
        if (type.includes('wireless') || type.includes('wifi')) return <Wifi className="h-5 w-5" />;
        return <Monitor className="h-5 w-5" />;
    };

    // Get status color
    const getStatusColor = (status?: string) => {
        const s = status?.toLowerCase() || '';
        if (s === 'active' || s === 'online' || s === 'up') return 'text-green-500';
        if (s === 'inactive' || s === 'offline' || s === 'down') return 'text-red-500';
        return 'text-gray-500';
    };

    // Loading state
    if (isLoading && !discoveryData.devices) {
        return (
            <div className="flex justify-center items-center h-64">
                <div className="text-lg text-gray-600 dark:text-gray-300">
                    Loading LAN discovery data...
                </div>
            </div>
        );
    }

    // Error state
    if (error && !discoveryData.devices) {
        return (
            <div className="bg-red-50 dark:bg-red-900/20 p-6 rounded-lg shadow">
                <div className="flex items-center mb-4">
                    <AlertCircle className="h-6 w-6 text-red-500 mr-2" />
                    <h2 className="text-xl font-bold text-red-700 dark:text-red-400">
                        Error Loading LAN Discovery Data
                    </h2>
                </div>
                <p className="text-red-600 dark:text-red-300 mb-4">{error}</p>
                <button
                    onClick={fetchLatestData}
                    className="px-4 py-2 bg-blue-500 text-white rounded hover:bg-blue-600 transition-colors"
                >
                    Retry
                </button>
            </div>
        );
    }

    return (
        <div className="space-y-6">
            {/* Header */}
            <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4 bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                <div className="flex items-center gap-2">
                    <button
                        onClick={() => router.push('/pollers')}
                        className="p-2 rounded-full bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600 transition-colors"
                    >
                        <ArrowLeft className="h-5 w-5" />
                    </button>
                    <div>
                        <h1 className="text-xl sm:text-2xl font-bold text-gray-900 dark:text-white flex items-center gap-2">
                            <Globe className="h-6 w-6 text-blue-500" />
                            LAN Discovery - {pollerId}
                        </h1>
                        <p className="text-sm text-gray-500 dark:text-gray-400">
                            Network topology and device discovery
                        </p>
                    </div>
                </div>

                <div className="flex items-center gap-2">
                    <button
                        onClick={fetchLatestData}
                        disabled={isRefreshing}
                        className="p-2 rounded-full bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600 transition-colors"
                    >
                        <RefreshCw className={`h-5 w-5 ${isRefreshing ? 'animate-spin' : ''}`} />
                    </button>
                </div>
            </div>

            {/* Stats Cards */}
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
                <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                    <div className="flex items-center justify-between">
                        <div>
                            <p className="text-sm text-gray-500 dark:text-gray-400">Total Devices</p>
                            <p className="text-2xl font-bold text-gray-900 dark:text-white">
                                {discoveryData.total_devices || 0}
                            </p>
                        </div>
                        <Monitor className="h-8 w-8 text-blue-500" />
                    </div>
                </div>

                <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                    <div className="flex items-center justify-between">
                        <div>
                            <p className="text-sm text-gray-500 dark:text-gray-400">Active Devices</p>
                            <p className="text-2xl font-bold text-green-600 dark:text-green-400">
                                {discoveryData.active_devices || 0}
                            </p>
                        </div>
                        <Activity className="h-8 w-8 text-green-500" />
                    </div>
                </div>

                <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                    <div className="flex items-center justify-between">
                        <div>
                            <p className="text-sm text-gray-500 dark:text-gray-400">Interfaces</p>
                            <p className="text-2xl font-bold text-gray-900 dark:text-white">
                                {discoveryData.interfaces?.length || 0}
                            </p>
                        </div>
                        <Network className="h-8 w-8 text-purple-500" />
                    </div>
                </div>

                <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                    <div className="flex items-center justify-between">
                        <div>
                            <p className="text-sm text-gray-500 dark:text-gray-400">Last Discovery</p>
                            <p className="text-sm font-medium text-gray-900 dark:text-white">
                                {discoveryData.last_discovery
                                    ? new Date(discoveryData.last_discovery).toLocaleTimeString()
                                    : 'N/A'}
                            </p>
                        </div>
                        <Clock className="h-8 w-8 text-gray-500" />
                    </div>
                </div>
            </div>

            {/* Filters and Search */}
            <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                <div className="flex flex-col lg:flex-row gap-4">
                    <div className="flex-1">
                        <div className="relative">
                            <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 h-5 w-5 text-gray-400" />
                            <input
                                type="text"
                                placeholder="Search by name, IP, or MAC address..."
                                value={searchTerm}
                                onChange={(e) => setSearchTerm(e.target.value)}
                                className="w-full pl-10 pr-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
                            />
                        </div>
                    </div>

                    <div className="flex gap-2">
                        <select
                            value={filterType}
                            onChange={(e) => setFilterType(e.target.value as any)}
                            className="px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
                        >
                            <option value="all">All</option>
                            <option value="devices">Devices Only</option>
                            <option value="interfaces">Interfaces Only</option>
                        </select>

                        <select
                            value={sortBy}
                            onChange={(e) => setSortBy(e.target.value as any)}
                            className="px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
                        >
                            <option value="name">Sort by Name</option>
                            <option value="ip">Sort by IP</option>
                            <option value="status">Sort by Status</option>
                        </select>

                        <button
                            onClick={() => setSortOrder(sortOrder === 'asc' ? 'desc' : 'asc')}
                            className="px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white hover:bg-gray-50 dark:hover:bg-gray-600"
                        >
                            {sortOrder === 'asc' ? '↑' : '↓'}
                        </button>

                        <button
                            onClick={() => setViewMode(viewMode === 'grid' ? 'table' : 'grid')}
                            className="px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white hover:bg-gray-50 dark:hover:bg-gray-600"
                        >
                            {viewMode === 'grid' ? 'Table' : 'Grid'}
                        </button>
                    </div>
                </div>
            </div>

            {/* Devices Section */}
            {filteredData.devices.length > 0 && (
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow">
                    <div className="p-4 border-b border-gray-200 dark:border-gray-700">
                        <h2 className="text-lg font-semibold text-gray-900 dark:text-white flex items-center gap-2">
                            <Monitor className="h-5 w-5" />
                            Discovered Devices ({filteredData.devices.length})
                        </h2>
                    </div>

                    {viewMode === 'grid' ? (
                        <div className="p-4 grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                            {filteredData.devices.map((device, index) => (
                                <div
                                    key={index}
                                    className="border border-gray-200 dark:border-gray-700 rounded-lg p-4 hover:shadow-md transition-shadow"
                                >
                                    <div className="flex items-start justify-between mb-2">
                                        <div className="flex items-center gap-2">
                                            {getDeviceIcon(device)}
                                            <h3 className="font-medium text-gray-900 dark:text-white">
                                                {device.name || device.ip_address || 'Unknown Device'}
                                            </h3>
                                        </div>
                                        <span className={`${getStatusColor(device.status)}`}>
                                            {device.status === 'active' || device.status === 'online' ? (
                                                <CheckCircle className="h-5 w-5" />
                                            ) : (
                                                <XCircle className="h-5 w-5" />
                                            )}
                                        </span>
                                    </div>

                                    <div className="space-y-1 text-sm">
                                        {device.ip_address && (
                                            <div className="flex justify-between">
                                                <span className="text-gray-500 dark:text-gray-400">IP:</span>
                                                <span className="font-mono text-gray-900 dark:text-white">
                                                    {device.ip_address}
                                                </span>
                                            </div>
                                        )}
                                        {device.mac_address && (
                                            <div className="flex justify-between">
                                                <span className="text-gray-500 dark:text-gray-400">MAC:</span>
                                                <span className="font-mono text-gray-900 dark:text-white">
                                                    {device.mac_address}
                                                </span>
                                            </div>
                                        )}
                                        {device.type && (
                                            <div className="flex justify-between">
                                                <span className="text-gray-500 dark:text-gray-400">Type:</span>
                                                <span className="text-gray-900 dark:text-white">
                                                    {device.type}
                                                </span>
                                            </div>
                                        )}
                                        {device.vendor && (
                                            <div className="flex justify-between">
                                                <span className="text-gray-500 dark:text-gray-400">Vendor:</span>
                                                <span className="text-gray-900 dark:text-white">
                                                    {device.vendor}
                                                </span>
                                            </div>
                                        )}
                                    </div>

                                    {device.description && (
                                        <p className="mt-2 text-sm text-gray-600 dark:text-gray-400">
                                            {device.description}
                                        </p>
                                    )}
                                </div>
                            ))}
                        </div>
                    ) : (
                        <div className="overflow-x-auto">
                            <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                                <thead className="bg-gray-50 dark:bg-gray-700">
                                <tr>
                                    <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                                        Device
                                    </th>
                                    <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                                        IP Address
                                    </th>
                                    <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                                        MAC Address
                                    </th>
                                    <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                                        Type
                                    </th>
                                    <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                                        Status
                                    </th>
                                </tr>
                                </thead>
                                <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                                {filteredData.devices.map((device, index) => (
                                    <tr key={index} className="hover:bg-gray-50 dark:hover:bg-gray-700">
                                        <td className="px-6 py-4 whitespace-nowrap">
                                            <div className="flex items-center">
                                                {getDeviceIcon(device)}
                                                <span className="ml-2 text-sm font-medium text-gray-900 dark:text-white">
                                                        {device.name || device.ip_address || 'Unknown'}
                                                    </span>
                                            </div>
                                        </td>
                                        <td className="px-6 py-4 whitespace-nowrap text-sm font-mono text-gray-900 dark:text-white">
                                            {device.ip_address || '-'}
                                        </td>
                                        <td className="px-6 py-4 whitespace-nowrap text-sm font-mono text-gray-900 dark:text-white">
                                            {device.mac_address || '-'}
                                        </td>
                                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900 dark:text-white">
                                            {device.type || '-'}
                                        </td>
                                        <td className="px-6 py-4 whitespace-nowrap">
                                                <span className={`inline-flex items-center ${getStatusColor(device.status)}`}>
                                                    {device.status === 'active' || device.status === 'online' ? (
                                                        <CheckCircle className="h-4 w-4" />
                                                    ) : (
                                                        <XCircle className="h-4 w-4" />
                                                    )}
                                                    <span className="ml-1 text-sm">{device.status || 'Unknown'}</span>
                                                </span>
                                        </td>
                                    </tr>
                                ))}
                                </tbody>
                            </table>
                        </div>
                    )}
                </div>
            )}

            {/* Interfaces Section */}
            {filteredData.interfaces.length > 0 && (
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow">
                    <div className="p-4 border-b border-gray-200 dark:border-gray-700">
                        <h2 className="text-lg font-semibold text-gray-900 dark:text-white flex items-center gap-2">
                            <Network className="h-5 w-5" />
                            Network Interfaces ({filteredData.interfaces.length})
                        </h2>
                    </div>

                    <div className="overflow-x-auto">
                        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                            <thead className="bg-gray-50 dark:bg-gray-700">
                            <tr>
                                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                                    Interface
                                </th>
                                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                                    IP Address
                                </th>
                                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                                    MAC Address
                                </th>
                                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                                    Speed
                                </th>
                                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                                    Status
                                </th>
                            </tr>
                            </thead>
                            <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                            {filteredData.interfaces.map((iface, index) => (
                                <tr key={index} className="hover:bg-gray-50 dark:hover:bg-gray-700">
                                    <td className="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-900 dark:text-white">
                                        {iface.name || 'Unknown'}
                                    </td>
                                    <td className="px-6 py-4 whitespace-nowrap text-sm font-mono text-gray-900 dark:text-white">
                                        {iface.ip_address || '-'}
                                    </td>
                                    <td className="px-6 py-4 whitespace-nowrap text-sm font-mono text-gray-900 dark:text-white">
                                        {iface.mac_address || '-'}
                                    </td>
                                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900 dark:text-white">
                                        {iface.speed || '-'}
                                    </td>
                                    <td className="px-6 py-4 whitespace-nowrap">
                                            <span className={`inline-flex items-center ${getStatusColor(iface.status)}`}>
                                                {iface.status === 'up' || iface.status === 'active' ? (
                                                    <CheckCircle className="h-4 w-4" />
                                                ) : (
                                                    <XCircle className="h-4 w-4" />
                                                )}
                                                <span className="ml-1 text-sm">{iface.status || 'Unknown'}</span>
                                            </span>
                                    </td>
                                </tr>
                            ))}
                            </tbody>
                        </table>
                    </div>
                </div>
            )}

            {/* Last Updated */}
            <div className="text-right text-xs text-gray-500 dark:text-gray-400">
                Last refreshed: {lastRefreshed.toLocaleString()}
            </div>
        </div>
    );
};

export default LanDiscoveryDashboard;