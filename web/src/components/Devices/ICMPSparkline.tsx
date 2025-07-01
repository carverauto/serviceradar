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

import React, { useState, useEffect, useMemo } from 'react';
import { AreaChart, Area, YAxis, ResponsiveContainer } from 'recharts';
import { TrendingUp, TrendingDown, Minus } from 'lucide-react';
import _ from 'lodash';

const MAX_POINTS = 50;
const REFRESH_INTERVAL = 10000; // 10 seconds

interface ICMPSparklineProps {
    deviceId: string;
    compact?: boolean;
    hasMetrics?: boolean;
}

interface ICMPMetric {
    name: string;
    value: string;
    type: string;
    timestamp: string;
    metadata: string;
    device_id: string;
    partition: string;
    poller_id: string;
}


const ICMPSparkline: React.FC<ICMPSparklineProps> = ({ 
    deviceId,
    compact = false,
    hasMetrics
}) => {
    const [metrics, setMetrics] = useState<ICMPMetric[]>([]);
    const [isLoading, setIsLoading] = useState(false);
    const [hasData, setHasData] = useState(false);

    useEffect(() => {
        if (hasMetrics === false) {
            setHasData(false);
            return;
        }
        
        fetchMetrics();
        const interval = setInterval(fetchMetrics, REFRESH_INTERVAL);
        return () => clearInterval(interval);
    }, [deviceId, hasMetrics]);

    const fetchMetrics = async () => {
        if (!deviceId || hasMetrics === false) return;
        
        setIsLoading(true);
        try {
            const endTime = new Date();
            const startTime = new Date(endTime.getTime() - 60 * 60 * 1000); // Last hour
            
            const queryParams = new URLSearchParams({
                type: 'icmp',
                start: startTime.toISOString(),
                end: endTime.toISOString()
            });

            const response = await fetch(`/api/devices/${encodeURIComponent(deviceId)}/metrics?${queryParams}`);
            
            if (response.ok) {
                const data = await response.json() as ICMPMetric[];
                setMetrics(data || []);
                setHasData(data && data.length > 0);
            } else {
                setMetrics([]);
                setHasData(false);
            }
        } catch (error) {
            console.error(`Error fetching ICMP metrics for device ${deviceId}:`, error);
            setMetrics([]);
            setHasData(false);
        } finally {
            setIsLoading(false);
        }
    };

    const processedMetrics = useMemo(() => {
        if (!metrics || metrics.length === 0) {
            return [];
        }

        const chartData = metrics
            .map((m) => {
                // Parse response time from nanoseconds string to milliseconds
                const responseTimeNs = parseInt(m.value) || 0;
                const responseTimeMs = responseTimeNs / 1000000;
                
                return {
                    timestamp: new Date(m.timestamp).getTime(),
                    value: responseTimeMs,
                };
            })
            .filter(point => point.value > 0) // Filter out invalid/zero values
            .sort((a, b) => a.timestamp - b.timestamp)
            .slice(-MAX_POINTS); // Limit to recent points

        if (chartData.length < 2) return chartData;

        // Downsample for performance if we have many points
        const step = Math.max(1, Math.floor(chartData.length / 15));
        return chartData.filter((_, i) => i % step === 0 || i === chartData.length - 1);
    }, [metrics]);

    const trend = useMemo(() => {
        if (processedMetrics.length < 4) return 'neutral';

        const half = Math.floor(processedMetrics.length / 2);
        const firstHalf = processedMetrics.slice(0, half);
        const secondHalf = processedMetrics.slice(half);

        const firstAvg = _.meanBy(firstHalf, 'value') || 0;
        const secondAvg = _.meanBy(secondHalf, 'value') || 0;

        if (firstAvg === 0) return secondAvg > 0 ? 'up' : 'neutral';

        const changePct = ((secondAvg - firstAvg) / firstAvg) * 100;

        if (Math.abs(changePct) < 10) return 'neutral';
        return changePct > 0 ? 'up' : 'down';
    }, [processedMetrics]);

    // Only show if we have ICMP metrics
    if (hasMetrics === false || (!isLoading && hasMetrics === undefined && !hasData)) {
        return null;
    }

    if (compact) {
        if (processedMetrics.length === 0) {
            if (isLoading) {
                return (
                    <div className="h-4 w-6 bg-gray-600 animate-pulse rounded"></div>
                );
            }
            return null;
        }

        const latestValue = processedMetrics[processedMetrics.length - 1]?.value || 0;
        const color = latestValue < 50 ? '#10b981' : latestValue < 100 ? '#f59e0b' : '#ef4444';

        return (
            <div className="relative group">
                <div className="h-4 w-6">
                    <ResponsiveContainer width="100%" height="100%">
                        <AreaChart data={processedMetrics}>
                            <defs>
                                <linearGradient id={`icmp-gradient-${deviceId}`} x1="0" y1="0" x2="0" y2="1">
                                    <stop offset="5%" stopColor={color} stopOpacity={0.8} />
                                    <stop offset="95%" stopColor={color} stopOpacity={0.2} />
                                </linearGradient>
                            </defs>
                            <YAxis type="number" domain={['dataMin', 'dataMax']} hide />
                            <Area
                                type="monotone"
                                dataKey="value"
                                stroke={color}
                                strokeWidth={1}
                                fill={`url(#icmp-gradient-${deviceId})`}
                                baseValue="dataMin"
                                dot={false}
                                isAnimationActive={false}
                            />
                        </AreaChart>
                    </ResponsiveContainer>
                </div>
                <div className="absolute bottom-full left-1/2 transform -translate-x-1/2 mb-1 px-2 py-1 text-xs text-white bg-gray-900 rounded-md opacity-0 group-hover:opacity-100 transition-opacity whitespace-nowrap z-10">
                    ICMP: {latestValue.toFixed(1)}ms
                </div>
            </div>
        );
    }

    // Full size version
    if (processedMetrics.length === 0) {
        return null;
    }

    const latestValue = processedMetrics[processedMetrics.length - 1]?.value || 0;

    return (
        <div className="flex flex-col items-center transition-colors">
            <div className="h-8 w-24">
                <ResponsiveContainer width="100%" height="100%">
                    <AreaChart data={processedMetrics}>
                        <defs>
                            <linearGradient id={`icmp-sparkline-gradient-${deviceId}`} x1="0" y1="0" x2="0" y2="1">
                                <stop offset="5%" stopColor="#10b981" stopOpacity={0.8} />
                                <stop offset="95%" stopColor="#10b981" stopOpacity={0.2} />
                            </linearGradient>
                        </defs>
                        <YAxis type="number" domain={['dataMin', 'dataMax']} hide />
                        <Area
                            type="monotone"
                            dataKey="value"
                            stroke="#10b981"
                            strokeWidth={1.5}
                            fill={`url(#icmp-sparkline-gradient-${deviceId})`}
                            baseValue="dataMin"
                            dot={false}
                            isAnimationActive={false}
                        />
                    </AreaChart>
                </ResponsiveContainer>
            </div>
            <div className="flex items-center gap-1 text-xs text-gray-600 dark:text-gray-300">
                <span>{latestValue ? `${latestValue.toFixed(1)}ms` : 'N/A'}</span>
                {trend === 'up' && <TrendingUp className="h-3 w-3 text-red-500 dark:text-red-400" />}
                {trend === 'down' && <TrendingDown className="h-3 w-3 text-green-500 dark:text-green-400" />}
                {trend === 'neutral' && <Minus className="h-3 w-3 text-gray-400 dark:text-gray-500" />}
            </div>
        </div>
    );
};

export default ICMPSparkline;