// src/components/NodeTimeline.tsx - Convert from JSX to TSX
import React, { useState, useEffect } from 'react';
import {
    AreaChart,
    Area,
    XAxis,
    YAxis,
    CartesianGrid,
    Tooltip,
    ResponsiveContainer,
} from 'recharts';
import { fetchFromAPI } from '@/lib/api';
import CustomTooltip from './CustomTooltip';

// Define the NodeHistoryEntry interface
export interface NodeHistoryEntry {
    timestamp: string;
    is_healthy: boolean;
    // Add any other properties from your history data
}

// Define the component props interface
interface NodeTimelineProps {
    nodeId: string;
    initialHistory?: NodeHistoryEntry[];
}

const NodeTimeline: React.FC<NodeTimelineProps> = ({ nodeId, initialHistory = [] }) => {
    const [availabilityData, setAvailabilityData] = useState<NodeHistoryEntry[]>(initialHistory);
    const [loading, setLoading] = useState(initialHistory.length === 0);
    const [error, setError] = useState<string | null>(null);

    useEffect(() => {
        const fetchData = async () => {
            try {
                const data = await fetchFromAPI<NodeHistoryEntry[]>(`/nodes/${nodeId}/history`);

                if (data) {
                    // Transform the history data for the chart
                    const timelineData = data.map((point) => ({
                        timestamp: new Date(point.timestamp).getTime(),
                        status: point.is_healthy ? 1 : 0,
                        tooltipTime: new Date(point.timestamp).toLocaleString(),
                        is_healthy: point.is_healthy
                    }));

                    setAvailabilityData(timelineData as unknown as NodeHistoryEntry[]);
                    setLoading(false);
                }
            } catch (err) {
                console.error('Error fetching history:', err);
                setError((err as Error).message);
                setLoading(false);
            }
        };

        // Use initial history if provided
        if (initialHistory.length > 0 && availabilityData.length === 0) {
            setAvailabilityData(initialHistory);
            setLoading(false);
        }

        fetchData();
        const interval = setInterval(fetchData, 10000);
        return () => clearInterval(interval);
    }, [nodeId, initialHistory, availabilityData.length]);

    if (loading && availabilityData.length === 0) {
        return <div className="text-center p-4">Loading timeline...</div>;
    }

    if (error && availabilityData.length === 0) {
        return <div className="text-red-500 text-center p-4">{error}</div>;
    }

    return (
        <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 transition-colors">
            <h3 className="text-lg font-semibold mb-4 text-gray-800 dark:text-gray-100">
                Node Availability Timeline
            </h3>
            <div className="h-48">
                <ResponsiveContainer width="100%" height="100%">
                    <AreaChart data={availabilityData}>
                        <CartesianGrid strokeDasharray="3 3" />
                        <XAxis
                            dataKey="timestamp"
                            type="number"
                            domain={['auto', 'auto']}
                            tickFormatter={(ts) => new Date(ts).toLocaleTimeString()}
                        />
                        <YAxis
                            domain={[0, 1]}
                            ticks={[0, 1]}
                            tickFormatter={(value) => (value === 1 ? 'Online' : 'Offline')}
                        />
                        <Tooltip content={<CustomTooltip />} />
                        <defs>
                            <linearGradient id="availabilityGradient" x1="0" y1="0" x2="0" y2="1">
                                <stop offset="5%" stopColor="#8884d8" stopOpacity={0.8}/>
                                <stop offset="95%" stopColor="#8884d8" stopOpacity={0.2}/>
                            </linearGradient>
                        </defs>
                        <Area
                            type="stepAfter"
                            dataKey="status"
                            stroke="#8884d8"
                            strokeWidth={2}
                            fill="url(#availabilityGradient)"
                            dot={false}
                            isAnimationActive={false}
                        />
                    </AreaChart>
                </ResponsiveContainer>
            </div>
        </div>
    );
};

export default NodeTimeline;