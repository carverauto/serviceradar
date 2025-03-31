'use client';

import React, { useState, useEffect } from 'react';
import { AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer } from 'recharts';
import { useRouter, useSearchParams } from 'next/navigation';
import { useAuth } from '@/components/AuthProvider';

interface RperfMetric {
    name: string; // e.g., "rperf_tcp_bandwidth"
    type: string; // "rperf"
    value: string;
    timestamp: string;
    metadata: {
        target: string;
        success: boolean;
        error?: string;
        bits_per_second: number;
        bytes_received: number;
        bytes_sent: number;
        duration: number;
        jitter_ms: number;
        loss_percent: number;
        packets_lost: number;
        packets_received: number;
        packets_sent: number;
    };
}

const REFRESH_INTERVAL = 10000; // 10 seconds

const RperfDashboard: React.FC<{
    nodeId: string;
    serviceName: string;
    initialData?: RperfMetric[];
    initialTimeRange?: string;
}> = ({ nodeId, serviceName, initialData = [], initialTimeRange = '1h' }) => {
    const router = useRouter();
    const searchParams = useSearchParams();
    const { token } = useAuth();
    const [rperfData, setRperfData] = useState<RperfMetric[]>(initialData);
    const [timeRange, setTimeRange] = useState<string>(searchParams.get('timeRange') || initialTimeRange);
    const [chartHeight, setChartHeight] = useState<number>(384);

    useEffect(() => {
        const handleResize = () => {
            const width = window.innerWidth;
            if (width < 640) setChartHeight(250);
            else if (width < 1024) setChartHeight(300);
            else setChartHeight(384);
        };

        handleResize();
        window.addEventListener('resize', handleResize);
        return () => window.removeEventListener('resize', handleResize);
    }, []);

    useEffect(() => {
        const fetchRperfData = async () => {
            const end = new Date();
            const start = new Date();
            switch (timeRange) {
                case '1h': start.setHours(end.getHours() - 1); break;
                case '6h': start.setHours(end.getHours() - 6); break;
                case '24h': start.setHours(end.getHours() - 24); break;
            }

            try {
                const headers: HeadersInit = { 'Content-Type': 'application/json' };
                if (token) headers['Authorization'] = `Bearer ${token}`;

                const response = await fetch(
                    `/api/nodes/${nodeId}/metrics?start=${start.toISOString()}&end=${end.toISOString()}`,
                    { headers, cache: 'no-store' }
                );

                if (response.ok) {
                    const data: RperfMetric[] = await response.json();
                    setRperfData(data.filter(m => m.type === 'rperf'));
                }
            } catch (error) {
                console.error('Error fetching rperf data:', error);
            }
        };

        fetchRperfData();
        const interval = setInterval(fetchRperfData, REFRESH_INTERVAL);
        return () => clearInterval(interval);
    }, [nodeId, timeRange, token]);

    const filterDataByTimeRange = (data: RperfMetric[]) => {
        const now = Date.now();
        const ranges: { [key: string]: number } = {
            '1h': 60 * 60 * 1000,
            '6h': 6 * 60 * 60 * 1000,
            '24h': 24 * 60 * 60 * 1000,
        };
        const timeLimit = now - ranges[timeRange];
        return data.filter((point) => new Date(point.timestamp).getTime() >= timeLimit);
    };

    const handleTimeRangeChange = (range: string) => {
        setTimeRange(range);
        const params = new URLSearchParams(searchParams.toString());
        params.set('timeRange', range);
        router.push(`/service/${nodeId}/${serviceName}?${params.toString()}`, { scroll: false });
    };

    const chartData = filterDataByTimeRange(rperfData).map((point) => ({
        timestamp: new Date(point.timestamp).getTime(),
        [point.name]: parseFloat(point.value),
    }));

    return (
        <div className="space-y-6">
            <div className="flex justify-between items-center bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
                <h3 className="text-lg font-semibold text-gray-800 dark:text-gray-100">
                    Rperf Metrics
                </h3>
                <div className="flex gap-2">
                    {['1h', '6h', '24h'].map((range) => (
                        <button
                            key={range}
                            onClick={() => handleTimeRangeChange(range)}
                            className={`px-3 py-1 rounded ${timeRange === range ? 'bg-blue-500 text-white' : 'bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-100'}`}
                        >
                            {range}
                        </button>
                    ))}
                </div>
            </div>

            {['bandwidth', 'jitter', 'loss'].map((metricType) => {
                const metrics = rperfData.filter(m => m.name.includes(metricType));
                const unit = metricType === 'bandwidth' ? 'Mbps' : metricType === 'jitter' ? 'ms' : '%';
                const color = metricType === 'bandwidth' ? '#8884d8' : metricType === 'jitter' ? '#82ca9d' : '#ff7300';

                return (
                    <div key={metricType} className="bg-white dark:bg-gray-800 rounded-lg shadow p-4">
                        <h4 className="text-md font-medium mb-2 text-gray-800 dark:text-gray-100">
                            {metricType.charAt(0).toUpperCase() + metricType.slice(1)} ({unit})
                        </h4>
                        <div style={{ height: `${chartHeight}px` }}>
                            <ResponsiveContainer>
                                <AreaChart data={chartData}>
                                    <CartesianGrid strokeDasharray="3 3" />
                                    <XAxis dataKey="timestamp" tickFormatter={(ts) => new Date(ts).toLocaleTimeString()} />
                                    <YAxis unit={` ${unit}`} />
                                    <Tooltip labelFormatter={(ts) => new Date(ts).toLocaleString()} />
                                    <Legend />
                                    {metrics.map((metric) => (
                                        <Area
                                            key={metric.name}
                                            type="monotone"
                                            dataKey={metric.name}
                                            stroke={color}
                                            fill={color}
                                            fillOpacity={0.3}
                                            name={`${metric.metadata.target} ${metricType}`}
                                        />
                                    ))}
                                </AreaChart>
                            </ResponsiveContainer>
                        </div>
                    </div>
                );
            })}
        </div>
    );
};

export default RperfDashboard;