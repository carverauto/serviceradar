'use client';

import React, { useState, useEffect, useMemo } from 'react';
import { LineChart, Line, YAxis, ResponsiveContainer } from 'recharts';
import { TrendingUp, TrendingDown, Minus } from 'lucide-react';
import _ from 'lodash';
import { useAPIData } from '../lib/api';

const MAX_POINTS = 100;
const POLLING_INTERVAL = 10000; // 10 seconds

const ServiceSparkline = React.memo(({ nodeId, serviceName, initialMetrics = [] }) => {
    const { data: metrics, error, isLoading } = useAPIData(
        `/api/nodes/${nodeId}/metrics`,
        initialMetrics,
        POLLING_INTERVAL
    );

    const [errorState, setError] = useState(error); // Handle initial error state

    const processedMetrics = useMemo(() => {
        if (!metrics || metrics.length === 0) return [];

        const serviceMetrics = metrics
            .filter((m) => m.service_name === serviceName)
            .map((m) => ({
                timestamp: new Date(m.timestamp).getTime(),
                value: m.response_time / 1000000, // Convert to milliseconds
            }))
            .sort((a, b) => a.timestamp - b.timestamp)
            .slice(-MAX_POINTS); // Limit to recent points

        if (serviceMetrics.length < 5) return serviceMetrics;

        // Downsample for performance
        const step = Math.max(1, Math.floor(serviceMetrics.length / 20));
        return serviceMetrics.filter((_, i) => i % step === 0 || i === serviceMetrics.length - 1);
    }, [metrics, serviceName]);

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

    useEffect(() => {
        setError(error); // Sync error state with useAPIData
    }, [error]);

    if (isLoading && !processedMetrics.length) {
        return <div className="flex flex-col items-center transition-colors h-8 w-24">
            <div className="h-8 w-24 bg-gray-100 dark:bg-gray-700 animate-pulse rounded"></div>
        </div>;
    }

    if (errorState) {
        return <div className="text-xs text-red-500 dark:text-red-400">Error</div>;
    }

    const latestValue = processedMetrics[processedMetrics.length - 1]?.value || 0;

    return (
        <div className="flex flex-col items-center transition-colors">
            <div className="h-8 w-24">
                <ResponsiveContainer width="100%" height="100%">
                    <LineChart data={processedMetrics}>
                        <YAxis type="number" domain={['dataMin', 'dataMax']} hide />
                        <Line
                            type="monotone"
                            dataKey="value"
                            stroke="#6366f1"
                            dot={false}
                            strokeWidth={1}
                            isAnimationActive={false}
                        />
                    </LineChart>
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

ServiceSparkline.displayName = 'ServiceSparkline'; // Helpful for debugging

export default ServiceSparkline;