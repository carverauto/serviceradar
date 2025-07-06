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

import React, { useState, Fragment, useMemo } from 'react';
import { CheckCircle, XCircle, ChevronDown, ChevronRight } from 'lucide-react';
import ReactJson from '@microlink/react-json-view';

export interface NetworkInterface {
    name?: string; // Preferred display name (if_name or if_descr)
    ip_address?: string; // First IP from ip_addresses array
    mac_address?: string; // from 'if_phys_address'
    status?: string; // 'up', 'down', etc. (derived from if_oper_status)
    type?: string; // from 'if_type' (OID) or 'if_descr')
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
    // Re-added index signature
    [key: string]: unknown;
}

interface InterfaceTableProps {
    interfaces: NetworkInterface[];
    showDeviceColumn?: boolean;
    jsonViewTheme?: 'rjv-default' | 'pop';
    itemsPerPage?: number;
}

const InterfaceTable: React.FC<InterfaceTableProps> = ({ 
    interfaces, 
    showDeviceColumn = false,
    jsonViewTheme = 'pop',
    itemsPerPage = 20
}) => {
    const [expandedRow, setExpandedRow] = useState<string | null>(null);
    const [currentPage, setCurrentPage] = useState(1);

    const getStatusColor = (status?: string) => {
        const s = status?.toLowerCase() || '';
        if (s === 'active' || s === 'online' || s === 'up') return 'text-green-500';
        if (s === 'inactive' || s === 'offline' || s === 'down') return 'text-red-500';
        return 'text-gray-500';
    };

    const processRawInterface = (item: Record<string, unknown>): NetworkInterface => {
        // Handle both camelCase (SHOW INTERFACES) and snake_case (LAN Discovery) properties
        const operStatus = (item.ifOperStatus || item.if_oper_status) as number;
        const adminStatus = (item.ifAdminStatus || item.if_admin_status) as number;
        const index = (item.ifIndex || item.if_index) as number;
        const name = (item.ifName || item.if_name) as string;
        const descr = (item.ifDescr || item.if_descr) as string;
        const physAddr = (item.ifPhysAddress || item.if_phys_address) as string;
        const speed = (item.ifSpeed || item.if_speed) as number | { value?: number };
        
        // Status mapping from SNMP operational status
        let ifaceStatus = 'unknown';
        switch (operStatus) {
            case 1: ifaceStatus = 'up'; break;
            case 2: ifaceStatus = 'down'; break;
            case 3: ifaceStatus = 'testing'; break;
            case 4: ifaceStatus = 'unknown'; break;
            case 5: ifaceStatus = 'dormant'; break;
            case 6: ifaceStatus = 'notPresent'; break;
            case 7: ifaceStatus = 'lowerLayerDown'; break;
            default: ifaceStatus = (item.status as string) || 'unknown'; break;
        }

        // Speed formatting
        let rawSpeedValue: number | undefined;
        if (typeof speed === 'object' && speed !== null && typeof speed.value === 'number') {
            rawSpeedValue = speed.value;
        } else if (typeof speed === 'number') {
            rawSpeedValue = speed;
        }

        let formattedSpeed = (item.speed as string) || 'N/A';
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

        return {
            name: (item.name as string) || name || descr || `Interface ${index || 'N/A'}`,
            ip_address: (item.ip_address as string) || (Array.isArray(item.ip_addresses) && item.ip_addresses.length > 0 ? item.ip_addresses[0] : undefined),
            mac_address: (item.mac_address as string) || physAddr || '-',
            status: ifaceStatus,
            type: (item.type as string) || (item.metadata as { if_type?: string })?.if_type || descr,
            speed: formattedSpeed,
            device_ip: item.device_ip as string,
            // Normalize to snake_case for consistency
            if_name: name,
            if_descr: descr,
            if_index: index,
            if_admin_status: adminStatus,
            if_oper_status: operStatus,
            if_phys_address: physAddr,
            if_speed: speed,
            ip_addresses: item.ip_addresses as string[],
            metadata: item.metadata as Record<string, unknown>,
            // Keep original camelCase properties for completeness
            ifName: item.ifName,
            ifDescr: item.ifDescr,
            ifIndex: item.ifIndex,
            ifAdminStatus: item.ifAdminStatus,
            ifOperStatus: item.ifOperStatus,
            ifPhysAddress: item.ifPhysAddress,
            ifSpeed: item.ifSpeed,
            ...item
        };
    };

    // Process interfaces to ensure they have the right format
    const processedInterfaces = interfaces.map(processRawInterface);

    // Pagination logic
    const totalPages = Math.ceil(processedInterfaces.length / itemsPerPage);
    const paginatedInterfaces = useMemo(() => {
        const startIndex = (currentPage - 1) * itemsPerPage;
        return processedInterfaces.slice(startIndex, startIndex + itemsPerPage);
    }, [processedInterfaces, currentPage, itemsPerPage]);

    const handlePageChange = (page: number) => {
        setCurrentPage(page);
        setExpandedRow(null); // Close any expanded rows when changing pages
    };

    if (!processedInterfaces || processedInterfaces.length === 0) {
        return (
            <div className="text-center p-8 text-gray-600 dark:text-gray-400">
                No interfaces found.
            </div>
        );
    }

    return (
        <div className="overflow-x-auto">
            <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                <thead className="bg-gray-50 dark:bg-gray-800/50">
                    <tr>
                        <th scope="col" className="w-12"></th>
                        {showDeviceColumn && (
                            <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                                Device
                            </th>
                        )}
                        <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                            Interface
                        </th>
                        <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                            IP Address
                        </th>
                        <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                            MAC Address
                        </th>
                        <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                            Speed
                        </th>
                        <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                            Status
                        </th>
                    </tr>
                </thead>
                <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                    {paginatedInterfaces.map((iface, index) => {
                        const rowKey = `${iface.device_ip || 'no-ip'}-${iface.if_index ?? index}-${iface.mac_address || 'no-mac'}`;
                        return (
                            <Fragment key={rowKey}>
                                <tr className="hover:bg-gray-100 dark:hover:bg-gray-700/30">
                                    <td className="pl-4">
                                        <button
                                            onClick={() => setExpandedRow(expandedRow === rowKey ? null : rowKey)}
                                            className="p-1 rounded-full hover:bg-gray-200 dark:hover:bg-gray-600"
                                        >
                                            {expandedRow === rowKey ? 
                                                <ChevronDown className="h-5 w-5 text-gray-600 dark:text-gray-400" /> : 
                                                <ChevronRight className="h-5 w-5 text-gray-600 dark:text-gray-400" />
                                            }
                                        </button>
                                    </td>
                                    {showDeviceColumn && (
                                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300">
                                            {iface.device_ip || '-'}
                                        </td>
                                    )}
                                    <td className="px-6 py-4 whitespace-nowrap">
                                        <div className="text-sm font-medium text-gray-900 dark:text-white">
                                            {iface.name}
                                        </div>
                                        {iface.if_descr && iface.if_descr !== iface.name && (
                                            <div className="text-sm text-gray-600 dark:text-gray-400">
                                                {iface.if_descr}
                                            </div>
                                        )}
                                        {iface.if_index && (
                                            <div className="text-xs text-gray-600 dark:text-gray-500">
                                                Index: {iface.if_index}
                                            </div>
                                        )}
                                    </td>
                                    <td className="px-6 py-4 whitespace-nowrap text-sm font-mono text-gray-700 dark:text-gray-300">
                                        {iface.ip_address || '-'}
                                    </td>
                                    <td className="px-6 py-4 whitespace-nowrap text-sm font-mono text-gray-700 dark:text-gray-300">
                                        {iface.mac_address || '-'}
                                    </td>
                                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-300">
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
                                {expandedRow === rowKey && (
                                    <tr className="bg-gray-100 dark:bg-gray-800/50">
                                        <td colSpan={showDeviceColumn ? 7 : 6} className="p-0">
                                            <div className="p-4">
                                                <h4 className="text-md font-semibold text-gray-900 dark:text-white mb-2">
                                                    Interface Details
                                                </h4>
                                                <div className="grid grid-cols-2 gap-4 mb-4">
                                                    {iface.type && (
                                                        <div>
                                                            <span className="text-sm text-gray-600 dark:text-gray-400">Type:</span>
                                                            <span className="text-sm text-gray-800 dark:text-gray-200 ml-2">
                                                                {iface.type}
                                                            </span>
                                                        </div>
                                                    )}
                                                    {iface.mtu && (
                                                        <div>
                                                            <span className="text-sm text-gray-600 dark:text-gray-400">MTU:</span>
                                                            <span className="text-sm text-gray-800 dark:text-gray-200 ml-2">
                                                                {iface.mtu}
                                                            </span>
                                                        </div>
                                                    )}
                                                    {iface.duplex && (
                                                        <div>
                                                            <span className="text-sm text-gray-600 dark:text-gray-400">Duplex:</span>
                                                            <span className="text-sm text-gray-800 dark:text-gray-200 ml-2">
                                                                {iface.duplex}
                                                            </span>
                                                        </div>
                                                    )}
                                                    {iface.if_admin_status !== undefined && (
                                                        <div>
                                                            <span className="text-sm text-gray-600 dark:text-gray-400">Admin Status:</span>
                                                            <span className="text-sm text-gray-800 dark:text-gray-200 ml-2">
                                                                {iface.if_admin_status === 1 ? 'Up' : 
                                                                 iface.if_admin_status === 2 ? 'Down' : 
                                                                 iface.if_admin_status === 3 ? 'Testing' : 
                                                                 'Unknown'}
                                                            </span>
                                                        </div>
                                                    )}
                                                    {Array.isArray(iface.ip_addresses) && iface.ip_addresses.length > 1 && (
                                                        <div className="col-span-2">
                                                            <span className="text-sm text-gray-600 dark:text-gray-400">All IP Addresses:</span>
                                                            <div className="text-sm text-gray-800 dark:text-gray-200 ml-2">
                                                                {iface.ip_addresses.join(', ')}
                                                            </div>
                                                        </div>
                                                    )}
                                                </div>
                                                {iface.metadata && Object.keys(iface.metadata).length > 0 && (
                                                    <>
                                                        <h4 className="text-md font-semibold text-gray-900 dark:text-white mb-2">
                                                            Metadata
                                                        </h4>
                                                        <ReactJson
                                                            src={iface.metadata}
                                                            theme={jsonViewTheme}
                                                            collapsed={false}
                                                            displayDataTypes={false}
                                                            enableClipboard={true}
                                                            style={{
                                                                padding: '1rem',
                                                                borderRadius: '0.375rem',
                                                                backgroundColor: '#1C1B22'
                                                            }}
                                                        />
                                                    </>
                                                )}
                                            </div>
                                        </td>
                                    </tr>
                                )}
                            </Fragment>
                        );
                    })}
                </tbody>
            </table>

            {/* Pagination Controls */}
            {totalPages > 1 && (
                <div className="flex items-center justify-between px-6 py-3 border-t border-gray-200 dark:border-gray-700">
                    <div className="flex items-center text-sm text-gray-600 dark:text-gray-400">
                        Showing {(currentPage - 1) * itemsPerPage + 1}-{Math.min(currentPage * itemsPerPage, processedInterfaces.length)} of {processedInterfaces.length} interfaces
                    </div>
                    <div className="flex items-center space-x-2">
                        <button
                            onClick={() => handlePageChange(currentPage - 1)}
                            disabled={currentPage === 1}
                            className="px-3 py-1 text-sm border border-gray-300 dark:border-gray-600 rounded-md bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-gray-200 hover:bg-gray-300 dark:hover:bg-gray-600 disabled:opacity-50 disabled:cursor-not-allowed"
                        >
                            Previous
                        </button>
                        
                        {/* Page numbers */}
                        <div className="flex items-center space-x-1">
                            {Array.from({ length: Math.min(5, totalPages) }, (_, i) => {
                                let pageNum;
                                if (totalPages <= 5) {
                                    pageNum = i + 1;
                                } else if (currentPage <= 3) {
                                    pageNum = i + 1;
                                } else if (currentPage >= totalPages - 2) {
                                    pageNum = totalPages - 4 + i;
                                } else {
                                    pageNum = currentPage - 2 + i;
                                }
                                
                                return (
                                    <button
                                        key={pageNum}
                                        onClick={() => handlePageChange(pageNum)}
                                        className={`px-3 py-1 text-sm border border-gray-600 rounded-md ${
                                            currentPage === pageNum
                                                ? 'bg-blue-600 text-white border-blue-600'
                                                : 'bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-gray-200 hover:bg-gray-300 dark:hover:bg-gray-600'
                                        }`}
                                    >
                                        {pageNum}
                                    </button>
                                );
                            })}
                        </div>

                        <button
                            onClick={() => handlePageChange(currentPage + 1)}
                            disabled={currentPage === totalPages}
                            className="px-3 py-1 text-sm border border-gray-300 dark:border-gray-600 rounded-md bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-gray-200 hover:bg-gray-300 dark:hover:bg-gray-600 disabled:opacity-50 disabled:cursor-not-allowed"
                        >
                            Next
                        </button>
                    </div>
                </div>
            )}
        </div>
    );
};

export default InterfaceTable;