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
import React, { useState, useEffect, useCallback } from 'react';
import { useAuth } from '@/components/AuthProvider';
import { Device, Pagination, DevicesApiResponse } from '@/types/devices';
import { cachedQuery } from '@/lib/cached-query';
import {Server, Search, Loader2, AlertTriangle, CheckCircle, XCircle} from 'lucide-react';
import DeviceTable from './DeviceTable';
import { useDebounce } from 'use-debounce';
type SortableKeys = 'ip' | 'hostname' | 'last_seen' | 'first_seen' | 'poller_id';
const StatCard = ({ title, value, icon, isLoading, colorScheme = 'blue' }: { title: string; value: string | number; icon: React.ReactNode; isLoading: boolean; colorScheme?: 'blue' | 'green' | 'red' }) => {
    const bgColors = {
        blue: 'bg-blue-50 dark:bg-blue-900/30',
        green: 'bg-green-50 dark:bg-green-900/30',
        red: 'bg-red-50 dark:bg-red-900/30'
    };
    
    return (
        <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 p-4 rounded-lg">
            <div className="flex items-center">
                <div className={`p-3 ${bgColors[colorScheme]} rounded-lg mr-4`}>{icon}</div>
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
};
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
                cachedQuery<{ results: [{ total: number }] }>('in:devices stats:"count() as total" sort:total:desc time:last_7d', token || undefined, 30000),
                cachedQuery<{ results: [{ total: number }] }>('in:devices is_available:true stats:"count() as total" sort:total:desc time:last_7d', token || undefined, 30000),
                cachedQuery<{ results: [{ total: number }] }>('in:devices is_available:false stats:"count() as total" sort:total:desc time:last_7d', token || undefined, 30000),
            ]);
            console.log('Device stats response:', {
                total: totalRes.results[0]?.total,
                online: onlineRes.results[0]?.total,
                offline: offlineRes.results[0]?.total
            });
            setStats({
                total: totalRes.results[0]?.total || 0,
                online: onlineRes.results[0]?.total || 0,
                offline: offlineRes.results[0]?.total || 0,
            });
        } catch (e) {
            console.error("Failed to fetch stats:", e);
        } finally {
            setStatsLoading(false);
        }
    }, [token]);

    const fetchDevices = useCallback(async (cursor?: string, direction?: 'next' | 'prev') => {
        setDevicesLoading(true);
        setError(null);
        try {
            const queryParts = [
                'in:devices',
                'time:last_7d',
                `sort:${sortBy}:${sortOrder}`,
                'limit:20'
            ];

            if (filterStatus !== 'all') {
                queryParts.push(`is_available:${filterStatus === 'online'}`);
            }

            if (debouncedSearchTerm) {
                const escapedTerm = debouncedSearchTerm.replace(/"/g, '\\"');
                queryParts.push(`hostname:%${escapedTerm}%`);
            }

            const query = queryParts.join(' ');

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


    return (
        <div className="space-y-6">
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                <StatCard title="Total Devices" value={stats.total.toLocaleString()}
                          icon={<Server className="h-6 w-6 text-blue-600 dark:text-blue-400"/>} 
                          isLoading={statsLoading}
                          colorScheme="blue"/>
                <StatCard title="Online" value={stats.online.toLocaleString()}
                          icon={<CheckCircle className="h-6 w-6 text-green-600 dark:text-green-400"/>} 
                          isLoading={statsLoading}
                          colorScheme="green"/>
                <StatCard title="Offline" value={stats.offline.toLocaleString()}
                          icon={<XCircle className="h-6 w-6 text-red-600 dark:text-red-400"/>} 
                          isLoading={statsLoading}
                          colorScheme="red"/>
            </div>

            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg shadow-lg">
                <div
                    className="p-4 flex flex-col md:flex-row gap-4 justify-between items-center border-b border-gray-700">
                    <div className="relative w-full md:w-1/3">
                        <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 h-5 w-5 text-gray-400"/>
                        <input
                            type="text"
                            placeholder="Search by IP, hostname, or ID..."
                            value={searchTerm}
                            onChange={(e) => setSearchTerm(e.target.value)}
                            className="w-full pl-10 pr-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-green-500 focus:border-green-500"
                        />
                    </div>
                    <div className="flex items-center gap-4">
                        <label htmlFor="statusFilter" className="text-sm text-gray-600 dark:text-gray-300">Status:</label>
                        <select
                            id="statusFilter"
                            value={filterStatus}
                            onChange={(e) => setFilterStatus(e.target.value as 'all' | 'online' | 'offline')}
                            className="border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white px-3 py-2 focus:ring-green-500 focus:border-green-500"
                        >
                            <option value="all">All</option>
                            <option value="online">Online</option>
                            <option value="offline">Offline</option>
                        </select>
                    </div>
                </div>

                {devicesLoading ? (
                    <div className="text-center p-8">
                        <Loader2 className="h-8 w-8 text-gray-400 animate-spin mx-auto"/>
                    </div>
                ) : error ? (
                    <div className="text-center p-8 text-red-400">
                        <AlertTriangle className="mx-auto h-6 w-6 mb-2"/>
                        {error}
                    </div>
                ) : (
                    <DeviceTable 
                        devices={devices}
                        onSort={handleSort}
                        sortBy={sortBy}
                        sortOrder={sortOrder}
                    />
                )}

                {pagination && (pagination.prev_cursor || pagination.next_cursor) && (
                    <div className="p-4 flex items-center justify-between border-t border-gray-700">
                        <button
                            onClick={() => fetchDevices(pagination.prev_cursor, 'prev')}
                            disabled={!pagination.prev_cursor || devicesLoading}
                            className="px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-white rounded-md disabled:opacity-50 disabled:cursor-not-allowed"
                        >
                            Previous
                        </button>
                        <button
                            onClick={() => fetchDevices(pagination.next_cursor, 'next')}
                            disabled={!pagination.next_cursor || devicesLoading}
                            className="px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-white rounded-md disabled:opacity-50 disabled:cursor-not-allowed"
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
