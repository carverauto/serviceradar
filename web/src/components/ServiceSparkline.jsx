import React, { useState, useEffect, useMemo } from 'react';
import { LineChart, Line, YAxis, ResponsiveContainer } from 'recharts';

const ResponseTimeSparkline = ({ nodeId, serviceName }) => {
    const [metrics, setMetrics] = useState([]);

    useEffect(() => {
        const fetchMetrics = async () => {
            try {
                const response = await fetch(`/api/nodes/${nodeId}/metrics`);
                if (!response.ok) throw new Error('Failed to fetch metrics');
                const data = await response.json();

                // Filter metrics for specific service
                const serviceMetrics = data
                    .filter(m => m.service_name === serviceName)
                    .map(m => ({
                        timestamp: new Date(m.timestamp).getTime(),
                        value: m.response_time / 1000000 // Convert ns to ms
                    }));

                setMetrics(serviceMetrics);
            } catch (error) {
                console.error('Error fetching metrics:', error);
            }
        };

        if (nodeId && serviceName) {
            fetchMetrics();
            const interval = setInterval(fetchMetrics, 10000);
            return () => clearInterval(interval);
        }
    }, [nodeId, serviceName]);

    if (!metrics.length) return null;

    return (
        <div className="h-8 w-24">
            <ResponsiveContainer width="100%" height="100%">
                <LineChart data={metrics}>
                    <YAxis
                        type="number"
                        domain={['dataMin', 'dataMax']}
                        hide={true}
                    />
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
    );
};

export default ResponseTimeSparkline;