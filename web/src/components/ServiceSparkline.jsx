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
import { useRouter } from 'next/navigation';

const MAX_POINTS = 100;
const REFRESH_INTERVAL = 10000; // 10 seconds

const ServiceSparkline = React.memo(({ nodeId, serviceName, initialMetrics = [] }) => {
    const router = useRouter();
    const [metrics, setMetrics] = useState(initialMetrics);

    // Update metrics when initialMetrics changes from server
    useEffect(() => {
        setMetrics(initialMetrics);
    }, [initialMetrics]);

    // Set up periodic refresh to trigger server-side data update
    useEffect(() => {
        const interval = setInterval(() => {
            router.refresh(); // Triggers server-side re-fetch of nodes/page.js
        }, REFRESH_INTERVAL);

        return () => clearInterval(interval);
    }, [router]);

    const processedMetrics = useMemo(() => {
        if (!metrics || metrics.length === 0) {
            console.log(`No metrics available for ${nodeId}/${serviceName}`);
            return [];
        }

        console.log(`Processing ${metrics.length} metrics for ${nodeId}/${serviceName}`);

        const serviceMetrics = metrics
            .filter((m) => m.service_name === serviceName)
            .map((m) => ({
                timestamp: new Date(m.timestamp).getTime(),
                value: m.response_time / 1000000, // Convert to milliseconds
            }))
            .sort((a, b) => a.timestamp - b.timestamp)
            .slice(-MAX_POINTS); // Limit to recent points

        console.log(`Filtered to ${serviceMetrics.length} service-specific metrics`);

        if (serviceMetrics.length < 5) return serviceMetrics;

        // Downsample for performance
        const step = Math.max(1, Math.floor(serviceMetrics.length / 20));
        return serviceMetrics.filter((_, i) => i % step === 0 || i === serviceMetrics.length - 1);
    }, [metrics, serviceName, nodeId]);

    const trend = useMemo(() => {
        if (processedMetrics.length < 5) return 'neutral';

        const half = Math.floor(processedMetrics.length / 2);
        const firstHalf = processedMetrics.slice(0, half);
        const secondHalf = processedMetrics.slice(half);

        const firstAvg = _.meanBy(firstHalf, 'value') || 0;
        const secondAvg = _.meanBy(secondHalf, 'value') || 0;

        if (firstAvg === 0) return secondAvg > 0 ? 'up' : 'neutral';

        const changePct = ((secondAvg - firstAvg) / firstAvg) * 100;

        if (Math.abs(changePct) < 5) return 'neutral';
        return changePct > 0 ? 'up' : 'down';
    }, [processedMetrics]);

    if (processedMetrics.length === 0) {
        return <div className="text-xs text-gray-600 dark:text-gray-300">No data</div>;
    }

    const latestValue = processedMetrics[processedMetrics.length - 1]?.value || 0;

    return (
        <div className="flex flex-col items-center transition-colors">
            <div className="h-8 w-24">
                <ResponsiveContainer width="100%" height="100%">
                    <AreaChart data={processedMetrics}>
                        <defs>
                            <linearGradient id={`sparkline-gradient-${nodeId}-${serviceName}`} x1="0" y1="0" x2="0" y2="1">
                                <stop offset="5%" stopColor="#6366f1" stopOpacity={0.6} />
                                <stop offset="95%" stopColor="#6366f1" stopOpacity={0.1} />
                            </linearGradient>
                        </defs>
                        <YAxis type="number" domain={['dataMin', 'dataMax']} hide />
                        <Area
                            type="monotone"
                            dataKey="value"
                            stroke="#6366f1"
                            strokeWidth={1.5}
                            fill={`url(#sparkline-gradient-${nodeId}-${serviceName})`}
                            baseValue="dataMin"
                            dot={false}
                            isAnimationActive={false}
                        />
                    </AreaChart>
                </ResponsiveContainer>
            </div>
            <div className="flex items-center gap-1 text-xs text-gray-600 dark:text-gray-300">
                <span>{latestValue ? `${latestValue.toFixed(2)}ms` : 'N/A'}</span>
                {trend === 'up' && <TrendingUp className="h-3 w-3 text-red-500 dark:text-red-400" />}
                {trend === 'down' && <TrendingDown className="h-3 w-3 text-green-500 dark:text-green-400" />}
                {trend === 'neutral' && <Minus className="h-3 w-3 text-gray-400 dark:text-gray-500" />}
            </div>
        </div>
    );
});

ServiceSparkline.displayName = 'ServiceSparkline';

export default ServiceSparkline;