import React, { useState, useEffect, useMemo } from 'react';
import { LineChart, Line, YAxis, ResponsiveContainer } from 'recharts';
import { TrendingUp, TrendingDown, Minus } from 'lucide-react';
import _ from 'lodash';

const MAX_POINTS = 100;
const POLLING_INTERVAL = 10;

const interpolatePoints = (points) => {
    if (points.length < 2) return points;

    const result = [];
    for (let i = 0; i < points.length - 1; i++) {
        const current = points[i];
        const next = points[i + 1];
        const timeDiff = next.timestamp - current.timestamp;

        if (timeDiff > POLLING_INTERVAL * 1000) {
            const steps = Math.min(Math.floor(timeDiff / (POLLING_INTERVAL * 1000)), 5);
            const valueStep = (next.value - current.value) / steps;
            const timeStep = timeDiff / steps;

            result.push(current);
            for (let j = 1; j < steps; j++) {
                result.push({
                    timestamp: current.timestamp + timeStep * j,
                    value: current.value + valueStep * j,
                });
            }
        } else {
            result.push(current);
        }
    }
    result.push(points[points.length - 1]);
    return result;
};

const getTrend = (metrics) => {
    if (metrics.length < 2) return 'neutral';

    // Get average of first half and second half
    const half = Math.floor(metrics.length / 2);
    const firstHalf = metrics.slice(0, half);
    const secondHalf = metrics.slice(half);

    const firstAvg = _.meanBy(firstHalf, 'value');
    const secondAvg = _.meanBy(secondHalf, 'value');

    const changePct = ((secondAvg - firstAvg) / firstAvg) * 100;

    if (Math.abs(changePct) < 5) return 'neutral';
    return changePct > 0 ? 'up' : 'down';
};

const ServiceSparkline = ({ nodeId, serviceName }) => {
    const [metrics, setMetrics] = useState([]);

    useEffect(() => {
        const fetchMetrics = async () => {
            try {
                const response = await fetch(`/api/nodes/${nodeId}/metrics`);
                if (!response.ok) throw new Error('Failed to fetch metrics');
                const data = await response.json();

                const serviceMetrics = data
                    .filter((m) => m.service_name === serviceName)
                    .map((m) => ({
                        timestamp: new Date(m.timestamp).getTime(),
                        value: m.response_time / 1000000,
                    }))
                    .sort((a, b) => a.timestamp - b.timestamp);

                const recentMetrics = serviceMetrics.slice(-MAX_POINTS);
                setMetrics(recentMetrics);
            } catch (error) {
                console.error('Error fetching metrics:', error);
            }
        };

        if (nodeId && serviceName) {
            fetchMetrics();
            const interval = setInterval(fetchMetrics, POLLING_INTERVAL * 1000);
            return () => clearInterval(interval);
        }
    }, [nodeId, serviceName]);

    const processedMetrics = useMemo(() => {
        return interpolatePoints(metrics);
    }, [metrics]);

    if (!processedMetrics.length) return null;

    const latestValue = processedMetrics[processedMetrics.length - 1]?.value;
    const trend = getTrend(processedMetrics);

    return (
        <div className="flex flex-col items-center transition-colors">
            <div className="h-8 w-24">
                <ResponsiveContainer width="100%" height="100%">
                    <LineChart data={processedMetrics}>
                        <YAxis type="number" domain={['dataMin', 'dataMax']} hide />
                        <Line
                            type="monotone"
                            dataKey="value"
                            stroke="#6366f1" // If you want a different stroke in dark mode, do inline logic or props
                            dot={false}
                            strokeWidth={1}
                            isAnimationActive={false}
                        />
                    </LineChart>
                </ResponsiveContainer>
            </div>
            <div className="flex items-center gap-1 text-xs text-gray-600 dark:text-gray-300">
        <span>
          {latestValue ? `${latestValue.toFixed(4)}ms` : 'N/A'}
        </span>
                {trend === 'up' && <TrendingUp className="h-3 w-3 text-red-500 dark:text-red-400" />}
                {trend === 'down' && <TrendingDown className="h-3 w-3 text-green-500 dark:text-green-400" />}
                {trend === 'neutral' && <Minus className="h-3 w-3 text-gray-400 dark:text-gray-500" />}
            </div>
        </div>
    );
};

export default ServiceSparkline;
