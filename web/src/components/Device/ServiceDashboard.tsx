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

import React, { useState, useEffect } from 'react';
import { ChevronLeft, Network, BarChart3 } from 'lucide-react';
import Link from 'next/link';
import { useAuth } from '@/components/AuthProvider';

interface DeviceServiceDashboardProps {
    deviceId: string;
    serviceName: string;
    initialData: any[];
    initialError: string | null;
    initialTimeRange: string;
}

const DeviceServiceDashboard: React.FC<DeviceServiceDashboardProps> = ({
    deviceId,
    serviceName,
    initialData,
    initialError,
    initialTimeRange
}) => {
    const { token } = useAuth();
    const [data, setData] = useState(initialData);
    const [error, setError] = useState(initialError);
    const [timeRange, setTimeRange] = useState(initialTimeRange);
    const [loading, setLoading] = useState(false);

    const getServiceIcon = () => {
        switch (serviceName.toLowerCase()) {
            case 'snmp':
                return <Network className="h-6 w-6" />;
            case 'sysmon':
                return <BarChart3 className="h-6 w-6" />;
            default:
                return <BarChart3 className="h-6 w-6" />;
        }
    };

    const getServiceTitle = () => {
        switch (serviceName.toLowerCase()) {
            case 'snmp':
                return 'Network Metrics (SNMP)';
            case 'sysmon':
                return 'System Metrics (Sysmon)';
            default:
                return `${serviceName} Metrics`;
        }
    };

    const fetchData = async (newTimeRange: string) => {
        setLoading(true);
        try {
            const hours = newTimeRange.replace('h', '');
            const endTime = new Date();
            const startTime = new Date(endTime.getTime() - parseInt(hours) * 60 * 60 * 1000);
            
            const response = await fetch(`/api/devices/${deviceId}/metrics?type=${serviceName.toLowerCase()}&start=${startTime.toISOString()}&end=${endTime.toISOString()}`, {
                headers: {
                    'Content-Type': 'application/json',
                    ...(token && { Authorization: `Bearer ${token}` })
                },
            });

            if (response.ok) {
                const newData = await response.json();
                setData(newData || []);
                setError(null);
            } else {
                const errorText = await response.text();
                setError(`Failed to fetch data: ${response.status} - ${errorText}`);
            }
        } catch (err) {
            setError(`Error fetching data: ${(err as Error).message}`);
        } finally {
            setLoading(false);
        }
    };

    const handleTimeRangeChange = (newTimeRange: string) => {
        setTimeRange(newTimeRange);
        fetchData(newTimeRange);
    };

    if (error) {
        return (
            <div className="min-h-screen bg-gray-900 text-white">
                <div className="container mx-auto px-4 py-8">
                    <div className="flex items-center mb-6">
                        <Link href="/devices" className="mr-4 p-2 rounded-lg hover:bg-gray-800">
                            <ChevronLeft className="h-5 w-5" />
                        </Link>
                        <div className="flex items-center space-x-3">
                            {getServiceIcon()}
                            <h1 className="text-2xl font-bold">{getServiceTitle()}</h1>
                        </div>
                    </div>
                    
                    <div className="bg-red-900/20 border border-red-500 rounded-lg p-6">
                        <h2 className="text-xl font-semibold text-red-400 mb-2">Error Loading Service Data</h2>
                        <p className="text-red-300">{error}</p>
                        <div className="mt-4 text-sm text-gray-400">
                            <p>Device ID: {deviceId}</p>
                            <p>Service: {serviceName}</p>
                        </div>
                    </div>
                </div>
            </div>
        );
    }

    return (
        <div className="min-h-screen bg-gray-900 text-white">
            <div className="container mx-auto px-4 py-8">
                <div className="flex items-center justify-between mb-6">
                    <div className="flex items-center">
                        <Link href="/devices" className="mr-4 p-2 rounded-lg hover:bg-gray-800">
                            <ChevronLeft className="h-5 w-5" />
                        </Link>
                        <div className="flex items-center space-x-3">
                            {getServiceIcon()}
                            <div>
                                <h1 className="text-2xl font-bold">{getServiceTitle()}</h1>
                                <p className="text-gray-400">Device: {deviceId}</p>
                            </div>
                        </div>
                    </div>
                    
                    <div className="flex items-center space-x-4">
                        <select
                            value={timeRange}
                            onChange={(e) => handleTimeRangeChange(e.target.value)}
                            className="bg-gray-800 border border-gray-600 rounded-lg px-3 py-2 text-white"
                            disabled={loading}
                        >
                            <option value="1h">Last 1 Hour</option>
                            <option value="6h">Last 6 Hours</option>
                            <option value="24h">Last 24 Hours</option>
                            <option value="7d">Last 7 Days</option>
                        </select>
                    </div>
                </div>

                <div className="grid gap-6">
                    {loading ? (
                        <div className="bg-gray-800 rounded-lg p-6 text-center">
                            <div className="animate-spin inline-block w-6 h-6 border-2 border-white border-t-transparent rounded-full"></div>
                            <p className="mt-2 text-gray-400">Loading {serviceName} data...</p>
                        </div>
                    ) : data && data.length > 0 ? (
                        <div className="bg-gray-800 rounded-lg p-6">
                            <h2 className="text-xl font-semibold mb-4">Metrics Data</h2>
                            <div className="text-sm text-gray-400 mb-4">
                                Found {data.length} metric records
                            </div>
                            <div className="max-h-96 overflow-y-auto">
                                <pre className="text-sm text-gray-300 whitespace-pre-wrap">
                                    {JSON.stringify(data, null, 2)}
                                </pre>
                            </div>
                        </div>
                    ) : (
                        <div className="bg-gray-800 rounded-lg p-6 text-center">
                            <div className="text-gray-400">
                                <div className="mb-2">{getServiceIcon()}</div>
                                <h3 className="text-lg font-medium text-white mb-2">No {serviceName} Data Available</h3>
                                <p>No metrics found for this device in the selected time range.</p>
                                <p className="text-sm mt-2">Device ID: {deviceId}</p>
                            </div>
                        </div>
                    )}
                </div>
            </div>
        </div>
    );
};

export default DeviceServiceDashboard;