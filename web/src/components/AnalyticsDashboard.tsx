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

import React, { useState, useEffect, useCallback } from 'react';
import { BarChart, Bar, XAxis, YAxis, ResponsiveContainer, Cell } from 'recharts';
import { Monitor, AlertTriangle, ShieldOff, Bell, Plus, MoreHorizontal } from 'lucide-react';
import { useAuth } from './AuthProvider';

const REFRESH_INTERVAL = 30000; // 30 seconds

const StatCard = ({ icon, title, value, subValue, alert = false }) => (
    <div className={`bg-[#25252e] border border-gray-700 p-4 rounded-lg flex items-center gap-4`}>
        <div className={`p-2 rounded-md ${alert ? 'bg-red-500/20 text-red-400' : 'bg-gray-600/30 text-gray-300'}`}>
            {React.cloneElement(icon, { className: 'h-6 w-6' })}
        </div>
        <div className="flex items-baseline gap-x-3">
            <p className="text-2xl font-bold text-white">{value}</p>
            <p className="text-sm text-gray-400">{title}</p>
            {subValue && <p className="text-sm text-gray-500">| {subValue}</p>}
        </div>
    </div>
);

const ChartWidget = ({ title, children, pagination, moreOptions = true }) => (
    <div className="bg-[#25252e] border border-gray-700 rounded-lg p-4 flex flex-col h-[300px]">
        <div className="flex justify-between items-center mb-4">
            <h3 className="font-semibold text-white">{title}</h3>
            <div className="flex items-center gap-x-2">
                {pagination && <div className="text-xs text-gray-400">{pagination}</div>}
                {moreOptions && <button className="text-gray-400 hover:text-white"><MoreHorizontal size={20} /></button>}
            </div>
        </div>
        <div className="flex-1">{children}</div>
    </div>
);

const NoData = () => (
    <div className="flex flex-col items-center justify-center h-full text-center text-gray-500">
        <div className="w-16 h-12 relative mb-2">
            <div className="absolute top-0 left-0 w-8 h-12 bg-gray-600 transform -skew-x-12"></div>
            <div className="absolute top-0 left-8 w-8 h-12 bg-violet-600 transform -skew-x-12"></div>
        </div>
        <p>No data to show</p>
    </div>
);


const mockBarData = [
    { name: 'Computers', value: 89800, color: '#3b82f6' },
    { name: 'Handhelds', value: 16700, color: '#8b5cf6' },
    { name: 'Communications', value: 16000, color: '#60a5fa' },
    { name: 'Network Equip...', value: 7525, color: '#60a5fa' },
    { name: 'Imaging', value: 3536, color: '#a78bfa' },
    { name: 'Multimedia', value: 961, color: '#a78bfa' },
    { name: 'Automations', value: 560, color: '#a78bfa' },
];

const SimpleBarChart = ({ data, yMax }) => (
    <ResponsiveContainer width="100%" height="100%">
        <BarChart data={data} margin={{ top: 5, right: 20, left: -10, bottom: 5 }}>
            <XAxis dataKey="name" tick={{ fill: '#9ca3af', fontSize: 12 }} axisLine={false} tickLine={false} />
            <YAxis
                tickFormatter={(value) => `${value / 1000}k`}
                tick={{ fill: '#9ca3af', fontSize: 12 }}
                domain={[0, yMax]}
                axisLine={false}
                tickLine={false}
            />
            <Bar dataKey="value" radius={[4, 4, 0, 0]}>
                {data.map((entry, index) => (
                    <Cell key={`cell-${index}`} fill={entry.color} />
                ))}
            </Bar>
        </BarChart>
    </ResponsiveContainer>
);


const AnalyticsDashboard = () => {
    const { token } = useAuth();
    const [deviceCount, setDeviceCount] = useState<number | null>(null);
    const [newDeviceCount, setNewDeviceCount] = useState<number | null>(null);
    const [isLoading, setIsLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);

    const fetchDeviceCount = useCallback(async () => {
        // Don't set isLoading to true on subsequent refreshes to avoid UI flicker
        if (deviceCount === null) {
            setIsLoading(true);
        }
        setError(null);

        try {
            const response = await fetch('/api/query', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    ...(token && { Authorization: `Bearer ${token}` }),
                },
                body: JSON.stringify({ query: 'count devices' }),
                cache: 'no-store',
            });

            if (!response.ok) {
                const errorText = await response.text();
                throw new Error(`API Error: ${response.status} ${errorText}`);
            }

            const data = await response.json();

            if (
                data &&
                Array.isArray(data.results) &&
                data.results.length > 0 &&
                typeof data.results[0]["count()"] === 'number'
            ) {
                setDeviceCount(data.results[0]["count()"]);
            } else {
                throw new Error('Unexpected data format for device count.');
            }
        } catch (err) {
            console.error("Failed to fetch device count:", err);
            setError(err instanceof Error ? err.message : 'Unknown error');
            setDeviceCount(null); // Clear previous count on error
        } finally {
            setIsLoading(false);
        }
    }, [token, deviceCount]);

    const fetchNewDeviceCount = useCallback(async () => {
        try {
            const response = await fetch('/api/query', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    ...(token && { Authorization: `Bearer ${token}` }),
                },
                body: JSON.stringify({ query: "count devices where first_seen > now() - 7d" }),
                cache: 'no-store',
            });

            if (!response.ok) {
                const errorText = await response.text();
                throw new Error(`API Error: ${response.status} ${errorText}`);
            }

            const data = await response.json();

            if (
                data &&
                Array.isArray(data.results) &&
                data.results.length > 0 &&
                typeof data.results[0]["count()"] === 'number'
            ) {
                setNewDeviceCount(data.results[0]["count()"]);
            } else {
                throw new Error('Unexpected data format for new device count.');
            }
        } catch (err) {
            console.error("Failed to fetch new device count:", err);
            setNewDeviceCount(null);
        }
    }, [token]);

    useEffect(() => {
        fetchDeviceCount();
        fetchNewDeviceCount();
        const interval = setInterval(() => {
            fetchDeviceCount();
            fetchNewDeviceCount();
        }, REFRESH_INTERVAL);
        return () => clearInterval(interval);
    }, [fetchDeviceCount, fetchNewDeviceCount]);

    return (
        <div className="space-y-6">
            {/* Stat Cards */}
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
                <StatCard
                    icon={<Monitor />}
                    title="Devices"
                    value={
                        isLoading && deviceCount === null ? '...' :
                            error ? 'Error' :
                                deviceCount !== null ? deviceCount.toLocaleString() : 'N/A'
                    }
                    subValue={
                        newDeviceCount !== null
                            ? `${newDeviceCount.toLocaleString()} new`
                            : 'N/A'
                    }
                />
                <StatCard icon={<AlertTriangle />} title="Critical risk devices" value="13.7k" alert />
                <StatCard icon={<ShieldOff />} title="Threat activities" value="0" />
                <StatCard icon={<Bell />} title="Unhandled alerts" value="0" />
            </div>

            {/* Vulnerabilities Section */}
            <div>
                <div className="flex justify-between items-center mb-4">
                    <h2 className="text-xl font-bold text-white">Vulnerabilities</h2>
                    <div className="flex items-center gap-2">
                        <button className="p-2 bg-violet-600 rounded-md hover:bg-violet-700">
                            <Plus className="h-5 w-5 text-white" />
                        </button>
                        <button className="p-2 text-gray-400 hover:text-white hover:bg-gray-700/50 rounded-md">
                            <MoreHorizontal className="h-5 w-5" />
                        </button>
                    </div>
                </div>
                <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
                    <ChartWidget title="Devices Scanned by Vulnerability Scanner">
                        <NoData />
                    </ChartWidget>
                    <ChartWidget title="Devices Not Scanned by Vulnerability Scanner" pagination="< 1 - 7 of 12 >">
                        <SimpleBarChart data={mockBarData} yMax={100000} />
                    </ChartWidget>
                    <ChartWidget title="High Risk Devices Not Scanned in Last 30 Days">
                        <SimpleBarChart data={[
                            { name: 'Category A', value: 673, color: '#3b82f6'},
                            { name: 'Category B', value: 525, color: '#8b5cf6'}
                        ]} yMax={750} />
                    </ChartWidget>
                    <ChartWidget title="Devices with Confirmed High or Critical Vulnerabilities and No Scan in Last 30 Days">
                        <SimpleBarChart data={[
                            { name: 'Device Type X', value: 3424, color: '#3b82f6'}
                        ]} yMax={4000} />
                    </ChartWidget>
                </div>
            </div>
        </div>
    );
};

export default AnalyticsDashboard;