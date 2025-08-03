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
import { PieChart, Pie, Cell, ResponsiveContainer, Tooltip } from 'recharts';
import { ServerOff, AlertTriangle } from 'lucide-react';
import { useAuth } from '../AuthProvider';
import { useRouter } from 'next/navigation';



interface DeviceAvailabilityData {
    name: string;
    value: number;
    color: string;
}

const DeviceAvailabilityWidget = () => {
    const { token } = useAuth();
    const router = useRouter();
    const [data, setData] = useState<DeviceAvailabilityData[]>([]);

    const [isLoading, setIsLoading] = useState(true);

    const [error, setError] = useState<string | null>(null);

    const cacheRef = React.useRef<Map<string, { data: unknown; timestamp: number }>>(new Map());
    
    const postQuery = useCallback(async (query: string) => {
        const cacheKey = query;
        const now = Date.now();
        
        const cached = cacheRef.current.get(cacheKey);
        if (cached && (now - cached.timestamp) < 30000) {
            return cached.data;
        }
        
        const response = await fetch('/api/query', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                ...(token && { Authorization: `Bearer ${token}` }),
            },
            body: JSON.stringify({ query, limit: 1000 }),
        });
        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.error || 'Failed to execute query');
        }
        const responseData = await response.json();
        
        cacheRef.current.set(cacheKey, { data: responseData, timestamp: now });
        return responseData;
    }, [token]);

    const fetchData = useCallback(async () => {
        setIsLoading(true);
        setError(null);

        try {
            const [totalDevicesRes, offlineDevicesRes] = await Promise.all([
                postQuery('COUNT DEVICES'),
                postQuery('COUNT DEVICES WHERE is_available = false'),
            ]);

            const totalDevices = totalDevicesRes.results[0]?.['count()'] || 0;
            const offlineCount = offlineDevicesRes.results[0]?.['count()'] || 0;
            const onlineCount = totalDevices - offlineCount;

            setData([
                { name: 'Online', value: onlineCount, color: '#10b981' },
                { name: 'Offline', value: offlineCount, color: '#ef4444' }
            ]);



        } catch (e) {
            setError(e instanceof Error ? e.message : "Failed to fetch device availability data");
        } finally {
            setIsLoading(false);
        }
    }, [postQuery]);

    useEffect(() => {
        fetchData();
        const interval = setInterval(fetchData, 60000);
        return () => clearInterval(interval);
    }, [fetchData]);

    const totalDevices = data.reduce((sum, item) => sum + item.value, 0);
    const offlineCount = data.find(item => item.name === 'Offline')?.value || 0;
    const availabilityPercentage = totalDevices > 0 ? ((totalDevices - offlineCount) / totalDevices * 100) : 100;

    const handlePieClick = useCallback((data: DeviceAvailabilityData) => {
        const isOffline = data.name === 'Offline';
        const query = isOffline 
            ? 'show devices where is_available = false'
            : 'show devices where is_available = true';
        
        const encodedQuery = encodeURIComponent(query);
        router.push(`/query?q=${encodedQuery}`);
    }, [router]);

    const CustomTooltip = ({ active, payload }: { 
        active?: boolean; 
        payload?: Array<{ payload: DeviceAvailabilityData }> 
    }) => {
        if (active && payload && payload.length) {
            const data = payload[0].payload;
            const percentage = totalDevices > 0 ? ((data.value / totalDevices) * 100).toFixed(1) : '0';
            return (
                <div className="bg-gray-900 border border-gray-700 p-2 rounded-md shadow-lg">
                    <p className="text-white text-sm">
                        {data.name}: {data.value} ({percentage}%)
                    </p>
                    <p className="text-gray-300 text-xs mt-1">
                        Click to view details
                    </p>
                </div>
            );
        }
        return null;
    };

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
                            const query = 'show devices where is_available = false';
                            const encodedQuery = encodeURIComponent(query);
                            router.push(`/query?q=${encodedQuery}`);
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
                                    <Tooltip content={<CustomTooltip />} />
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