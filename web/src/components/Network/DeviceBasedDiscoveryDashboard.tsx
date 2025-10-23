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
import { usePathname, useRouter } from 'next/navigation';
import {
    Network,
    Monitor,
    Router as RouterIcon,
    Activity,
    Clock,
    RefreshCw,
    Search,
    AlertCircle,
    CheckCircle,
    XCircle,
    Wifi,
    Server,
    Globe,
    ArrowLeft
} from 'lucide-react';
import { useAuth } from '@/components/AuthProvider';
import { Device } from '@/types/devices';
import InterfaceTable from './InterfaceTable';
import { cachedQuery } from '@/lib/cached-query';
import { useSrqlQuery } from '@/contexts/SrqlQueryContext';
import { DISCOVERY_DEVICES_QUERY, DISCOVERY_INTERFACES_QUERY } from '@/lib/srqlQueries';

/**
 * Interface represents a discovered network interface from the device_id centric model
 */
interface DiscoveredInterface {
    device_id?: string;
    device_ip?: string;
    if_index?: number;
    if_name?: string;
    if_descr?: string;
    if_speed?: number;
    if_phys_address?: string;
    if_admin_status?: number;
    if_oper_status?: number;
    if_type?: number;
    ip_addresses?: string[];
    timestamp?: string;
    agent_id?: string;
    poller_id?: string;
    metadata?: Record<string, unknown>;
    [key: string]: unknown;
}

interface DeviceBasedDiscoveryDashboardProps {}

type FilterType = 'all' | 'devices' | 'interfaces';
type SortBy = 'name' | 'ip' | 'status';
type SortOrder = 'asc' | 'desc';
type ViewMode = 'grid' | 'table';
const DISCOVERY_RESULTS_LIMIT = 50;
const statCardButtonClass = (isActive: boolean): string =>
    [
        'w-full text-left bg-white dark:bg-gray-800 p-4 rounded-lg shadow border transition',
        'hover:border-gray-300 dark:hover:border-gray-600',
        'focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500',
        'focus-visible:ring-offset-2 dark:focus-visible:ring-offset-gray-900',
        isActive
            ? 'border-blue-500 dark:border-blue-400 ring-1 ring-blue-300 dark:ring-blue-500/40'
            : 'border-transparent',
    ].join(' ');

const DeviceBasedDiscoveryDashboard: React.FC<DeviceBasedDiscoveryDashboardProps> = () => {
    const router = useRouter();
    const pathname = usePathname();
    const { setQuery: setSrqlQuery } = useSrqlQuery();
    const discoveryViewPath = useMemo(() => `${pathname ?? '/network'}#discovery`, [pathname]);
    const { token } = useAuth();
    const [devices, setDevices] = useState<Device[]>([]);
    const [interfaces, setInterfaces] = useState<DiscoveredInterface[]>([]);
    const [isLoading, setIsLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);
    const [searchTerm, setSearchTerm] = useState('');
    const [filterType, setFilterType] = useState<FilterType>('all');
    const [viewMode, setViewMode] = useState<ViewMode>('grid');
    const [sortBy, setSortBy] = useState<SortBy>('name');
    const [sortOrder, setSortOrder] = useState<SortOrder>('asc');
    const [lastRefreshed, setLastRefreshed] = useState(new Date());
    const [isRefreshing, setIsRefreshing] = useState(false);
    const [stats, setStats] = useState({
        totalDevices: 0,
        activeDevices: 0,
        totalInterfaces: 0,
        onlineInterfaces: 0
    });

    // Fetch discovered devices using device_id centric queries
    const fetchDevices = useCallback(async () => {
        try {
            const response = await cachedQuery<{ results: Device[] }>(
                DISCOVERY_DEVICES_QUERY,
                token || undefined,
                30000,
                { limit: DISCOVERY_RESULTS_LIMIT }
            );
            return Array.isArray(response.results) ? response.results : [];
        } catch (error) {
            console.error('Failed to fetch discovered devices:', error);
            throw error;
        }
    }, [token]);

    // Fetch discovered interfaces using device_id centric queries
    const fetchInterfaces = useCallback(async () => {
        try {
            const response = await cachedQuery<{ results: DiscoveredInterface[] }>(
                DISCOVERY_INTERFACES_QUERY,
                token || undefined,
                30000,
                { limit: DISCOVERY_RESULTS_LIMIT }
            );
            return Array.isArray(response.results) ? response.results : [];
        } catch (error) {
            console.error('Failed to fetch discovered interfaces:', error);
            throw error;
        }
    }, [token]);

    // Fetch stats
    const fetchStats = useCallback(async () => {
        try {
            const [totalDevicesRes, activeDevicesRes, totalInterfacesRes] = await Promise.all([
                cachedQuery<{ results: [{ total: number }] }>(
                    'in:devices discovery_sources:* stats:"count() as total" sort:total:desc time:last_7d',
                    token || undefined,
                    30000
                ),
                cachedQuery<{ results: [{ total: number }] }>(
                    'in:devices discovery_sources:* is_available:true stats:"count() as total" sort:total:desc time:last_7d',
                    token || undefined,
                    30000
                ),
                cachedQuery<{ results: [{ total: number }] }>(
                    'in:interfaces stats:"count() as total" sort:total:desc time:last_7d',
                    token || undefined,
                    30000
                ),
            ]);

            setStats({
                totalDevices: totalDevicesRes.results[0]?.total || 0,
                activeDevices: activeDevicesRes.results[0]?.total || 0,
                totalInterfaces: totalInterfacesRes.results[0]?.total || 0,
                onlineInterfaces: 0 // Could add interface status counting if needed
            });
        } catch (error) {
            console.error('Failed to fetch stats:', error);
        }
    }, [token]);

    // Fetch all data
    const fetchData = useCallback(async () => {
        setIsRefreshing(true);
        setError(null);
        
        try {
            const [devicesData, interfacesData] = await Promise.all([
                fetchDevices(),
                fetchInterfaces()
            ]);
            
            setDevices(devicesData);
            setInterfaces(interfacesData);
            await fetchStats();
            setLastRefreshed(new Date());
        } catch (err) {
            console.error('Error fetching discovery data:', err);
            setError(err instanceof Error ? err.message : 'Failed to fetch discovery data');
        } finally {
            setIsRefreshing(false);
            setIsLoading(false);
        }
    }, [fetchDevices, fetchInterfaces, fetchStats]);

    const handleTotalDevicesCardClick = useCallback(() => {
        if (filterType === 'all') {
            void fetchData();
            return;
        }
        setFilterType('all');
    }, [fetchData, filterType]);

    const handleInterfacesCardClick = useCallback(() => {
        if (filterType === 'interfaces') {
            void fetchData();
            return;
        }
        setFilterType('interfaces');
    }, [fetchData, filterType]);

    useEffect(() => {
        const baseQuery = filterType === 'interfaces' ? DISCOVERY_INTERFACES_QUERY : DISCOVERY_DEVICES_QUERY;
        setSrqlQuery(baseQuery, { origin: 'view', viewPath: discoveryViewPath, viewId: 'network:discovery' });
    }, [filterType, setSrqlQuery, discoveryViewPath]);

    // Initial load
    useEffect(() => {
        fetchData();
    }, [fetchData]);

    // Auto-refresh every 30 seconds
    useEffect(() => {
        const interval = setInterval(() => {
            fetchData();
        }, 30000);

        return () => clearInterval(interval);
    }, [fetchData]);

    // Filter and sort data
    const filteredData = useMemo(() => {
        let currentFilteredDevices = devices;
        let currentFilteredInterfaces = interfaces;

        // Apply search filter
        if (searchTerm) {
            const search = searchTerm.toLowerCase();
            currentFilteredDevices = devices.filter(d =>
                (d.hostname && d.hostname.toLowerCase().includes(search)) ||
                (d.ip && d.ip.toLowerCase().includes(search)) ||
                (d.mac && d.mac.toLowerCase().includes(search)) ||
                (d.device_id && d.device_id.toLowerCase().includes(search))
            );

            currentFilteredInterfaces = interfaces.filter(i =>
                (i.if_name && i.if_name.toLowerCase().includes(search)) ||
                (i.if_descr && i.if_descr.toLowerCase().includes(search)) ||
                (i.device_ip && i.device_ip.toLowerCase().includes(search)) ||
                (i.if_phys_address && i.if_phys_address.toLowerCase().includes(search))
            );
        }

        // Sort function
        const sortFn = (a: Device | DiscoveredInterface, b: Device | DiscoveredInterface) => {
            let aVal: string | number | undefined, bVal: string | number | undefined;
            let comparisonResult: number;

            switch (sortBy) {
                case 'ip':
                    const parseIp = (ip: string | undefined) => {
                        return ip ? ip.split('.').map(Number).reduce((acc, octet) => (acc << 8) + octet, 0) : 0;
                    };
                    const aIp = 'ip' in a ? (a as Device).ip : ('device_ip' in a ? (a as DiscoveredInterface).device_ip : undefined);
                    const bIp = 'ip' in b ? (b as Device).ip : ('device_ip' in b ? (b as DiscoveredInterface).device_ip : undefined);
                    comparisonResult = parseIp(aIp) - parseIp(bIp);
                    break;
                case 'status':
                    const statusOrder: { [key: string]: number } = { 
                        'online': 1, 'up': 1, 'active': 1, 
                        'warning': 2, 
                        'offline': 3, 'down': 3, 'inactive': 3, 
                        'unknown': 4 
                    };
                    const aStatus = 'is_available' in a ? ((a as Device).is_available ? 'online' : 'offline') : 'unknown';
                    const bStatus = 'is_available' in b ? ((b as Device).is_available ? 'online' : 'offline') : 'unknown';
                    aVal = statusOrder[aStatus] || 99;
                    bVal = statusOrder[bStatus] || 99;
                    comparisonResult = aVal - bVal;
                    break;
                default: // 'name'
                    const aName = ('hostname' in a ? (a as Device).hostname : undefined) || 
                                  ('if_name' in a ? (a as DiscoveredInterface).if_name : undefined) || 
                                  ('ip' in a ? (a as Device).ip : undefined) || 
                                  ('device_ip' in a ? (a as DiscoveredInterface).device_ip : undefined) || '';
                    const bName = ('hostname' in b ? (b as Device).hostname : undefined) || 
                                  ('if_name' in b ? (b as DiscoveredInterface).if_name : undefined) || 
                                  ('ip' in b ? (b as Device).ip : undefined) || 
                                  ('device_ip' in b ? (b as DiscoveredInterface).device_ip : undefined) || '';
                    comparisonResult = String(aName).localeCompare(String(bName));
                    break;
            }
            return sortOrder === 'asc' ? comparisonResult : -comparisonResult;
        };

        currentFilteredDevices.sort(sortFn);
        currentFilteredInterfaces.sort(sortFn);

        return {
            devices: filterType === 'interfaces' ? [] : currentFilteredDevices,
            interfaces: filterType === 'devices' ? [] : currentFilteredInterfaces
        };
    }, [devices, interfaces, searchTerm, filterType, sortBy, sortOrder]);

    // Convert interfaces to format expected by InterfaceTable
    const formattedInterfaces = useMemo(() => {
        return filteredData.interfaces.map(iface => ({
            name: iface.if_name || iface.if_descr || `Interface ${iface.if_index || 'N/A'}`,
            ip_address: Array.isArray(iface.ip_addresses) && iface.ip_addresses.length > 0 ? iface.ip_addresses[0] : undefined,
            mac_address: iface.if_phys_address || '-',
            status: iface.if_oper_status === 1 ? 'up' : iface.if_oper_status === 2 ? 'down' : 'unknown',
            type: iface.if_descr,
            speed: iface.if_speed ? `${(iface.if_speed / 1000000).toFixed(0)}Mbps` : 'N/A',
            device_ip: iface.device_ip,
            if_name: iface.if_name,
            if_descr: iface.if_descr,
            if_index: iface.if_index,
            if_admin_status: iface.if_admin_status,
            if_oper_status: iface.if_oper_status,
            if_phys_address: iface.if_phys_address,
            if_speed: iface.if_speed,
            ip_addresses: iface.ip_addresses,
            metadata: iface.metadata,
        }));
    }, [filteredData.interfaces]);

    // Get icon for device type
    const getDeviceIcon = (device: Device) => {
        const sources = device.discovery_sources?.join(' ').toLowerCase() || '';
        const hostname = device.hostname?.toLowerCase() || '';

        if (sources.includes('router') || hostname.includes('router')) return <RouterIcon className="h-5 w-5" />;
        if (sources.includes('switch') || hostname.includes('switch')) return <Network className="h-5 w-5" />;
        if (sources.includes('server') || hostname.includes('server')) return <Server className="h-5 w-5" />;
        if (sources.includes('wifi') || hostname.includes('ap')) return <Wifi className="h-5 w-5" />;
        return <Monitor className="h-5 w-5" />;
    };

    // Get status color
    const getStatusColor = (isAvailable?: boolean) => {
        if (isAvailable === true) return 'text-green-500';
        if (isAvailable === false) return 'text-red-500';
        return 'text-gray-500';
    };

    // Loading state
    if (isLoading) {
        return (
            <div className="flex justify-center items-center h-64">
                <div className="text-lg text-gray-600 dark:text-gray-300">
                    Loading discovery data...
                </div>
            </div>
        );
    }

    // Error state
    if (error && devices.length === 0 && interfaces.length === 0) {
        return (
            <div className="bg-red-50 dark:bg-red-900/20 p-6 rounded-lg shadow">
                <div className="flex items-center mb-4">
                    <AlertCircle className="h-6 w-6 text-red-500 mr-2" />
                    <h2 className="text-xl font-bold text-red-700 dark:text-red-400">
                        Error Loading Discovery Data
                    </h2>
                </div>
                <p className="text-red-600 dark:text-red-300 mb-4">{error}</p>
                <button
                    onClick={fetchData}
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
                        onClick={() => router.push('/network')}
                        className="p-2 rounded-full bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600 transition-colors"
                    >
                        <ArrowLeft className="h-5 w-5" />
                    </button>
                    <div>
                        <h1 className="text-xl sm:text-2xl font-bold text-gray-900 dark:text-white flex items-center gap-2">
                            <Globe className="h-6 w-6 text-blue-500" />
                            Network Discovery
                        </h1>
                        <p className="text-sm text-gray-500 dark:text-gray-400">
                            Discovered devices and interfaces from all sources
                        </p>
                    </div>
                </div>

                <div className="flex items-center gap-2">
                    <button
                        onClick={fetchData}
                        disabled={isRefreshing}
                        className="p-2 rounded-full bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600 transition-colors"
                    >
                        <RefreshCw className={`h-5 w-5 ${isRefreshing ? 'animate-spin' : ''}`} />
                    </button>
                </div>
            </div>

            {/* Error Alert (if data exists but there was a recent refresh error) */}
            {error && (devices.length > 0 || interfaces.length > 0) && (
                <div className="bg-red-50 dark:bg-red-900/30 p-4 rounded-lg flex items-center">
                    <AlertCircle className="h-5 w-5 text-red-500 dark:text-red-400 mr-2" />
                    <span className="text-red-600 dark:text-red-300 text-sm">{error} (Showing last known data)</span>
                </div>
            )}

            {/* Stats Cards */}
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
                <button
                    type="button"
                    onClick={handleTotalDevicesCardClick}
                    className={statCardButtonClass(filterType === 'all')}
                >
                    <div className="flex items-center justify-between">
                        <div>
                            <p className="text-sm text-gray-500 dark:text-gray-400">Total Devices</p>
                            <p className="text-2xl font-bold text-gray-900 dark:text-white">
                                {stats.totalDevices}
                            </p>
                        </div>
                        <Monitor className="h-8 w-8 text-blue-500" />
                    </div>
                </button>

                <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                    <div className="flex items-center justify-between">
                        <div>
                            <p className="text-sm text-gray-500 dark:text-gray-400">Active Devices</p>
                            <p className="text-2xl font-bold text-green-600 dark:text-green-400">
                                {stats.activeDevices}
                            </p>
                        </div>
                        <Activity className="h-8 w-8 text-green-500" />
                    </div>
                </div>

                <button
                    type="button"
                    onClick={handleInterfacesCardClick}
                    className={statCardButtonClass(filterType === 'interfaces')}
                >
                    <div className="flex items-center justify-between">
                        <div>
                            <p className="text-sm text-gray-500 dark:text-gray-400">Interfaces</p>
                            <p className="text-2xl font-bold text-gray-900 dark:text-white">
                                {stats.totalInterfaces}
                            </p>
                        </div>
                        <Network className="h-8 w-8 text-green-500" />
                    </div>
                </button>

                <div className="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                    <div className="flex items-center justify-between">
                        <div>
                            <p className="text-sm text-gray-500 dark:text-gray-400">Last Updated</p>
                            <p className="text-sm font-medium text-gray-900 dark:text-white">
                                {lastRefreshed.toLocaleString()}
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
                            onChange={(e) => setFilterType(e.target.value as FilterType)}
                            className="px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
                        >
                            <option value="all">All</option>
                            <option value="devices">Devices Only</option>
                            <option value="interfaces">Interfaces Only</option>
                        </select>

                        <select
                            value={sortBy}
                            onChange={(e) => setSortBy(e.target.value as SortBy)}
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

            {/* No Data State */}
            {filteredData.devices.length === 0 && filteredData.interfaces.length === 0 && searchTerm === '' && (
                <div className="bg-white dark:bg-gray-800 rounded-lg p-8 text-center shadow">
                    <Monitor className="h-12 w-12 mx-auto text-gray-400 mb-3" />
                    <h3 className="text-lg font-semibold text-gray-900 dark:text-white">No Discovery Data</h3>
                    <p className="text-gray-500 dark:text-gray-400">No discovered devices or interfaces found.</p>
                </div>
            )}
            {filteredData.devices.length === 0 && filteredData.interfaces.length === 0 && searchTerm !== '' && (
                <div className="bg-white dark:bg-gray-800 rounded-lg p-8 text-center shadow">
                    <Search className="h-12 w-12 mx-auto text-gray-400 mb-3" />
                    <h3 className="text-lg font-semibold text-gray-900 dark:text-white">No Matching Results</h3>
                    <p className="text-gray-500 dark:text-gray-400">No devices or interfaces match your search query &quot;{searchTerm}&quot;.</p>
                </div>
            )}

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
                                    key={device.device_id || device.ip || `device-${index}`}
                                    className="border border-gray-200 dark:border-gray-700 rounded-lg p-4 hover:shadow-md transition-shadow"
                                >
                                    <div className="flex items-start justify-between mb-2">
                                        <div className="flex items-center gap-2">
                                            {getDeviceIcon(device)}
                                            <h3 className="font-medium text-gray-900 dark:text-white">
                                                {device.hostname || device.ip || 'Unknown Device'}
                                            </h3>
                                        </div>
                                        <span className={`${getStatusColor(device.is_available)}`}>
                                            {device.is_available ? (
                                                <CheckCircle className="h-5 w-5" />
                                            ) : (
                                                <XCircle className="h-5 w-5" />
                                            )}
                                        </span>
                                    </div>

                                    <div className="space-y-1 text-sm">
                                        {device.ip && (
                                            <div className="flex justify-between">
                                                <span className="text-gray-500 dark:text-gray-400">IP:</span>
                                                <span className="font-mono text-gray-900 dark:text-white">
                                                    {device.ip}
                                                </span>
                                            </div>
                                        )}
                                        {device.mac && (
                                            <div className="flex justify-between">
                                                <span className="text-gray-500 dark:text-gray-400">MAC:</span>
                                                <span className="font-mono text-gray-900 dark:text-white">
                                                    {device.mac}
                                                </span>
                                            </div>
                                        )}
                                        {device.discovery_sources && device.discovery_sources.length > 0 && (
                                            <div className="flex justify-between">
                                                <span className="text-gray-500 dark:text-gray-400">Sources:</span>
                                                <span className="text-gray-900 dark:text-white">
                                                    {device.discovery_sources.join(', ')}
                                                </span>
                                            </div>
                                        )}
                                    </div>
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
                                        Sources
                                    </th>
                                    <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                                        Status
                                    </th>
                                </tr>
                                </thead>
                                <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                                {filteredData.devices.map((device, index) => (
                                    <tr key={device.device_id || device.ip || `device-${index}`} className="hover:bg-gray-50 dark:hover:bg-gray-700">
                                        <td className="px-6 py-4 whitespace-nowrap">
                                            <div className="flex items-center">
                                                {getDeviceIcon(device)}
                                                <span className="ml-2 text-sm font-medium text-gray-900 dark:text-white">
                                                    {device.hostname || device.ip || 'Unknown'}
                                                </span>
                                            </div>
                                        </td>
                                        <td className="px-6 py-4 whitespace-nowrap text-sm font-mono text-gray-900 dark:text-white">
                                            {device.ip || '-'}
                                        </td>
                                        <td className="px-6 py-4 whitespace-nowrap text-sm font-mono text-gray-900 dark:text-white">
                                            {device.mac || '-'}
                                        </td>
                                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900 dark:text-white">
                                            {device.discovery_sources?.join(', ') || '-'}
                                        </td>
                                        <td className="px-6 py-4 whitespace-nowrap">
                                            <span className={`inline-flex items-center ${getStatusColor(device.is_available)}`}>
                                                {device.is_available ? (
                                                    <CheckCircle className="h-4 w-4" />
                                                ) : (
                                                    <XCircle className="h-4 w-4" />
                                                )}
                                                <span className="ml-1 text-sm">{device.is_available ? 'Online' : 'Offline'}</span>
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
                    <div className="p-4">
                        <InterfaceTable 
                            interfaces={formattedInterfaces} 
                            showDeviceColumn={true}
                            jsonViewTheme="pop"
                        />
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

export default DeviceBasedDiscoveryDashboard;
