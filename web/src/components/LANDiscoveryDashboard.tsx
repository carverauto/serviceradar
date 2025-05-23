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
    AlertCircle,
    CheckCircle,
    XCircle,
    Wifi,
    Server,
    Globe,
    ArrowLeft
} from 'lucide-react';
import { useAuth } from '@/components/AuthProvider';

// --- START: UPDATED INTERFACES to match `snake_case` and nested `if_speed` and remove 'any' types ---

/**
 * RawBackendLanDiscoveryData represents the direct JSON structure returned by the backend's LAN discovery service details.
 * It contains snake_case keys as received from the Go backend.
 */
interface RawBackendLanDiscoveryData {
    devices?: RawDevice[];
    interfaces?: RawInterface[];
    topology?: NetworkTopology;
    last_discovery?: string;
    discovery_duration?: number;
    total_devices?: number;
    active_devices?: number;
    [key: string]: unknown; // Allow other unexpected top-level keys
}

/**
 * RawDevice represents a device object directly from the backend payload (snake_case keys).
 */
interface RawDevice {
    device_id?: string;
    hostname?: string;
    ip?: string; // raw ip address
    mac?: string; // raw mac address
    sys_descr?: string; // directly on device object
    sys_object_id?: string;
    sys_contact?: string; // directly on device object
    uptime?: number;
    discovery_source?: string;
    is_available?: boolean;
    last_seen?: string;
    metadata?: {
        discovery_id?: string;
        discovery_time?: string;
        [key: string]: unknown; // Arbitrary metadata keys
    };
    [key: string]: unknown; // Allow other unexpected keys
}

/**
 * RawInterface represents an interface object directly from the backend payload (snake_case keys).
 */
interface RawInterface {
    device_ip?: string;
    if_index?: number;
    if_name?: string;
    if_descr?: string;
    if_speed?: { value?: number } | number; // Can be object {value: number} or raw number
    if_phys_address?: string;
    if_admin_status?: number;
    if_oper_status?: number;
    if_type?: number; // SNMP interface type OID
    ip_addresses?: string[];
    metadata?: {
        discovery_id?: string;
        discovery_time?: string;
        if_type?: string; // `if_type` might be string in metadata, number in root
        [key: string]: unknown; // Arbitrary metadata keys
    };
    [key: string]: unknown; // Allow other unexpected keys
}

/**
 * Device represents a parsed device object for display in the frontend.
 * It uses camelCase keys for consistency with React component conventions.
 */
interface Device {
    name?: string; // Display name (from hostname, ip, or device_id)
    ip_address?: string; // from 'ip'
    mac_address?: string; // from 'mac'
    description?: string; // from 'sys_descr'
    type?: string; // from 'discovery_source'
    vendor?: string; // from 'sys_contact'
    last_seen?: string;
    status?: string; // 'online', 'offline', 'unknown'

    // Raw properties from backend output (retained for comprehensive data)
    device_id?: string;
    hostname?: string;
    ip?: string; // raw ip address
    mac?: string; // raw mac address
    sys_descr?: string;
    sys_object_id?: string;
    sys_contact?: string;
    uptime?: number;
    discovery_source?: string;
    is_available?: boolean;
    metadata?: {
        discovery_id?: string;
        discovery_time?: string;
        [key: string]: unknown;
    };
}

/**
 * Interface represents a parsed network interface object for display in the frontend.
 * It uses camelCase keys.
 */
interface Interface {
    name?: string; // Preferred display name (if_name or if_descr)
    ip_address?: string; // First IP from ip_addresses array
    mac_address?: string; // from 'if_phys_address'
    status?: string; // 'up', 'down', etc. (derived from if_oper_status)
    type?: string; // from 'if_type' (OID) or 'if_descr'
    speed?: string; // Formatted speed (e.g., "1Gbps", "10Mbps")
    duplex?: string;
    mtu?: number;

    // Raw properties from backend output (retained for comprehensive data)
    device_ip?: string;
    if_index?: number;
    if_name?: string;
    if_descr?: string;
    if_speed?: { value?: number } | number;
    if_phys_address?: string;
    if_admin_status?: number;
    if_oper_status?: number;
    if_type?: number;
    ip_addresses?: string[];
    metadata?: {
        discovery_id?: string;
        discovery_time?: string;
        if_type?: string;
        [key: string]: unknown;
    };
}

/**
 * Basic types for topology nodes and edges to avoid `any`.
 * More detailed types could be added if the topology is rendered visually.
 */
interface TopologyNode {
    id: string;
    label: string;
    type?: string;
    ip?: string;
    [key: string]: unknown;
}

interface TopologyEdge {
    from: string;
    to: string;
    label?: string;
    [key: string]: unknown;
}

interface NetworkTopology {
    nodes?: TopologyNode[];
    edges?: TopologyEdge[];
    subnets?: string[];
}

/**
 * ParsedLanDiscoveryData represents the fully parsed and structured data for the dashboard.
 */
interface ParsedLanDiscoveryData {
    devices: Device[];
    interfaces: Interface[];
    topology?: NetworkTopology;
    last_discovery?: string;
    discovery_duration?: number;
    total_devices?: number;
    active_devices?: number;
}

/**
 * ServicePayload represents the full service object returned by the API endpoint.
 */
interface ServicePayload {
    id?: string; // Example: service ID (optional)
    poller_id: string;
    service_name: string;
    status: string;
    last_update: string; // ISO 8601 timestamp string
    details: string | RawBackendLanDiscoveryData; // Can be JSON string or parsed object
    [key: string]: unknown; // Allow other potential fields in the service object
}

interface LanDiscoveryDashboardProps {
    pollerId: string;
    serviceName: string;
    initialService?: ServicePayload | null; // initialService can be null
    initialError?: string | null;
    initialTimeRange?: string; // Unused in this component but kept for consistency
}

// Define specific types for state variables that previously used 'any' with type assertions
type FilterType = 'all' | 'devices' | 'interfaces';
type SortBy = 'name' | 'ip' | 'status';
type SortOrder = 'asc' | 'desc';
type ViewMode = 'grid' | 'table';

// --- END: UPDATED INTERFACES ---


const LanDiscoveryDashboard: React.FC<LanDiscoveryDashboardProps> = ({
                                                                         pollerId,
                                                                         serviceName,
                                                                         initialService = null,
                                                                         initialError = null,
                                                                         // initialTimeRange // Unused in this component
                                                                     }) => {
    const router = useRouter();
    const { token } = useAuth();
    const [discoveryData, setDiscoveryData] = useState<ParsedLanDiscoveryData>({ devices: [], interfaces: [], topology: {} });
    const [isLoading, setIsLoading] = useState(true);
    const [error, setError] = useState<string | null>(initialError);
    const [searchTerm, setSearchTerm] = useState('');
    const [filterType, setFilterType] = useState<FilterType>('all');
    const [viewMode, setViewMode] = useState<ViewMode>('grid');
    const [sortBy, setSortBy] = useState<SortBy>('name');
    const [sortOrder, setSortOrder] = useState<SortOrder>('asc');
    const [lastRefreshed, setLastRefreshed] = useState(new Date());
    const [isRefreshing, setIsRefreshing] = useState(false);

    // --- START: UPDATED parseBackendLanDiscoveryData ---
    const parseBackendLanDiscoveryData = useCallback((rawDetails: RawBackendLanDiscoveryData): ParsedLanDiscoveryData => {
        console.group("parseBackendLanDiscoveryData called");
        console.log("Raw details received for parsing:", rawDetails);

        if (!rawDetails) {
            console.warn("parseBackendLanDiscoveryData received null or undefined rawDetails. Returning empty data.");
            console.groupEnd();
            return { devices: [], interfaces: [], topology: {} };
        }

        const devices: Device[] = []; // Changed to const
        const interfaces: Interface[] = []; // Changed to const
        let totalDevices = 0;
        let activeDevices = 0;

        const rawDevices = rawDetails.devices || [];
        const rawInterfaces = rawDetails.interfaces || [];

        // Process devices
        if (Array.isArray(rawDevices)) {
            console.log(`Processing ${rawDevices.length} raw devices.`);
            rawDevices.forEach((item: RawDevice, index: number) => { // Typed 'item' as RawDevice
                console.groupCollapsed(`Processing raw device item ${index}`);
                console.log("Raw device item:", item);

                let deviceStatus = 'unknown';
                if (typeof item.is_available === 'boolean') {
                    deviceStatus = item.is_available ? 'online' : 'offline';
                } else if (item.ip) {
                    deviceStatus = 'online'; // Assume online if IP exists and no other status
                }

                devices.push({
                    name: item.hostname || item.ip || item.device_id || 'Unknown Device',
                    ip_address: item.ip,
                    mac_address: item.mac,
                    description: item.sys_descr,
                    type: item.discovery_source,
                    vendor: item.sys_contact,
                    last_seen: item.last_seen,
                    status: deviceStatus,
                    // Keep raw fields
                    device_id: item.device_id,
                    hostname: item.hostname,
                    ip: item.ip,
                    mac: item.mac,
                    sys_descr: item.sys_descr,
                    sys_contact: item.sys_contact,
                    is_available: item.is_available,
                    metadata: item.metadata,
                });
                console.groupEnd();
            });
        } else {
            console.warn("`rawDetails.devices` is not an array or is missing.", rawDetails.devices);
        }

        // Process interfaces
        if (Array.isArray(rawInterfaces)) {
            console.log(`Processing ${rawInterfaces.length} raw interfaces.`);
            rawInterfaces.forEach((item: RawInterface, index: number) => { // Typed 'item' as RawInterface
                console.groupCollapsed(`Processing raw interface item ${index}`);
                console.log("Raw interface item:", item);

                let ifaceStatus = 'unknown';
                switch (item.if_oper_status) {
                    case 1: ifaceStatus = 'up'; break;
                    case 2: ifaceStatus = 'down'; break;
                    case 3: ifaceStatus = 'testing'; break;
                    case 4: ifaceStatus = 'unknown'; break;
                    case 5: ifaceStatus = 'dormant'; break;
                    case 6: ifaceStatus = 'notPresent'; break;
                    case 7: ifaceStatus = 'lowerLayerDown'; break;
                    default: ifaceStatus = 'unknown'; break;
                }

                let rawSpeedValue: number | undefined;
                if (typeof item.if_speed === 'object' && item.if_speed !== null && typeof item.if_speed.value === 'number') {
                    rawSpeedValue = item.if_speed.value;
                } else if (typeof item.if_speed === 'number') {
                    rawSpeedValue = item.if_speed;
                }

                let formattedSpeed = 'N/A';
                if (typeof rawSpeedValue === 'number' && rawSpeedValue > 0) {
                    const speedInMbps = rawSpeedValue / 1000000;
                    if (speedInMbps >= 1000) {
                        formattedSpeed = `${(speedInMbps / 1000).toFixed(1)}Gbps`;
                    } else if (speedInMbps >= 1) {
                        formattedSpeed = `${speedInMbps.toFixed(0)}Mbps`;
                    } else {
                        formattedSpeed = `${(rawSpeedValue / 1000).toFixed(0)}Kbps`;
                        if (rawSpeedValue < 1000) formattedSpeed = `${rawSpeedValue}bps`;
                    }
                } else if (rawSpeedValue === 0) {
                    formattedSpeed = '0 Mbps';
                }

                interfaces.push({
                    name: item.if_name || item.if_descr || `Interface ${item.if_index || 'N/A'}`,
                    ip_address: Array.isArray(item.ip_addresses) && item.ip_addresses.length > 0 ? item.ip_addresses[0] : undefined,
                    mac_address: item.if_phys_address || '-',
                    status: ifaceStatus,
                    type: item.metadata?.if_type || item.if_descr,
                    speed: formattedSpeed,
                    // Keep raw properties
                    if_name: item.if_name,
                    if_descr: item.if_descr,
                    if_index: item.if_index,
                    if_admin_status: item.if_admin_status,
                    if_oper_status: item.if_oper_status,
                    if_phys_address: item.if_phys_address,
                    if_speed: item.if_speed,
                    ip_addresses: item.ip_addresses,
                    metadata: item.metadata,
                });
                console.groupEnd();
            });
        } else {
            console.warn("`rawDetails.interfaces` is not an array or is missing.", rawDetails.interfaces);
        }

        totalDevices = rawDetails.total_devices !== undefined ? rawDetails.total_devices : devices.length;
        activeDevices = rawDetails.active_devices !== undefined ? rawDetails.active_devices : devices.filter((d: Device) => d.status === 'online').length;

        const parsedResult = {
            devices,
            interfaces,
            topology: rawDetails.topology || {},
            last_discovery: rawDetails.last_discovery,
            discovery_duration: rawDetails.discovery_duration,
            total_devices: totalDevices,
            active_devices: activeDevices,
        };

        console.log("Final parsed result:", parsedResult);
        console.groupEnd();
        return parsedResult;
    }, []);
    // --- END: UPDATED parseBackendLanDiscoveryData ---

    // Initialize data from props
    useEffect(() => {
        if (initialService) {
            let rawDetails: string | RawBackendLanDiscoveryData = initialService.details;
            try {
                if (typeof initialService.details === 'string') {
                    rawDetails = JSON.parse(initialService.details);
                }
            } catch (e) {
                console.error('Error parsing initialService.details JSON string:', e);
                setError('Failed to parse initial service details from backend. Please check JSON format.');
                setIsLoading(false);
                return;
            }

            const parsed = parseBackendLanDiscoveryData(rawDetails as RawBackendLanDiscoveryData); // Cast after potential parsing
            setDiscoveryData(parsed);
            setIsLoading(false);
            setLastRefreshed(new Date(initialService.last_update || Date.now()));
        } else {
            console.warn("LANDiscoveryDashboard: No initial service data provided.");
            setError("No initial LAN discovery service data provided.");
            setIsLoading(false);
        }
    }, [initialService, parseBackendLanDiscoveryData]);

    // Fetch latest data
    const fetchLatestData = useCallback(async () => {
        if (!pollerId || !serviceName) {
            console.warn("fetchLatestData: Missing pollerId or serviceName. Skipping fetch.");
            return;
        }

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
                cache: 'no-store', // Always fetch fresh data
            });

            if (!response.ok) {
                const errorText = await response.text();
                throw new Error(`Service data request failed: ${response.status} - ${errorText}`);
            }

            const serviceData: ServicePayload = await response.json(); // Typed serviceData
            let rawDetails: string | RawBackendLanDiscoveryData = serviceData.details;
            try {
                if (typeof serviceData.details === 'string') {
                    rawDetails = JSON.parse(serviceData.details);
                }
            } catch (e) {
                console.error('Error parsing refreshed serviceData.details JSON string:', e);
                throw new Error('Failed to parse refreshed service details. Please check JSON format.');
            }
            const parsed = parseBackendLanDiscoveryData(rawDetails as RawBackendLanDiscoveryData);
            setDiscoveryData(parsed);
            setLastRefreshed(new Date(serviceData.last_update || Date.now()));
            setError(null);
        } catch (err) {
            console.error('Error fetching LAN discovery data:', err);
            setError(err instanceof Error ? err.message : 'Failed to fetch data');
        } finally {
            setIsRefreshing(false);
            setIsLoading(false);
        }
    }, [pollerId, serviceName, token, parseBackendLanDiscoveryData]);

    // Auto-refresh
    useEffect(() => {
        const interval = setInterval(() => {
            fetchLatestData();
        }, 30000);

        return () => clearInterval(interval);
    }, [fetchLatestData]);

    // Filter and sort data
    const filteredData = useMemo(() => {
        const devices = discoveryData.devices || [];
        const interfaces = discoveryData.interfaces || [];

        let currentFilteredDevices = devices;
        let currentFilteredInterfaces = interfaces;

        // Apply search filter
        if (searchTerm) {
            const search = searchTerm.toLowerCase();
            currentFilteredDevices = devices.filter(d =>
                (d.name && d.name.toLowerCase().includes(search)) ||
                (d.ip_address && d.ip_address.toLowerCase().includes(search)) ||
                (d.mac_address && d.mac_address.toLowerCase().includes(search)) ||
                (d.description && d.description.toLowerCase().includes(search)) ||
                (d.type && d.type.toLowerCase().includes(search)) ||
                (d.vendor && d.vendor.toLowerCase().includes(search)) ||
                (d.hostname && d.hostname.toLowerCase().includes(search)) ||
                (d.device_id && d.device_id.toLowerCase().includes(search))
            );

            currentFilteredInterfaces = interfaces.filter(i =>
                (i.name && i.name.toLowerCase().includes(search)) ||
                (i.ip_address && i.ip_address.toLowerCase().includes(search)) ||
                (i.mac_address && i.mac_address.toLowerCase().includes(search)) ||
                (i.status && i.status.toLowerCase().includes(search)) ||
                (i.type && i.type.toLowerCase().includes(search)) ||
                (i.speed && i.speed.toLowerCase().includes(search)) ||
                (i.if_descr && i.if_descr.toLowerCase().includes(search)) ||
                (i.if_name && i.if_name.toLowerCase().includes(search))
            );
        }

        // Sort function, now correctly uses sortOrder
        const sortFn = (a: Device | Interface, b: Device | Interface) => {
            let aVal: string | number | undefined, bVal: string | number | undefined;
            let comparisonResult: number;

            switch (sortBy) {
                case 'ip':
                    const parseIp = (ip: string | undefined) => {
                        return ip ? ip.split('.').map(Number).reduce((acc, octet) => (acc << 8) + octet, 0) : 0;
                    };
                    comparisonResult = parseIp(a.ip_address) - parseIp(b.ip_address);
                    break;
                case 'status':
                    const statusOrder: { [key: string]: number } = { 'online': 1, 'up': 1, 'active': 1, 'warning': 2, 'offline': 3, 'down': 3, 'inactive': 3, 'unknown': 4, 'testing': 4, 'dormant':4, 'notpresent':4, 'lowerlayerdown':4 };
                    // Ensure status is string and fallback to empty string if undefined
                    aVal = statusOrder[String(a.status || '').toLowerCase()] || 99;
                    bVal = statusOrder[String(b.status || '').toLowerCase()] || 99;
                    comparisonResult = aVal - bVal;
                    if (comparisonResult === 0) { // Secondary sort by name if primary sort is equal
                        const aName = (a as Device).name || (a as Device).hostname || (a as Interface).name || (a as Interface).if_descr || '';
                        const bName = (b as Device).name || (b as Device).hostname || (b as Interface).name || (b as Interface).if_descr || '';
                        comparisonResult = String(aName).localeCompare(String(bName));
                    }
                    break;
                default: // 'name'
                    const aDisplayName = (a as Device).name || (a as Device).hostname || (a as Device).ip_address || (a as Interface).name || (a as Interface).if_descr || '';
                    const bDisplayName = (b as Device).name || (b as Device).hostname || (b as Device).ip_address || (b as Interface).name || (b as Interface).if_descr || '';
                    comparisonResult = String(aDisplayName).localeCompare(String(bDisplayName));
                    break;
            }
            return sortOrder === 'asc' ? comparisonResult : -comparisonResult;
        };

        if (Array.isArray(currentFilteredDevices)) {
            currentFilteredDevices.sort(sortFn);
        }
        if (Array.isArray(currentFilteredInterfaces)) {
            currentFilteredInterfaces.sort(sortFn);
        }

        return {
            devices: filterType === 'interfaces' ? [] : currentFilteredDevices,
            interfaces: filterType === 'devices' ? [] : currentFilteredInterfaces
        };
    }, [discoveryData, searchTerm, filterType, sortBy, sortOrder]);

    // Get icon for device type
    const getDeviceIcon = (device: Device) => {
        const type = device.type?.toLowerCase() || '';
        const description = device.description?.toLowerCase() || '';
        const name = device.name?.toLowerCase() || '';

        if (type.includes('router') || description.includes('udm-pro') || name.includes('router')) return <RouterIcon className="h-5 w-5" />;
        if (type.includes('switch') || name.includes('switch')) return <Network className="h-5 w-5" />;
        if (type.includes('server') || name.includes('server')) return <Server className="h-5 w-5" />;
        if (type.includes('wireless') || type.includes('wifi') || description.includes('access point') || name.includes('ap')) return <Wifi className="h-5 w-5" />;
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
    if (isLoading) {
        return (
            <div className="flex justify-center items-center h-64">
                <div className="text-lg text-gray-600 dark:text-gray-300">
                    Loading LAN discovery data...
                </div>
            </div>
        );
    }

    // Error state
    if (error && discoveryData.devices.length === 0 && discoveryData.interfaces.length === 0) {
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

            {/* Error Alert (if data exists but there was a recent refresh error) */}
            {error && (discoveryData.devices.length > 0 || discoveryData.interfaces.length > 0) && (
                <div className="bg-red-50 dark:bg-red-900/30 p-4 rounded-lg flex items-center">
                    <AlertCircle className="h-5 w-5 text-red-500 dark:text-red-400 mr-2" />
                    <span className="text-red-600 dark:text-red-300 text-sm">{error} (Showing last known data)</span>
                </div>
            )}


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
                                    ? new Date(discoveryData.last_discovery).toLocaleString()
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
                    <h3 className="text-lg font-semibold text-gray-900 dark:text-white">No Devices or Interfaces Discovered</h3>
                    <p className="text-gray-500 dark:text-gray-400">The LAN Discovery service has not found any network entities.</p>
                </div>
            )}
            {filteredData.devices.length === 0 && filteredData.interfaces.length === 0 && searchTerm !== '' && (
                <div className="bg-white dark:bg-gray-800 rounded-lg p-8 text-center shadow">
                    <Search className="h-12 w-12 mx-auto text-gray-400 mb-3" />
                    <h3 className="text-lg font-semibold text-gray-900 dark:text-white">No Matching Results</h3>
                    <p className="text-gray-500 dark:text-gray-400">No devices or interfaces match your search query &#34;{searchTerm}&#34;.</p>
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
                                    key={device.device_id || device.ip_address || `device-${index}`}
                                    className="border border-gray-200 dark:border-gray-700 rounded-lg p-4 hover:shadow-md transition-shadow"
                                >
                                    <div className="flex items-start justify-between mb-2">
                                        <div className="flex items-center gap-2">
                                            {getDeviceIcon(device)}
                                            <h3 className="font-medium text-gray-900 dark:text-white">
                                                {device.name || device.hostname || device.ip_address || 'Unknown Device'}
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
                                    <tr key={device.device_id || device.ip_address || `device-${index}`} className="hover:bg-gray-50 dark:hover:bg-gray-700">
                                        <td className="px-6 py-4 whitespace-nowrap">
                                            <div className="flex items-center">
                                                {getDeviceIcon(device)}
                                                <span className="ml-2 text-sm font-medium text-gray-900 dark:text-white">
                                                        {device.name || device.hostname || device.ip_address || 'Unknown'}
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
                                <tr key={iface.if_index || iface.mac_address || `interface-${index}`} className="hover:bg-gray-50 dark:hover:bg-gray-700">
                                    <td className="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-900 dark:text-white">
                                        {iface.name || iface.if_descr || iface.if_name || 'Unknown'}
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