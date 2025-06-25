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
import { Cpu, HardDrive, BarChart3 } from 'lucide-react';
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