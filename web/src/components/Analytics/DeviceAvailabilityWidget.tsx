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

import React, { useMemo, useCallback } from 'react';
import { PieChart, Pie, Cell, ResponsiveContainer, Tooltip } from 'recharts';
import { ServerOff, AlertTriangle } from 'lucide-react';
import { useRouter } from 'next/navigation';
import { useAnalytics } from '@/contexts/AnalyticsContext';
import { useSrqlQuery } from '@/contexts/SrqlQueryContext';

interface DeviceAvailabilityData {
    name: string;
    value: number;
    color: string;
}

interface DeviceAvailabilityTooltipProps {
    active?: boolean;
    payload?: Array<{ payload: DeviceAvailabilityData }>;
    totalDevices: number;
}

const DeviceAvailabilityTooltip: React.FC<DeviceAvailabilityTooltipProps> = ({ active, payload, totalDevices }) => {
    if (active && payload && payload.length) {
        const datum = payload[0].payload;
        const percentage = totalDevices > 0 ? ((datum.value / totalDevices) * 100).toFixed(1) : '0';
        return (
            <div className="bg-gray-900 border border-gray-700 p-2 rounded-md shadow-lg">
                <p className="text-white text-sm">
                    {datum.name}: {datum.value} ({percentage}%)
                </p>
                <p className="text-gray-300 text-xs mt-1">
                    Click to view details
                </p>
            </div>
        );
    }
    return null;
};

const DeviceAvailabilityWidget = () => {
    const router = useRouter();
    const { setQuery: setSrqlQuery } = useSrqlQuery();
    const { data: analyticsData, loading: isLoading, error } = useAnalytics();

    const data = useMemo((): DeviceAvailabilityData[] => {
        if (!analyticsData) return [];
        
        return [
            { name: 'Online', value: analyticsData.onlineDevices, color: '#10b981' },
            { name: 'Offline', value: analyticsData.offlineDevices, color: '#ef4444' }
        ];
    }, [analyticsData]);

    const totalDevices = data.reduce((sum, item) => sum + item.value, 0);
    const offlineCount = data.find(item => item.name === 'Offline')?.value || 0;
    const availabilityPercentage = totalDevices > 0 ? ((totalDevices - offlineCount) / totalDevices * 100) : 100;

    const navigateToDevices = useCallback((query: string) => {
        setSrqlQuery(query, { origin: 'view', viewPath: '/devices', viewId: 'devices:inventory' });
        router.push('/devices');
    }, [router, setSrqlQuery]);

    const handlePieClick = useCallback((data: DeviceAvailabilityData) => {
        const isOffline = data.name === 'Offline';
        const query = isOffline
            ? 'in:devices is_available:false time:last_7d sort:last_seen:desc limit:100'
            : 'in:devices is_available:true time:last_7d sort:last_seen:desc limit:100';

        navigateToDevices(query);
    }, [navigateToDevices]);

    if (error) {
        return (
            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 h-[320px] flex items-center justify-center">
                <div className="text-center text-red-600 dark:text-red-400">
                    <AlertTriangle className="h-8 w-8 mx-auto mb-2" />
                    <p className="text-sm">{error}</p>
                </div>
            </div>
        );
    }

    return (
        <>
            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 flex flex-col h-[320px]">
                <div className="flex justify-between items-start mb-4">
                    <h3 
                        className="font-semibold text-gray-900 dark:text-white cursor-pointer hover:text-blue-600 dark:hover:text-blue-400 transition-colors"
                        onClick={() => handlePieClick(data.find(d => d.name === 'Online') || data[0])}
                        title="Click to view all devices"
                    >
                        Device Availability
                    </h3>
                    <button
                        onClick={() => {
                            navigateToDevices('in:devices is_available:false time:last_7d sort:last_seen:desc limit:100');
                        }}
                        className="text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
                        title="View offline devices"
                    >
                        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                            <path d="m7 11 2-2-2-2"/>
                            <path d="M11 13h4"/>
                            <rect width="18" height="18" x="3" y="3" rx="2" ry="2"/>
                        </svg>
                    </button>
                </div>

            {isLoading ? (
                <div className="flex-1 flex items-center justify-center">
                    <div className="animate-pulse">
                        <div className="h-32 w-32 bg-gray-200 dark:bg-gray-700 rounded-full mx-auto mb-4"></div>
                        <div className="h-4 w-24 bg-gray-200 dark:bg-gray-700 rounded mx-auto"></div>
                    </div>
                </div>
            ) : (
                <>
                    <div className="flex-1 flex items-center">
                        <div className="w-1/2 h-full">
                            <ResponsiveContainer width="100%" height="100%">
                                <PieChart>
                                    <Pie
                                        data={data}
                                        cx="50%"
                                        cy="50%"
                                        innerRadius={40}
                                        outerRadius={80}
                                        dataKey="value"
                                        startAngle={90}
                                        endAngle={450}
                                        onClick={(data) => handlePieClick(data)}
                                        style={{ cursor: 'pointer' }}
                                    >
                                        {data.map((entry) => (
                                            <Cell 
                                                key={`cell-${entry.name}`} 
                                                fill={entry.color}
                                                style={{ cursor: 'pointer' }}
                                            />
                                        ))}
                                    </Pie>
                                    <Tooltip content={<DeviceAvailabilityTooltip totalDevices={totalDevices} />} />
                                </PieChart>
                            </ResponsiveContainer>
                        </div>
                        
                        <div className="w-1/2 pl-4">
                            <div className="text-center mb-4">
                                <div className="text-3xl font-bold text-gray-900 dark:text-white">
                                    {availabilityPercentage.toFixed(1)}%
                                </div>
                                <div className="text-sm text-gray-600 dark:text-gray-400">
                                    Availability
                                </div>
                            </div>
                            
                            <div className="space-y-2">
                                {data.map((item) => (
                                    <div key={item.name} className="flex items-center justify-between text-sm">
                                        <div className="flex items-center gap-2">
                                            <div 
                                                className="w-3 h-3 rounded-full" 
                                                style={{ backgroundColor: item.color }}
                                            />
                                            <span className="text-gray-700 dark:text-gray-300">{item.name}</span>
                                        </div>
                                        <span className="font-medium text-gray-900 dark:text-white">
                                            {item.value}
                                        </span>
                                    </div>
                                ))}
                            </div>

                            {offlineCount > 0 && (
                                <div className="mt-3 p-2 bg-red-50 dark:bg-red-900/20 rounded-md">
                                    <div className="flex items-center gap-2 text-red-600 dark:text-red-400 text-sm">
                                        <ServerOff className="h-4 w-4" />
                                        <span>{offlineCount} device{offlineCount !== 1 ? 's' : ''} offline</span>
                                    </div>
                                </div>
                            )}
                        </div>
                    </div>


                </>
            )}
            </div>
        </>
    );
};

export default DeviceAvailabilityWidget;
