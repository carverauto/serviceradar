/*
* Copyright 2025 Carver Automation Corporation.
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
* http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/
'use client';
import React, { useState, useEffect, useCallback, useMemo, Fragment } from 'react';
import { useAuth } from '@/components/AuthProvider';
import { Device, Pagination, DevicesApiResponse } from '@/types/devices';
import { Server, CheckCircle, XCircle, ChevronDown, ChevronRight, Search, Loader2, AlertTriangle, ArrowUp, ArrowDown } from 'lucide-react';
import ReactJson from '@microlink/react-json-view';
import { useDebounce } from 'use-debounce';
type SortableKeys = 'ip' | 'hostname' | 'last_seen' | 'first_seen' | 'poller_id';
const StatCard = ({ title, value, icon, isLoading }: { title: string; value: string | number; icon: React.ReactNode; isLoading: boolean }) => (
    <div className="bg-[#25252e] border border-gray-700 p-4 rounded-lg">
        <div className="flex items-center">
            <div className="p-2 bg-gray-700/50 rounded-md mr-4">{icon}</div>
            <div>
                <p className="text-sm text-gray-400">{title}</p>
                {isLoading ? (
                    <div className="h-7 w-20 bg-gray-700 rounded-md animate-pulse mt-1"></div>
                ) : (
                    <p className="text-2xl font-bold text-white">{value}</p>
                )}
            </div>
        </div>
    </div>
);
const Dashboard = () => {
    const {token} = useAuth();
    const [devices, setDevices] = useState<Device[]>([]);
    const [pagination, setPagination] = useState<Pagination | null>(null);
    const [stats, setStats] = useState({
        total: 0,
        online: 0,
        offline: 0
    });
    const [statsLoading, setStatsLoading] = useState(true);
    const [devicesLoading, setDevicesLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);
    const [searchTerm, setSearchTerm] = useState('');
    const [debouncedSearchTerm] = useDebounce(searchTerm, 300);
    const [filterStatus, setFilterStatus] = useState<'all' | 'online' | 'offline'>('all');
    const [sortBy, setSortBy] = useState<SortableKeys>('last_seen');
    const [sortOrder, setSortOrder] = useState<'asc' | 'desc'>('desc');
    const [expandedRow, setExpandedRow] = useState<string | null>(null);
    const postQuery = useCallback(async <T, >(query: string, cursor?: string, direction?: 'next' | 'prev'): Promise<T> => {
        const body: Record<string, unknown> = {
            query,
            limit: 20
        };
        if (cursor) body.cursor = cursor;
        if (direction) body.direction = direction;

        const response = await fetch('/api/query', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                ...(token && {Authorization: `Bearer ${token}`}),
            },
            body: JSON.stringify(body),
            cache: 'no-store',
        });

        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.error || 'Failed to execute query');
        }
        return response.json();
    }, [token]);

    const fetchStats = useCallback(async () => {
        setStatsLoading(true);
        try {
            const [totalRes, onlineRes, offlineRes] = await Promise.all([
                postQuery<{
                    results: [{
                        'count()': number
                    }]
                }>('COUNT DEVICES'),
                postQuery<{
                    results: [{
                        'count()': number
                    }]
                }>('COUNT DEVICES WHERE is_available = true'),
                postQuery<{
                    results: [{
                        'count()': number
                    }]
                }>('COUNT DEVICES WHERE is_available = false'),
            ]);
            setStats({
                total: totalRes.results[0]?.['count()'] || 0,
                online: onlineRes.results[0]?.['count()'] || 0,
                offline: offlineRes.results[0]?.['count()'] || 0,
            });
        } catch (e) {
            console.error("Failed to fetch stats:", e);
        } finally {
            setStatsLoading(false);
        }
    }, [postQuery]);

    const fetchDevices = useCallback(async (cursor?: string, direction?: 'next' | 'prev') => {
        setDevicesLoading(true);
        setError(null);
        try {
            let query = 'SHOW DEVICES';
            const whereClauses: string[] = [];

            if (debouncedSearchTerm) {
                whereClauses.push(`(ip LIKE '%${debouncedSearchTerm}%' OR hostname LIKE '%${debouncedSearchTerm}%' OR device_id LIKE '%${debouncedSearchTerm}%')`);
            }
            if (filterStatus !== 'all') {
                whereClauses.push(`is_available = ${filterStatus === 'online'}`);
            }

            if (whereClauses.length > 0) {
                query += ` WHERE ${whereClauses.join(' AND ')}`;
            }

            query += ` ORDER BY ${sortBy} ${sortOrder.toUpperCase()}`;

            const data = await postQuery<DevicesApiResponse>(query, cursor, direction);
            setDevices(data.results || []);
            setPagination(data.pagination || null);
        } catch (e) {
            setError(e instanceof Error ? e.message : "An unknown error occurred.");
            setDevices([]);
            setPagination(null);
        } finally {
            setDevicesLoading(false);
        }
    }, [postQuery, debouncedSearchTerm, filterStatus, sortBy, sortOrder]);

    useEffect(() => {
        fetchStats();
    }, [fetchStats]);

    useEffect(() => {
        fetchDevices();
    }, [fetchDevices]);

    const handleSort = (key: SortableKeys) => {
        if (sortBy === key) {
            setSortOrder(sortOrder === 'asc' ? 'desc' : 'asc');
        } else {
            setSortBy(key);
            setSortOrder('desc');
        }
    };

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

    const TableHeader = ({
                             aKey,
                             label
                         }: {
        aKey: SortableKeys;
        label: string
    }) => (
        <th scope="col"
            className="px-6 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider cursor-pointer"
            onClick={() => handleSort(aKey)}>
            <div className="flex items-center">
                {label}
                {sortBy === aKey && (
                    sortOrder === 'asc' ? <ArrowUp className="ml-1 h-3 w-3"/> : <ArrowDown className="ml-1 h-3 w-3"/>
                )}
            </div>
        </th>
    );

    return (
        <div className="space-y-6">
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                <StatCard title="Total Devices" value={stats.total.toLocaleString()}
                          icon={<Server className="h-6 w-6 text-gray-300"/>} isLoading={statsLoading}/>
                <StatCard title="Online" value={stats.online.toLocaleString()}
                          icon={<CheckCircle className="h-6 w-6 text-green-400"/>} isLoading={statsLoading}/>
                <StatCard title="Offline" value={stats.offline.toLocaleString()}
                          icon={<XCircle className="h-6 w-6 text-red-400"/>} isLoading={statsLoading}/>
            </div>

            <div className="bg-[#25252e] border border-gray-700 rounded-lg shadow-lg">
                <div
                    className="p-4 flex flex-col md:flex-row gap-4 justify-between items-center border-b border-gray-700">
                    <div className="relative w-full md:w-1/3">
                        <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 h-5 w-5 text-gray-400"/>
                        <input
                            type="text"
                            placeholder="Search by IP, hostname, or ID..."
                            value={searchTerm}
                            onChange={(e) => setSearchTerm(e.target.value)}
                            className="w-full pl-10 pr-4 py-2 border border-gray-600 rounded-lg bg-[#1C1B22] text-white focus:ring-green-500 focus:border-green-500"
                        />
                    </div>
                    <div className="flex items-center gap-4">
                        <label htmlFor="statusFilter" className="text-sm text-gray-300">Status:</label>
                        <select
                            id="statusFilter"
                            value={filterStatus}
                            onChange={(e) => setFilterStatus(e.target.value as 'all' | 'online' | 'offline')}
                            className="border border-gray-600 rounded-lg bg-[#1C1B22] text-white px-3 py-2 focus:ring-green-500 focus:border-green-500"
                        >
                            <option value="all">All</option>
                            <option value="online">Online</option>
                            <option value="offline">Offline</option>
                        </select>
                    </div>
                </div>

                <div className="overflow-x-auto">
                    <table className="min-w-full divide-y divide-gray-700">
                        <thead className="bg-gray-800/50">
                        <tr>
                            <th scope="col" className="w-12"></th>
                            <th scope="col"
                                className="px-6 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider">Status
                            </th>
                            <TableHeader aKey="ip" label="Device"/>
                            <th scope="col"
                                className="px-6 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider">Sources
                            </th>
                            <TableHeader aKey="poller_id" label="Poller"/>
                            <TableHeader aKey="last_seen" label="Last Seen"/>
                        </tr>
                        </thead>
                        <tbody className="bg-[#25252e] divide-y divide-gray-700">
                        {devicesLoading ? (
                            <tr>
                                <td colSpan={6} className="text-center p-8"><Loader2
                                    className="h-8 w-8 text-gray-400 animate-spin mx-auto"/></td>
                            </tr>
                        ) : error ? (
                            <tr>
                                <td colSpan={6} className="text-center p-8 text-red-400"><AlertTriangle
                                    className="mx-auto h-6 w-6 mb-2"/>{error}</td>
                            </tr>
                        ) : devices.length === 0 ? (
                            <tr>
                                <td colSpan={6} className="text-center p-8 text-gray-400">No devices found.</td>
                            </tr>
                        ) : (
                            devices.map(device => (
                                <Fragment key={device.device_id}>
                                    <tr className="hover:bg-gray-700/30">
                                        <td className="pl-4">
                                            <button
                                                onClick={() => setExpandedRow(expandedRow === device.device_id ? null : device.device_id)}
                                                className="p-1 rounded-full hover:bg-gray-600">
                                                {expandedRow === device.device_id ? <ChevronDown className="h-5 w-5"/> :
                                                    <ChevronRight className="h-5 w-5"/>}
                                            </button>
                                        </td>
                                        <td className="px-6 py-4 whitespace-nowrap">
                                            {device.is_available ? <CheckCircle className="h-5 w-5 text-green-500"/> :
                                                <XCircle className="h-5 w-5 text-red-500"/>}
                                        </td>
                                        <td className="px-6 py-4 whitespace-nowrap">
                                            <div
                                                className="text-sm font-medium text-white">{device.hostname || device.ip}</div>
                                            <div
                                                className="text-sm text-gray-400">{device.hostname ? device.ip : device.mac}</div>
                                        </td>
                                        <td className="px-6 py-4 whitespace-nowrap">
                                            <div className="flex flex-wrap gap-1">
                                                {device.discovery_sources.map(source => (
                                                    <span key={source}
                                                          className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${getSourceColor(source)}`}>
                                                        {source}
                                                    </span>
                                                ))}
                                            </div>
                                        </td>
                                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-300">{device.poller_id}</td>
                                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-300">{formatDate(device.last_seen)}</td>
                                    </tr>
                                    {expandedRow === device.device_id && (
                                        <tr className="bg-gray-800/50">
                                            <td colSpan={6} className="p-0">
                                                <div className="p-4">
                                                    <h4 className="text-md font-semibold text-white mb-2">Metadata</h4>
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
                            ))
                        )}
                        </tbody>
                    </table>
                </div>

                {pagination && (pagination.prev_cursor || pagination.next_cursor) && (
                    <div className="p-4 flex items-center justify-between border-t border-gray-700">
                        <button
                            onClick={() => fetchDevices(pagination.prev_cursor, 'prev')}
                            disabled={!pagination.prev_cursor || devicesLoading}
                            className="px-4 py-2 bg-gray-700 text-white rounded-md disabled:opacity-50 disabled:cursor-not-allowed"
                        >
                            Previous
                        </button>
                        <button
                            onClick={() => fetchDevices(pagination.next_cursor, 'next')}
                            disabled={!pagination.next_cursor || devicesLoading}
                            className="px-4 py-2 bg-gray-700 text-white rounded-md disabled:opacity-50 disabled:cursor-not-allowed"
                        >
                            Next
                        </button>
                    </div>
                )}
            </div>
        </div>
    );
}

export default Dashboard;