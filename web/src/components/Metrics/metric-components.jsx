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

import React from 'react';
import { Cpu, HardDrive, BarChart3, Activity } from 'lucide-react';
import { AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, BarChart, Bar, ResponsiveContainer, ReferenceLine } from 'recharts';
import { MetricCard, CustomTooltip, ProgressBar } from './shared-components';

export const CpuCard = ({ data }) => {
    return (
        <MetricCard
            title="CPU Usage"
            current={data.current}
            unit={data.unit}
            warning={data.warning}
            critical={data.critical}
            change={data.change}
            icon={<Cpu size={16} className="mr-2 text-green-500 dark:text-green-400" />}
        />
    );
};

export const CpuChart = ({ data }) => {
    return (
        <div className="bg-white dark:bg-gray-800 rounded-lg p-4 shadow transition-colors">
            <h3 className="text-sm font-medium text-gray-600 dark:text-gray-300 mb-2">CPU Usage Trend</h3>
            <div style={{ height: '180px' }}>
                <ResponsiveContainer width="100%" height="100%">
                    <AreaChart data={data.data} margin={{ top: 5, right: 5, left: 0, bottom: 5 }}>
                        <CartesianGrid strokeDasharray="3 3" stroke="#D1D5DB dark:#374151" />
                        <XAxis dataKey="formattedTime" stroke="#6B7280" tick={{ fontSize: 12 }} />
                        <YAxis domain={[0, 100]} stroke="#6B7280" tick={{ fontSize: 12 }} />
                        <Tooltip content={<CustomTooltip />} />
                        <Area type="monotone" dataKey="value" stroke="#50FA7B" fill="#50FA7B" fillOpacity={0.2} name={`CPU Usage (${data.unit})`} />
                        <ReferenceLine y={data.warning} stroke="#F59E0B" strokeDasharray="3 3" />
                        <ReferenceLine y={data.critical} stroke="#EF4444" strokeDasharray="3 3" />
                    </AreaChart>
                </ResponsiveContainer>
            </div>
        </div>
    );
};

export const CpuCoresChart = ({ cores }) => {
    return (
        <div className="bg-white dark:bg-gray-800 rounded-lg p-4 shadow transition-colors">
            <h3 className="text-sm font-medium text-gray-600 dark:text-gray-300 mb-3">CPU Cores Usage</h3>
            <div style={{ height: '180px' }}>
                <ResponsiveContainer width="100%" height="100%">
                    <BarChart data={cores} margin={{ top: 5, right: 30, left: 20, bottom: 5 }}>
                        <CartesianGrid strokeDasharray="3 3" stroke="#D1D5DB dark:#374151" />
                        <XAxis dataKey="name" stroke="#6B7280" />
                        <YAxis domain={[0, 100]} stroke="#6B7280" />
                        <Tooltip />
                        <Bar dataKey="value" name="Usage (%)" fill="#50FA7B" />
                    </BarChart>
                </ResponsiveContainer>
            </div>
        </div>
    );
};

export const MemoryCard = ({ data }) => {
    return (
        <MetricCard
            title="Memory Usage"
            current={data.current}
            unit={data.unit}
            warning={data.warning}
            critical={data.critical}
            change={data.change}
            icon={<BarChart3 size={16} className="mr-2 text-pink-500 dark:text-pink-400" />}
        />
    );
};

export const MemoryChart = ({ data }) => {
    return (
        <div className="bg-white dark:bg-gray-800 rounded-lg p-4 shadow transition-colors">
            <h3 className="text-sm font-medium text-gray-600 dark:text-gray-300 mb-2">Memory Usage Trend</h3>
            <div style={{ height: '180px' }}>
                <ResponsiveContainer width="100%" height="100%">
                    <AreaChart data={data.data} margin={{ top: 5, right: 5, left: 0, bottom: 5 }}>
                        <CartesianGrid strokeDasharray="3 3" stroke="#D1D5DB dark:#374151" />
                        <XAxis dataKey="formattedTime" stroke="#6B7280" tick={{ fontSize: 12 }} />
                        <YAxis domain={[0, 100]} stroke="#6B7280" tick={{ fontSize: 12 }} />
                        <Tooltip content={<CustomTooltip />} />
                        <Area type="monotone" dataKey="value" stroke="#EC4899" fill="#EC4899" fillOpacity={0.2} name={`Memory Usage (${data.unit})`} />
                        <ReferenceLine y={data.warning} stroke="#F59E0B" strokeDasharray="3 3" />
                        <ReferenceLine y={data.critical} stroke="#EF4444" strokeDasharray="3 3" />
                    </AreaChart>
                </ResponsiveContainer>
            </div>
        </div>
    );
};

export const MemoryDetails = ({ data }) => {
    return (
        <div className="bg-white dark:bg-gray-800 rounded-lg p-4 shadow transition-colors">
            <h3 className="text-sm font-medium text-gray-600 dark:text-gray-300 mb-3">Memory Details</h3>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div className="p-3 bg-gray-100 dark:bg-gray-700 rounded-lg">
                    <div className="text-xs text-gray-500 dark:text-gray-400">Total Memory</div>
                    <div className="text-lg font-bold text-pink-500 dark:text-pink-400">{data.total} GB</div>
                </div>
                <div className="p-3 bg-gray-100 dark:bg-gray-700 rounded-lg">
                    <div className="text-xs text-gray-500 dark:text-gray-400">Used Memory</div>
                    <div className="text-lg font-bold text-pink-500 dark:text-pink-400">{data.used} GB</div>
                </div>
                <div className="p-3 bg-gray-100 dark:bg-gray-700 rounded-lg">
                    <div className="text-xs text-gray-500 dark:text-gray-400">Free Memory</div>
                    <div className="text-lg font-bold text-pink-500 dark:text-pink-400">{(data.total - data.used).toFixed(1)} GB</div>
                </div>
            </div>
        </div>
    );
};


export const FilesystemCard = ({ data }) => {
    const drives = data?.drives || [];
    const avgUsage = drives.length
        ? drives.reduce((sum, drive) => sum + drive.usedPercent, 0) / drives.length
        : 0;

    return (
        <MetricCard
            title="Disk Usage"
            current={avgUsage.toFixed(1)}
            unit="%"
            warning={data?.warning || 75}
            critical={data?.critical || 90}
            icon={<HardDrive size={16} className="mr-2 text-green-500 dark:text-green-400" />}
        >
            <div className="text-xs text-gray-500 dark:text-gray-400 mt-1">{drives.length} volumes monitored</div>
        </MetricCard>
    );
};

export const FilesystemChart = ({ data }) => {
    return (
        <div className="bg-white dark:bg-gray-800 rounded-lg p-4 shadow transition-colors">
            <h3 className="text-sm font-medium text-gray-600 dark:text-gray-300 mb-2">Disk Usage Trend</h3>
            <div style={{ height: '180px' }}>
                <ResponsiveContainer width="100%" height="100%">
                    <AreaChart data={data.data} margin={{ top: 5, right: 5, left: 0, bottom: 5 }}>
                        <CartesianGrid strokeDasharray="3 3" stroke="#D1D5DB dark:#374151" />
                        <XAxis dataKey="formattedTime" stroke="#6B7280" tick={{ fontSize: 12 }} />
                        <YAxis domain={[0, 100]} stroke="#6B7280" tick={{ fontSize: 12 }} />
                        <Tooltip content={<CustomTooltip />} />
                        <Area type="monotone" dataKey="value" stroke="#10B981" fill="#10B981" fillOpacity={0.2} name={`Disk Usage (%)`} />
                        <ReferenceLine y={data.warning} stroke="#F59E0B" strokeDasharray="3 3" />
                        <ReferenceLine y={data.critical} stroke="#EF4444" strokeDasharray="3 3" />
                    </AreaChart>
                </ResponsiveContainer>
            </div>
        </div>
    );
};

export const FilesystemDetails = ({ drives = [] }) => {
    if (!drives || drives.length === 0) {
        return (
            <div className="bg-white dark:bg-gray-800 rounded-lg p-4 shadow transition-colors">
                <h3 className="text-sm font-medium text-gray-600 dark:text-gray-300 mb-3">Disk Details</h3>
                <div className="text-center py-4 text-gray-500 dark:text-gray-400">
                    No disk data available
                </div>
            </div>
        );
    }

    return (
        <div className="bg-white dark:bg-gray-800 rounded-lg p-4 shadow transition-colors">
            <h3 className="text-sm font-medium text-gray-600 dark:text-gray-300 mb-3">Disk Details</h3>
            <div className="space-y-4">
                {drives.map((drive, index) => (
                    <div key={index} className="bg-gray-100 dark:bg-gray-700 rounded-lg p-3">
                        <div className="flex justify-between items-center mb-1">
                            <span className="font-medium text-gray-800 dark:text-gray-200">{drive.name}</span>
                            <span className="text-sm text-gray-600 dark:text-gray-400">
                                {drive.used} GB / {drive.size} GB
                            </span>
                        </div>
                        <ProgressBar
                            value={drive.usedPercent}
                            warning={drive.warning}
                            critical={drive.critical}
                        />
                        <div className="text-right text-xs text-gray-500 dark:text-gray-400 mt-1">
                            {drive.usedPercent}% used
                        </div>
                    </div>
                ))}
            </div>
        </div>
    );
};

export const ProcessCard = ({ data }) => {
    return (
        <MetricCard
            title="Running Processes"
            current={data.count}
            unit={data.unit}
            warning={200}
            critical={500}
            change={data.change}
            icon={<Activity size={16} className="mr-2 text-blue-500 dark:text-blue-400" />}
        />
    );
};

export const ProcessChart = ({ data }) => {
    return (
        <div className="bg-white dark:bg-gray-800 rounded-lg p-4 shadow transition-colors">
            <h3 className="text-sm font-medium text-gray-600 dark:text-gray-300 mb-2">Process Count Trend</h3>
            <div style={{ height: '180px' }}>
                <ResponsiveContainer width="100%" height="100%">
                    <AreaChart data={data.data} margin={{ top: 5, right: 5, left: 0, bottom: 5 }}>
                        <CartesianGrid strokeDasharray="3 3" stroke="#D1D5DB dark:#374151" />
                        <XAxis dataKey="formattedTime" stroke="#6B7280" tick={{ fontSize: 12 }} />
                        <YAxis stroke="#6B7280" tick={{ fontSize: 12 }} />
                        <Tooltip content={<CustomTooltip />} />
                        <Area type="monotone" dataKey="value" stroke="#3B82F6" fill="#3B82F6" fillOpacity={0.2} name="Process Count" />
                    </AreaChart>
                </ResponsiveContainer>
            </div>
        </div>
    );
};

export const ProcessDetails = ({ deviceId, targetId, idType = 'device' }) => {
    const [processes, setProcesses] = React.useState([]);
    const [pagination, setPagination] = React.useState(null);
    const [isLoading, setIsLoading] = React.useState(false);
    const [error, setError] = React.useState(null);
    const [limit] = React.useState(50); // Show 50 processes per page
    const [topProcessPids, setTopProcessPids] = React.useState(new Set());

    // Determine the actual ID to use
    const actualId = targetId || deviceId;
    const actualIdType = targetId ? idType : 'device';

    const fetchProcesses = React.useCallback(async (cursor = null, direction = 'next') => {
        if (!actualId) return;

        setIsLoading(true);
        setError(null);

        try {
            // Build SRQL query based on ID type  
            // Escape the device ID properly for SRQL
            const escapedId = actualId.replace(/'/g, "\\'");
            const whereCondition = actualIdType === 'device' 
                ? `device_id = '${escapedId}'`
                : `poller_id = '${escapedId}'`;
            
            const query = `SHOW process_metrics WHERE ${whereCondition} ORDER BY cpu_usage DESC, memory_usage DESC, pid ASC LATEST`;

            const body = { query, limit };
            if (cursor) {
                body.cursor = cursor;
                body.direction = direction;
            }

            const response = await fetch('/api/query', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify(body),
                cache: 'no-store',
                credentials: 'include',
            });

            if (!response.ok) {
                throw new Error(`Failed to fetch processes: ${response.statusText}`);
            }

            const data = await response.json();
            
            if (data.error) {
                throw new Error(data.error);
            }

            const processData = data.results || [];
            setProcesses(processData);
            setPagination(data.pagination || null);

            // Identify top 10 processes by CPU usage (primary) and memory usage (secondary) for highlighting
            const sortedByUsage = [...processData].sort((a, b) => {
                const cpuDiff = (b.cpu_usage || 0) - (a.cpu_usage || 0);
                if (cpuDiff !== 0) return cpuDiff;
                return (b.memory_usage || 0) - (a.memory_usage || 0);
            });
            const topPids = new Set(sortedByUsage.slice(0, 10).map(p => p.pid));
            setTopProcessPids(topPids);

        } catch (err) {
            console.error('Error fetching processes:', err);
            setError(err.message);
        } finally {
            setIsLoading(false);
        }
    }, [actualId, actualIdType, limit]);

    React.useEffect(() => {
        fetchProcesses();
    }, [fetchProcesses]);

    if (isLoading && processes.length === 0) {
        return (
            <div className="bg-white dark:bg-gray-800 rounded-lg p-4 shadow transition-colors">
                <h3 className="text-sm font-medium text-gray-600 dark:text-gray-300 mb-3">Process Details</h3>
                <div className="text-center py-4 text-gray-500 dark:text-gray-400">
                    Loading processes...
                </div>
            </div>
        );
    }

    if (error) {
        return (
            <div className="bg-white dark:bg-gray-800 rounded-lg p-4 shadow transition-colors">
                <h3 className="text-sm font-medium text-gray-600 dark:text-gray-300 mb-3">Process Details</h3>
                <div className="text-center py-4 text-red-500 dark:text-red-400">
                    Error: {error}
                </div>
            </div>
        );
    }

    if (!processes || processes.length === 0) {
        return (
            <div className="bg-white dark:bg-gray-800 rounded-lg p-4 shadow transition-colors">
                <h3 className="text-sm font-medium text-gray-600 dark:text-gray-300 mb-3">Process Details</h3>
                <div className="text-center py-4 text-gray-500 dark:text-gray-400">
                    No process data available
                </div>
            </div>
        );
    }

    return (
        <div className="bg-white dark:bg-gray-800 rounded-lg p-4 shadow transition-colors">
            <h3 className="text-sm font-medium text-gray-600 dark:text-gray-300 mb-3">
                All Processes (Top 10 highlighted)
            </h3>
            <div className="overflow-x-auto">
                <table className="w-full text-sm">
                    <thead>
                        <tr className="border-b border-gray-200 dark:border-gray-700">
                            <th className="text-left py-2 text-gray-600 dark:text-gray-300">PID</th>
                            <th className="text-left py-2 text-gray-600 dark:text-gray-300 min-w-48">Name</th>
                            <th className="text-right py-2 text-gray-600 dark:text-gray-300">CPU %</th>
                            <th className="text-right py-2 text-gray-600 dark:text-gray-300">Memory</th>
                            <th className="text-left py-2 text-gray-600 dark:text-gray-300">Status</th>
                        </tr>
                    </thead>
                    <tbody>
                        {processes.map((process, index) => {
                            const isTopProcess = topProcessPids.has(process.pid);
                            return (
                                <tr 
                                    key={`${process.pid}-${index}`} 
                                    className={`border-b border-gray-100 dark:border-gray-700 ${
                                        isTopProcess ? 'bg-blue-50 dark:bg-blue-900/20' : ''
                                    }`}
                                >
                                    <td className="py-2 text-gray-800 dark:text-gray-200">
                                        {isTopProcess && (
                                            <span className="inline-block w-2 h-2 bg-blue-500 rounded-full mr-2" title="Top 10 by CPU & Memory"></span>
                                        )}
                                        {process.pid}
                                    </td>
                                    <td className="py-2 text-gray-800 dark:text-gray-200 max-w-0">
                                        <div className="truncate pr-2" title={process.name}>
                                            {process.name}
                                        </div>
                                    </td>
                                    <td className="py-2 text-right">
                                        <span className={`${
                                            (process.cpu_usage || 0) > 50 ? 'text-red-600 dark:text-red-400' :
                                            (process.cpu_usage || 0) > 20 ? 'text-yellow-600 dark:text-yellow-400' :
                                            'text-gray-800 dark:text-gray-200'
                                        }`}>
                                            {(process.cpu_usage || 0).toFixed(1)}%
                                        </span>
                                    </td>
                                    <td className="py-2 text-right text-gray-800 dark:text-gray-200">
                                        {((process.memory_usage || 0) / 1024 / 1024 / 1024).toFixed(2)} GB
                                    </td>
                                    <td className="py-2">
                                        <span className={`px-2 py-1 rounded text-xs ${
                                            process.status === 'Running' ? 'bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200' :
                                            process.status === 'Sleeping' ? 'bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200' :
                                            'bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-200'
                                        }`}>
                                            {process.status || 'Unknown'}
                                        </span>
                                    </td>
                                </tr>
                            );
                        })}
                    </tbody>
                </table>
            </div>
            
            {/* Pagination Controls */}
            {pagination && (pagination.prev_cursor || pagination.next_cursor) && (
                <div className="flex justify-between items-center mt-4 pt-4 border-t border-gray-200 dark:border-gray-700">
                    <button
                        onClick={() => fetchProcesses(pagination.prev_cursor, 'prev')}
                        disabled={!pagination.prev_cursor || isLoading}
                        className="px-3 py-1 rounded bg-gray-200 dark:bg-gray-700 text-gray-700 dark:text-gray-200 disabled:opacity-50 disabled:cursor-not-allowed hover:bg-gray-300 dark:hover:bg-gray-600"
                    >
                        Previous
                    </button>
                    <span className="text-sm text-gray-600 dark:text-gray-400">
                        Showing {processes.length} processes
                    </span>
                    <button
                        onClick={() => fetchProcesses(pagination.next_cursor, 'next')}
                        disabled={!pagination.next_cursor || isLoading}
                        className="px-3 py-1 rounded bg-gray-200 dark:bg-gray-700 text-gray-700 dark:text-gray-200 disabled:opacity-50 disabled:cursor-not-allowed hover:bg-gray-300 dark:hover:bg-gray-600"
                    >
                        Next
                    </button>
                </div>
            )}
            
            {/* Legend for highlighting */}
            <div className="mt-3 text-xs text-gray-500 dark:text-gray-400 text-center">
                <span className="inline-block w-2 h-2 bg-blue-500 rounded-full mr-1"></span>
                Highlighted rows are top 10 processes by CPU & memory usage
            </div>
        </div>
    );
};