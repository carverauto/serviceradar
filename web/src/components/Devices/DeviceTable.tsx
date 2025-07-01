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

import React, { useState, Fragment, useEffect, useMemo } from 'react';
import { CheckCircle, XCircle, ChevronDown, ChevronRight, ArrowUp, ArrowDown } from 'lucide-react';
import ReactJson from '@microlink/react-json-view';
import { Device } from '@/types/devices';
import SysmonStatusIndicator from './SysmonStatusIndicator';
import SNMPStatusIndicator from './SNMPStatusIndicator';
import ICMPSparkline from './ICMPSparkline';

type SortableKeys = 'ip' | 'hostname' | 'last_seen' | 'first_seen' | 'poller_id';

interface DeviceTableProps {
    devices: Device[];
    onSort?: (key: SortableKeys) => void;
    sortBy?: SortableKeys;
    sortOrder?: 'asc' | 'desc';
}

const DeviceTable: React.FC<DeviceTableProps> = ({ 
    devices,
    onSort,
    sortBy = 'last_seen',
    sortOrder = 'desc'
}) => {
    const [expandedRow, setExpandedRow] = useState<string | null>(null);
    const [sysmonStatuses, setSysmonStatuses] = useState<Record<string, { hasMetrics: boolean }>>({});
    const [sysmonStatusesLoading, setSysmonStatusesLoading] = useState(true);
    const [snmpStatuses, setSnmpStatuses] = useState<Record<string, { hasMetrics: boolean }>>({});
    const [snmpStatusesLoading, setSnmpStatusesLoading] = useState(true);
    const [icmpStatuses, setIcmpStatuses] = useState<Record<string, { hasMetrics: boolean }>>({});
    const [icmpStatusesLoading, setIcmpStatusesLoading] = useState(true);

    // Create a stable reference for device IDs
    const deviceIdsString = useMemo(() => {
        return devices.map(device => device.device_id).sort().join(',');
    }, [devices]);

    useEffect(() => {
        if (!devices || devices.length === 0) return;

        const deviceIds = devices.map(device => device.device_id);
        console.log(`DeviceTable useEffect triggered with ${devices.length} devices: ${deviceIds.slice(0, 3).join(', ')}...`);

        const fetchSysmonStatuses = async () => {
            setSysmonStatusesLoading(true);
            try {
                console.log(`DeviceTable: Fetching sysmon status for ${deviceIds.length} devices`);
                const response = await fetch('/api/devices/sysmon/status', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify({ deviceIds }),
                });

                if (response.ok) {
                    const data = await response.json();
                    setSysmonStatuses(data.statuses || {});
                } else {
                    console.error('Failed to fetch bulk sysmon statuses:', response.status);
                }
            } catch (error) {
                console.error('Error fetching bulk sysmon statuses:', error);
            } finally {
                setSysmonStatusesLoading(false);
            }
        };

        const fetchSnmpStatuses = async () => {
            setSnmpStatusesLoading(true);
            try {
                console.log(`DeviceTable: Fetching SNMP status for ${deviceIds.length} devices`);
                const response = await fetch('/api/devices/snmp/status', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify({ deviceIds }),
                });

                if (response.ok) {
                    const data = await response.json();
                    setSnmpStatuses(data.statuses || {});
                } else {
                    console.error('Failed to fetch bulk SNMP statuses:', response.status);
                }
            } catch (error) {
                console.error('Error fetching bulk SNMP statuses:', error);
            } finally {
                setSnmpStatusesLoading(false);
            }
        };

        const fetchIcmpStatuses = async () => {
            setIcmpStatusesLoading(true);
            try {
                console.log(`DeviceTable: Fetching ICMP status for ${deviceIds.length} devices:`, deviceIds);
                const response = await fetch('/api/devices/icmp/status', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify({ deviceIds }),
                });

                if (response.ok) {
                    const data = await response.json();
                    setIcmpStatuses(data.statuses || {});
                } else {
                    console.error('Failed to fetch bulk ICMP statuses:', response.status);
                }
            } catch (error) {
                console.error('Error fetching bulk ICMP statuses:', error);
            } finally {
                setIcmpStatusesLoading(false);
            }
        };

        fetchSysmonStatuses();
        fetchSnmpStatuses();
        fetchIcmpStatuses();
    }, [deviceIdsString]);

    const getSourceColor = (source: string) => {
        const lowerSource = source.toLowerCase();
        if (lowerSource.includes('netbox')) return 'bg-blue-600/50 text-blue-200';
        if (lowerSource.includes('sweep')) return 'bg-green-600/50 text-green-200';
        if (lowerSource.includes('mapper')) return 'bg-green-600/50 text-green-200';
        if (lowerSource.includes('unifi')) return 'bg-sky-600/50 text-sky-200';
        return 'bg-gray-600/50 text-gray-200';
    };

    const formatDate = (dateString: string) => {
        try {
            return new Date(dateString).toLocaleString();
        } catch {
            return 'Invalid Date';
        }
    };

    const TableHeader = ({ aKey, label }: { aKey: SortableKeys; label: string }) => (
        <th 
            scope="col"
            className={`px-6 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider ${onSort ? 'cursor-pointer' : ''}`}
            onClick={() => onSort && onSort(aKey)}
        >
            <div className="flex items-center">
                {label}
                {onSort && sortBy === aKey && (
                    sortOrder === 'asc' ? <ArrowUp className="ml-1 h-3 w-3"/> : <ArrowDown className="ml-1 h-3 w-3"/>
                )}
            </div>
        </th>
    );

    if (!devices || devices.length === 0) {
        return (
            <div className="text-center p-8 text-gray-400">
                No devices found.
            </div>
        );
    }

    return (
        <div className="overflow-x-auto">
            <table className="min-w-full divide-y divide-gray-700">
                <thead className="bg-gray-800/50">
                    <tr>
                        <th scope="col" className="w-12"></th>
                        <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider">
                            Status
                        </th>
                        <TableHeader aKey="ip" label="Device" />
                        <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider">
                            Sources
                        </th>
                        <TableHeader aKey="poller_id" label="Poller" />
                        <TableHeader aKey="last_seen" label="Last Seen" />
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
                                            <ChevronDown className="h-5 w-5 text-gray-400" /> : 
                                            <ChevronRight className="h-5 w-5 text-gray-400" />
                                        }
                                    </button>
                                </td>
                                <td className="px-6 py-4 whitespace-nowrap">
                                    <div className="flex items-center gap-2">
                                        {device.is_available ? 
                                            <CheckCircle className="h-5 w-5 text-green-500" /> : 
                                            <XCircle className="h-5 w-5 text-red-500" />
                                        }
                                        <SysmonStatusIndicator 
                                            deviceId={device.device_id} 
                                            compact={true}
                                            hasMetrics={sysmonStatusesLoading ? undefined : sysmonStatuses[device.device_id]?.hasMetrics}
                                        />
                                        <SNMPStatusIndicator 
                                            deviceId={device.device_id} 
                                            compact={true}
                                            hasMetrics={snmpStatusesLoading ? undefined : snmpStatuses[device.device_id]?.hasMetrics}
                                        />
                                        <ICMPSparkline 
                                            deviceId={device.device_id} 
                                            compact={false}
                                            hasMetrics={icmpStatusesLoading ? undefined : icmpStatuses[device.device_id]?.hasMetrics}
                                        />
                                    </div>
                                </td>
                                <td className="px-6 py-4 whitespace-nowrap">
                                    <div className="text-sm font-medium text-white">
                                        {device.hostname || device.ip}
                                    </div>
                                    <div className="text-sm text-gray-400">
                                        {device.hostname ? device.ip : device.mac}
                                    </div>
                                </td>
                                <td className="px-6 py-4 whitespace-nowrap">
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
                                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-300">
                                    {device.poller_id}
                                </td>
                                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-300">
                                    {formatDate(device.last_seen)}
                                </td>
                            </tr>
                            {expandedRow === device.device_id && (
                                <tr className="bg-gray-800/50">
                                    <td colSpan={6} className="p-0">
                                        <div className="p-4">
                                            <h4 className="text-md font-semibold text-white mb-2">
                                                Metadata
                                            </h4>
                                            <ReactJson
                                                src={device.metadata}
                                                theme="pop"
                                                collapsed={false}
                                                displayDataTypes={false}
                                                enableClipboard={true}
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
        </div>
    );
};

export default DeviceTable;