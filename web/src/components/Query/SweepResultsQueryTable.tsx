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

import React, { useState, useMemo } from 'react';
import { Device } from '@/types/devices';
import { 
    CheckCircle, 
    XCircle, 
    Activity, 
    Server, 
    Search,
    Eye,
    EyeOff 
} from 'lucide-react';

interface SweepResultsQueryTableProps {
    devices: Device[];
    jsonViewTheme?: 'rjv-default' | 'pop';
}

interface PortResult {
    port: number;
    available: boolean;
    response_time?: number;
    service?: string;
}

const SweepResultsQueryTable: React.FC<SweepResultsQueryTableProps> = ({ 
    devices
}) => {
    const [viewMode, setViewMode] = useState<'summary' | 'table'>('summary');
    const [searchTerm, setSearchTerm] = useState('');
    const [expandedRow, setExpandedRow] = useState<string | null>(null);

    const parseMetadata = (metadata: Record<string, unknown> | string | undefined): Record<string, unknown> => {
        if (!metadata) return {};
        if (typeof metadata === 'string') {
            try {
                return JSON.parse(metadata);
            } catch {
                return {};
            }
        }
        return metadata;
    };

    const aggregatedStats = useMemo(() => {
        if (!devices.length) return null;

        const totalHosts = devices.length;
        const respondingHosts = devices.filter(device => device.is_available).length;
        
        let totalOpenPorts = 0;
        let avgResponseTime = 0;
        
        try {
            const hostsWithMetadata = devices.filter(device => device.metadata && device.metadata !== '{}');
            if (hostsWithMetadata.length > 0) {
                hostsWithMetadata.forEach(device => {
                    const metadata = parseMetadata(device.metadata);
                    let openPorts: unknown[] = [];
                    const rawOpenPorts = metadata.open_ports;
                    
                    if (typeof rawOpenPorts === 'string') {
                        try {
                            openPorts = JSON.parse(rawOpenPorts);
                        } catch {
                            openPorts = [];
                        }
                    } else if (Array.isArray(rawOpenPorts)) {
                        openPorts = rawOpenPorts;
                    }
                    
                    totalOpenPorts += Array.isArray(openPorts) ? openPorts.length : 0;
                });
                
                const responseTimes = hostsWithMetadata
                    .map(device => {
                        const metadata = parseMetadata(device.metadata);
                        const responseTime = metadata.response_time_ns;
                        return typeof responseTime === 'number' ? responseTime : 0;
                    })
                    .filter(time => time > 0);
                
                avgResponseTime = responseTimes.length > 0 ?
                    responseTimes.reduce((acc, time) => acc + time, 0) / responseTimes.length / 1000000 : 0;
            }
        } catch (error) {
            console.warn('Error parsing sweep metadata:', error);
        }

        return {
            totalHosts,
            respondingHosts,
            totalOpenPorts,
            avgResponseTime
        };
    }, [devices]);

    const filteredDevices = useMemo(() => {
        if (!searchTerm) return devices;
        
        return devices.filter(device => 
            device.ip.toLowerCase().includes(searchTerm.toLowerCase()) ||
            (device.hostname && device.hostname.toLowerCase().includes(searchTerm.toLowerCase()))
        );
    }, [devices, searchTerm]);

    if (devices.length === 0) {
        return (
            <div className="text-center p-8 text-gray-600 dark:text-gray-400">
                No sweep results found.
            </div>
        );
    }

    return (
        <div className="space-y-4">
            {/* Summary Stats */}
            {aggregatedStats && (
                <div className="grid grid-cols-1 md:grid-cols-4 gap-4 p-4 bg-gray-50 dark:bg-gray-800/50 rounded-lg">
                    <div className="flex items-center gap-3">
                        <Server className="h-5 w-5 text-blue-500" />
                        <div>
                            <p className="text-sm text-gray-600 dark:text-gray-400">Total Hosts</p>
                            <p className="text-lg font-semibold text-gray-900 dark:text-white">
                                {aggregatedStats.totalHosts.toLocaleString()}
                            </p>
                        </div>
                    </div>
                    <div className="flex items-center gap-3">
                        <CheckCircle className="h-5 w-5 text-green-500" />
                        <div>
                            <p className="text-sm text-gray-600 dark:text-gray-400">Responding</p>
                            <p className="text-lg font-semibold text-gray-900 dark:text-white">
                                {aggregatedStats.respondingHosts.toLocaleString()}
                            </p>
                        </div>
                    </div>
                    <div className="flex items-center gap-3">
                        <Activity className="h-5 w-5 text-purple-500" />
                        <div>
                            <p className="text-sm text-gray-600 dark:text-gray-400">Open Ports</p>
                            <p className="text-lg font-semibold text-gray-900 dark:text-white">
                                {aggregatedStats.totalOpenPorts.toLocaleString()}
                            </p>
                        </div>
                    </div>
                    <div className="flex items-center gap-3">
                        <Activity className="h-5 w-5 text-orange-500" />
                        <div>
                            <p className="text-sm text-gray-600 dark:text-gray-400">Avg Response</p>
                            <p className="text-lg font-semibold text-gray-900 dark:text-white">
                                {aggregatedStats.avgResponseTime > 0 ? `${aggregatedStats.avgResponseTime.toFixed(2)}ms` : 'N/A'}
                            </p>
                        </div>
                    </div>
                </div>
            )}

            {/* Controls */}
            <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
                <div className="flex gap-2">
                    <button
                        onClick={() => setViewMode('summary')}
                        className={`px-4 py-2 rounded-md transition-colors ${
                            viewMode === 'summary'
                                ? 'bg-blue-500 text-white'
                                : 'bg-gray-100 dark:bg-gray-700 text-gray-900 dark:text-white'
                        }`}
                    >
                        Summary View
                    </button>
                    <button
                        onClick={() => setViewMode('table')}
                        className={`px-4 py-2 rounded-md transition-colors ${
                            viewMode === 'table'
                                ? 'bg-blue-500 text-white'
                                : 'bg-gray-100 dark:bg-gray-700 text-gray-900 dark:text-white'
                        }`}
                    >
                        Table View
                    </button>
                </div>
                
                <div className="relative w-full sm:w-1/3">
                    <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 h-5 w-5 text-gray-400" />
                    <input
                        type="text"
                        placeholder="Search IPs or hostnames..."
                        value={searchTerm}
                        onChange={(e) => setSearchTerm(e.target.value)}
                        className="w-full pl-10 pr-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-green-500 focus:border-green-500"
                    />
                </div>
            </div>

            {/* Content */}
            {viewMode === 'summary' ? (
                <div className="space-y-3">
                    {filteredDevices.slice(0, 10).map((device, index) => {
                        const metadata = parseMetadata(device.metadata);
                        const responseTime = typeof metadata.response_time_ns === 'number' ? metadata.response_time_ns / 1000000 : null;
                        let openPorts: unknown[] = [];
                        const rawOpenPorts = metadata.open_ports;
                        
                        if (typeof rawOpenPorts === 'string') {
                            try {
                                openPorts = JSON.parse(rawOpenPorts);
                            } catch {
                                openPorts = [];
                            }
                        } else if (Array.isArray(rawOpenPorts)) {
                            openPorts = rawOpenPorts;
                        }
                        
                        return (
                            <div key={device.device_id || index} className="border border-gray-200 dark:border-gray-700 rounded-lg p-4 bg-white dark:bg-gray-800">
                                <div className="flex justify-between items-start mb-2">
                                    <div>
                                        <h4 className="font-medium text-gray-900 dark:text-white">
                                            {device.hostname || device.ip}
                                        </h4>
                                        <p className="text-sm text-gray-600 dark:text-gray-400">
                                            {device.ip} • {new Date(device.last_seen).toLocaleString()}
                                        </p>
                                    </div>
                                    <div className="flex items-center gap-2">
                                        <span className={`px-2 py-1 text-xs rounded ${
                                            device.is_available
                                                ? 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-200'
                                                : 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-200'
                                        }`}>
                                            {device.is_available ? 'Available' : 'Unavailable'}
                                        </span>
                                    </div>
                                </div>
                                
                                <div className="flex flex-wrap gap-2 text-xs">
                                    {responseTime && (
                                        <span className="px-2 py-1 bg-blue-100 dark:bg-blue-900/30 text-blue-800 dark:text-blue-200 rounded">
                                            {responseTime.toFixed(2)}ms
                                        </span>
                                    )}
                                    {openPorts.length > 0 && (
                                        <span className="px-2 py-1 bg-purple-100 dark:bg-purple-900/30 text-purple-800 dark:text-purple-200 rounded">
                                            {openPorts.length} open ports
                                        </span>
                                    )}
                                    <span className="px-2 py-1 bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-400 rounded">
                                        {device.agent_id}
                                    </span>
                                </div>
                            </div>
                        );
                    })}
                    
                    {filteredDevices.length > 10 && (
                        <div className="text-center p-4 text-gray-600 dark:text-gray-400">
                            Showing first 10 of {filteredDevices.length} results. Use table view to see all.
                        </div>
                    )}
                </div>
            ) : (
                <div className="overflow-x-auto">
                    <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                        <thead className="bg-gray-50 dark:bg-gray-700">
                            <tr>
                                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                                    Host
                                </th>
                                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                                    Status
                                </th>
                                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                                    Response Time
                                </th>
                                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                                    Open Ports
                                </th>
                                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                                    Last Seen
                                </th>
                                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                                    Actions
                                </th>
                            </tr>
                        </thead>
                        <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                            {filteredDevices.map((device, index) => {
                                const metadata = parseMetadata(device.metadata);
                                const responseTime = typeof metadata.response_time_ns === 'number' ? metadata.response_time_ns / 1000000 : null;
                                let openPorts: PortResult[] = [];
                                const rawOpenPorts = metadata.port_results || metadata.open_ports;
                                
                                if (typeof rawOpenPorts === 'string') {
                                    try {
                                        openPorts = JSON.parse(rawOpenPorts);
                                    } catch {
                                        openPorts = [];
                                    }
                                } else if (Array.isArray(rawOpenPorts)) {
                                    openPorts = rawOpenPorts as PortResult[];
                                }
                                
                                const isExpanded = expandedRow === device.device_id;
                                
                                return (
                                    <React.Fragment key={device.device_id || index}>
                                        <tr className="hover:bg-gray-50 dark:hover:bg-gray-700/50">
                                            <td className="px-6 py-4 whitespace-nowrap">
                                                <div>
                                                    <div className="text-sm font-medium text-gray-900 dark:text-white">
                                                        {device.hostname || device.ip}
                                                    </div>
                                                    {device.ip !== (device.hostname || device.ip) && (
                                                        <div className="text-sm text-gray-500 dark:text-gray-400">
                                                            {device.ip}
                                                        </div>
                                                    )}
                                                </div>
                                            </td>
                                            <td className="px-6 py-4 whitespace-nowrap">
                                                <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${
                                                    device.is_available
                                                        ? 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-200'
                                                        : 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-200'
                                                }`}>
                                                    {device.is_available ? (
                                                        <CheckCircle className="w-3 h-3 mr-1" />
                                                    ) : (
                                                        <XCircle className="w-3 h-3 mr-1" />
                                                    )}
                                                    {device.is_available ? 'Available' : 'Unavailable'}
                                                </span>
                                            </td>
                                            <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900 dark:text-white">
                                                {responseTime ? `${responseTime.toFixed(2)}ms` : 'N/A'}
                                            </td>
                                            <td className="px-6 py-4 whitespace-nowrap">
                                                <div className="flex flex-wrap gap-1">
                                                    {openPorts.slice(0, 3).map((port, portIndex) => (
                                                        <span 
                                                            key={portIndex}
                                                            className="px-2 py-1 bg-blue-100 dark:bg-blue-900/30 text-blue-800 dark:text-blue-200 text-xs rounded"
                                                        >
                                                            {port.port}
                                                            {port.service && ` (${port.service})`}
                                                        </span>
                                                    ))}
                                                    {openPorts.length > 3 && (
                                                        <span className="px-2 py-1 bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-400 text-xs rounded">
                                                            +{openPorts.length - 3}
                                                        </span>
                                                    )}
                                                    {openPorts.length === 0 && (
                                                        <span className="text-gray-500 dark:text-gray-400 text-xs">None</span>
                                                    )}
                                                </div>
                                            </td>
                                            <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500 dark:text-gray-400">
                                                {new Date(device.last_seen).toLocaleString()}
                                            </td>
                                            <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                                                <button
                                                    onClick={() => setExpandedRow(isExpanded ? null : device.device_id)}
                                                    className="text-blue-600 hover:text-blue-900 dark:text-blue-400 dark:hover:text-blue-300"
                                                >
                                                    {isExpanded ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
                                                </button>
                                            </td>
                                        </tr>
                                        
                                        {isExpanded && (
                                            <tr>
                                                <td colSpan={6} className="px-6 py-4 bg-gray-50 dark:bg-gray-900/50">
                                                    <div className="space-y-3">
                                                        <div className="grid grid-cols-2 gap-4 text-sm">
                                                            <div>
                                                                <span className="font-medium text-gray-700 dark:text-gray-300">Device ID:</span>
                                                                <span className="ml-2 text-gray-600 dark:text-gray-400">{device.device_id}</span>
                                                            </div>
                                                            <div>
                                                                <span className="font-medium text-gray-700 dark:text-gray-300">Agent:</span>
                                                                <span className="ml-2 text-gray-600 dark:text-gray-400">{device.agent_id}</span>
                                                            </div>
                                                            <div>
                                                                <span className="font-medium text-gray-700 dark:text-gray-300">First Seen:</span>
                                                                <span className="ml-2 text-gray-600 dark:text-gray-400">{new Date(device.first_seen).toLocaleString()}</span>
                                                            </div>
                                                            {device.mac && (
                                                                <div>
                                                                    <span className="font-medium text-gray-700 dark:text-gray-300">MAC:</span>
                                                                    <span className="ml-2 text-gray-600 dark:text-gray-400">{device.mac}</span>
                                                                </div>
                                                            )}
                                                        </div>
                                                        
                                                        {openPorts.length > 0 && (
                                                            <div>
                                                                <h4 className="font-medium text-gray-700 dark:text-gray-300 mb-2">All Open Ports:</h4>
                                                                <div className="flex flex-wrap gap-1">
                                                                    {openPorts.map((port, portIndex) => (
                                                                        <span 
                                                                            key={portIndex}
                                                                            className="px-2 py-1 bg-blue-100 dark:bg-blue-900/30 text-blue-800 dark:text-blue-200 text-xs rounded"
                                                                        >
                                                                            {port.port}
                                                                            {port.service && ` (${port.service})`}
                                                                            {port.response_time && ` - ${(port.response_time / 1000000).toFixed(2)}ms`}
                                                                        </span>
                                                                    ))}
                                                                </div>
                                                            </div>
                                                        )}
                                                    </div>
                                                </td>
                                            </tr>
                                        )}
                                    </React.Fragment>
                                );
                            })}
                        </tbody>
                    </table>
                </div>
            )}
        </div>
    );
};

export default SweepResultsQueryTable;