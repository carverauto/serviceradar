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
import { AreaChart, Area, ResponsiveContainer } from 'recharts';
import { 
    Activity, 
    TrendingUp, 
    TrendingDown, 
    Minus, 
    AlertTriangle
} from 'lucide-react';
import { useAuth } from '../AuthProvider';
import { useRouter } from 'next/navigation';
import { RperfMetric } from '@/types/rperf';

interface BandwidthTarget {
    target: string;
    currentBandwidth: number;
    avgBandwidth: number;
    trend: 'up' | 'down' | 'stable';
    trendPercentage: number;
    sources: string[];
    sparklineData: { timestamp: number; value: number }[];
    status: 'excellent' | 'good' | 'warning' | 'critical';
}

const RperfBandwidthWidget = () => {
    const { token } = useAuth();
    const router = useRouter();
    const [targets, setTargets] = useState<BandwidthTarget[]>([]);
    const [isLoading, setIsLoading] = useState(true);

    const [error, setError] = useState<string | null>(null);
    const [viewMode, setViewMode] = useState<'table' | 'heatmap'>('table');

    const fetchData = useCallback(async () => {
        setIsLoading(true);
        setError(null);

        try {
            // Get pollers that have rperf services
            const pollersResponse = await fetch('/api/pollers', {
                headers: {
                    'Content-Type': 'application/json',
                    ...(token && { Authorization: `Bearer ${token}` }),
                },
            });

            if (!pollersResponse.ok) {
                throw new Error('Failed to fetch pollers');
            }

            const pollersData = await pollersResponse.json();
            const rperfPollers = pollersData.filter((poller: {
                poller_id: string;
                services?: { type: string; name: string }[];
            }) => 
                poller.services?.some((s) => s.type === 'grpc' && s.name === 'rperf-checker')
            );

            if (rperfPollers.length === 0) {
                setTargets([]);
                return;
            }

            // Get data for the last 2 hours to calculate trends
            const endTime = new Date();
            const startTime = new Date(endTime.getTime() - 2 * 60 * 60 * 1000);
            
            const rperfPromises = rperfPollers.map((poller: { poller_id: string }) => {
                const url = `/api/pollers/${poller.poller_id}/rperf?start=${startTime.toISOString()}&end=${endTime.toISOString()}`;
                
                return fetch(url, {
                    headers: {
                        'Content-Type': 'application/json',
                        ...(token && { Authorization: `Bearer ${token}` }),
                    },
                })
                .then(res => {
                    if (!res.ok) {
                        console.error(`RPerf API error for poller ${poller.poller_id}: ${res.status}`);
                        return [];
                    }
                    return res.json() as Promise<RperfMetric[]>;
                })
                .catch((err) => {
                    console.error(`Error fetching rperf for poller ${poller.poller_id}:`, err);
                    return [];
                });
            });
            
            const rperfDataArrays = await Promise.all(rperfPromises);
            const allRperfData = rperfDataArrays.flat();

            if (allRperfData.length === 0) {
                setTargets([]);
                return;
            }

            // Process data by target
            const targetMap = new Map<string, {
                metrics: RperfMetric[];
                sources: Set<string>;
            }>();

            allRperfData
                .filter(metric => metric.success)
                .forEach(metric => {
                    const target = metric.target;
                    if (!targetMap.has(target)) {
                        targetMap.set(target, {
                            metrics: [],
                            sources: new Set()
                        });
                    }
                    
                    const targetData = targetMap.get(target)!;
                    targetData.metrics.push(metric);
                    if (metric.agent_id) {
                        targetData.sources.add(metric.agent_id);
                    }
                });

            // Calculate statistics for each target
            const processedTargets: BandwidthTarget[] = Array.from(targetMap.entries())
                .map(([target, data]) => {
                    const metrics = data.metrics.sort((a, b) => new Date(a.timestamp).getTime() - new Date(b.timestamp).getTime());
                    
                    // Current bandwidth (average of last 10 minutes)
                    const recentMetrics = metrics.slice(-10);
                    const currentBandwidth = recentMetrics.reduce((sum, m) => sum + (m.bits_per_second / 1000000), 0) / recentMetrics.length;
                    
                    // Overall average
                    const avgBandwidth = metrics.reduce((sum, m) => sum + (m.bits_per_second / 1000000), 0) / metrics.length;
                    
                    // Trend calculation (compare last 30 minutes vs previous 30 minutes)
                    const halfPoint = Math.floor(metrics.length / 2);
                    const firstHalf = metrics.slice(0, halfPoint);
                    const secondHalf = metrics.slice(halfPoint);
                    
                    let trend: 'up' | 'down' | 'stable' = 'stable';
                    let trendPercentage = 0;
                    
                    if (firstHalf.length > 0 && secondHalf.length > 0) {
                        const firstAvg = firstHalf.reduce((sum, m) => sum + (m.bits_per_second / 1000000), 0) / firstHalf.length;
                        const secondAvg = secondHalf.reduce((sum, m) => sum + (m.bits_per_second / 1000000), 0) / secondHalf.length;
                        
                        if (firstAvg > 0) {
                            trendPercentage = ((secondAvg - firstAvg) / firstAvg) * 100;
                            if (Math.abs(trendPercentage) > 5) {
                                trend = trendPercentage > 0 ? 'up' : 'down';
                            }
                        }
                    }
                    
                    // Sparkline data (last 20 points)
                    const sparklineData = metrics.slice(-20).map(m => ({
                        timestamp: new Date(m.timestamp).getTime(),
                        value: m.bits_per_second / 1000000
                    }));
                    
                    // Status based on bandwidth performance
                    let status: 'excellent' | 'good' | 'warning' | 'critical' = 'good';
                    if (currentBandwidth >= 8) status = 'excellent';
                    else if (currentBandwidth >= 6) status = 'good';
                    else if (currentBandwidth >= 3) status = 'warning';
                    else status = 'critical';
                    
                    return {
                        target,
                        currentBandwidth: Math.round(currentBandwidth * 100) / 100,
                        avgBandwidth: Math.round(avgBandwidth * 100) / 100,
                        trend,
                        trendPercentage: Math.abs(trendPercentage),
                        sources: Array.from(data.sources),
                        sparklineData,
                        status
                    };
                })
                .sort((a, b) => b.currentBandwidth - a.currentBandwidth);

            setTargets(processedTargets);

        } catch (e) {
            setError(e instanceof Error ? e.message : "Failed to fetch RPerf bandwidth data");
        } finally {
            setIsLoading(false);
        }
    }, [token]);

    useEffect(() => {
        fetchData();
        const interval = setInterval(fetchData, 60000);
        return () => clearInterval(interval);
    }, [fetchData]);

    const handleRperfTargetClick = useCallback((target: BandwidthTarget) => {
        // Find a poller that measures this target
        if (target.sources.length > 0) {
            const pollerId = target.sources[0]; // Use first source
            // Navigate to RPerf dashboard for this poller
            router.push(`/network/rperf/${pollerId}/rperf-checker`);
        } else {
            // Fallback to general network page
            router.push('/network');
        }
    }, [router]);

    const handleRperfHeaderClick = useCallback(() => {
        // If we have targets, go to the first available RPerf dashboard
        if (targets.length > 0 && targets[0].sources.length > 0) {
            const pollerId = targets[0].sources[0];
            router.push(`/network/rperf/${pollerId}/rperf-checker`);
        } else {
            // Fallback to general network page
            router.push('/network');
        }
    }, [router, targets]);

    const getStatusColor = (status: string) => {
        switch (status) {
            case 'excellent': return 'text-green-600 dark:text-green-400';
            case 'good': return 'text-blue-600 dark:text-blue-400';
            case 'warning': return 'text-yellow-600 dark:text-yellow-400';
            case 'critical': return 'text-red-600 dark:text-red-400';
            default: return 'text-gray-600 dark:text-gray-400';
        }
    };

    const getStatusBgColor = (status: string) => {
        switch (status) {
            case 'excellent': return 'bg-green-100 dark:bg-green-900/20';
            case 'good': return 'bg-blue-100 dark:bg-blue-900/20';
            case 'warning': return 'bg-yellow-100 dark:bg-yellow-900/20';
            case 'critical': return 'bg-red-100 dark:bg-red-900/20';
            default: return 'bg-gray-100 dark:bg-gray-900/20';
        }
    };

    const TrendIcon = ({ trend }: { trend: 'up' | 'down' | 'stable' }) => {
        if (trend === 'up') return <TrendingUp className="h-3 w-3 text-green-600 dark:text-green-400" />;
        if (trend === 'down') return <TrendingDown className="h-3 w-3 text-red-600 dark:text-red-400" />;
        return <Minus className="h-3 w-3 text-gray-600 dark:text-gray-400" />;
    };

    const Sparkline = ({ data }: { data: { timestamp: number; value: number }[] }) => {
        
        return (
            <ResponsiveContainer width={60} height={20}>
                <AreaChart data={data} margin={{ top: 0, right: 0, left: 0, bottom: 0 }}>
                    <Area 
                        type="monotone" 
                        dataKey="value" 
                        stroke="#3b82f6" 
                        strokeWidth={1}
                        fill="#3b82f6"
                        fillOpacity={0.2}
                        isAnimationActive={false}
                    />
                </AreaChart>
            </ResponsiveContainer>
        );
    };

    const HeatmapView = () => (
        <div className="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-6 gap-2">
            {targets.map((target) => (
                <div
                    key={target.target}
                    className={`p-2 rounded text-center text-xs cursor-pointer hover:opacity-80 transition-opacity ${getStatusBgColor(target.status)}`}
                    onClick={() => handleRperfTargetClick(target)}
                    title={`${target.target}: ${target.currentBandwidth} Mbps - Click to view RPerf dashboard`}
                >
                    <div className="font-medium text-gray-900 dark:text-white truncate text-xs">
                        {target.target.split('.')[0]}
                    </div>
                    <div className={`font-bold text-sm ${getStatusColor(target.status)}`}>
                        {target.currentBandwidth}
                    </div>
                    <div className="text-xs text-gray-500 dark:text-gray-400">
                        Mbps
                    </div>
                </div>
            ))}
        </div>
    );

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
        <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-4 flex flex-col h-[320px]">
            <div className="flex justify-between items-start mb-4">
                <h3 
                    className="font-semibold text-gray-900 dark:text-white cursor-pointer hover:text-blue-600 dark:hover:text-blue-400 transition-colors"
                    onClick={handleRperfHeaderClick}
                    title="Click to view RPerf dashboard"
                >
                    RPerf Bandwidth (Mbps)
                </h3>
                <div className="flex items-center gap-2">
                    <div className="flex gap-1 bg-gray-100 dark:bg-gray-700 p-1 rounded text-xs">
                        <button
                            onClick={() => setViewMode('table')}
                            className={`px-2 py-1 rounded ${
                                viewMode === 'table'
                                    ? 'bg-blue-500 text-white'
                                    : 'text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600'
                            }`}
                        >
                            Table
                        </button>
                        <button
                            onClick={() => setViewMode('heatmap')}
                            className={`px-2 py-1 rounded ${
                                viewMode === 'heatmap'
                                    ? 'bg-blue-500 text-white'
                                    : 'text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600'
                            }`}
                        >
                            Grid
                        </button>
                    </div>
                    <button
                        onClick={handleRperfHeaderClick}
                        className="text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
                        title="View RPerf dashboard"
                    >
                        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                            <path d="m7 11 2-2-2-2"/>
                            <path d="M11 13h4"/>
                            <rect width="18" height="18" x="3" y="3" rx="2" ry="2"/>
                        </svg>
                    </button>
                </div>
            </div>

            {isLoading ? (
                <div className="flex-1 flex items-center justify-center">
                    <div className="animate-pulse space-y-2 w-full">
                        {[...Array(5)].map((_, i) => (
                            <div key={i} className="h-8 bg-gray-200 dark:bg-gray-700 rounded"></div>
                        ))}
                    </div>
                </div>
            ) : targets.length === 0 ? (
                <div className="flex-1 flex items-center justify-center">
                    <div className="text-center text-gray-600 dark:text-gray-500">
                        <Activity className="h-12 w-12 mx-auto mb-2 opacity-50" />
                        <p>No RPerf data available</p>
                    </div>
                </div>
            ) : (
                <div className="flex-1 overflow-hidden">
                    {viewMode === 'heatmap' ? (
                        <HeatmapView />
                    ) : (
                        <div className="h-full overflow-y-auto">
                            <div className="space-y-1">
                                {targets.slice(0, 6).map((target, index) => (
                                    <div 
                                        key={target.target}
                                        className="flex items-center justify-between p-2 hover:bg-gray-50 dark:hover:bg-gray-700/50 rounded text-sm cursor-pointer transition-colors"
                                        onClick={() => handleRperfTargetClick(target)}
                                        title={`Click to view RPerf dashboard for ${target.target}`}
                                    >
                                        <div className="flex items-center gap-3 flex-1 min-w-0">
                                            <div className="flex items-center gap-1">
                                                <span className="text-xs font-medium text-gray-500 dark:text-gray-400 w-4">
                                                    #{index + 1}
                                                </span>
                                                <TrendIcon trend={target.trend} />
                                            </div>
                                            <div className="flex-1 min-w-0">
                                                <div className="font-medium text-gray-900 dark:text-white truncate">
                                                    {target.target}
                                                </div>
                                                {target.sources.length > 1 && (
                                                    <div className="text-xs text-gray-500 dark:text-gray-400">
                                                        {target.sources.length} sources
                                                    </div>
                                                )}
                                            </div>
                                        </div>
                                        
                                        <div className="flex items-center gap-3">
                                            <Sparkline data={target.sparklineData} />
                                            <div className="text-right">
                                                <div className={`font-bold ${getStatusColor(target.status)}`}>
                                                    {target.currentBandwidth}
                                                </div>
                                                <div className="text-xs text-gray-500 dark:text-gray-400">
                                                    Mbps
                                                </div>
                                                {target.trend !== 'stable' && (
                                                    <div className="text-xs text-gray-500 dark:text-gray-400">
                                                        {target.trendPercentage.toFixed(1)}%
                                                    </div>
                                                )}
                                            </div>
                                        </div>
                                    </div>
                                ))}
                                
                                {targets.length > 6 && (
                                    <div className="text-center text-xs text-gray-500 dark:text-gray-400 py-2">
                                        +{targets.length - 6} more targets
                                    </div>
                                )}
                            </div>
                        </div>
                    )}
                </div>
            )}
        </div>
    );
};

export default RperfBandwidthWidget;