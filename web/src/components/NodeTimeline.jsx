import React, { useState, useEffect } from 'react';
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts';

const NodeTimeline = ({ nodeId }) => {
    const [availabilityData, setAvailabilityData] = useState([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState(null);

    useEffect(() => {
        const fetchData = async () => {
            try {
                const response = await fetch(`/api/nodes/${nodeId}/history`);
                if (!response.ok) throw new Error('Failed to fetch node history');
                const data = await response.json();

                // Transform data for timeline
                const timelineData = data.map(entry => ({
                    timestamp: new Date(entry.timestamp).getTime(),
                    status: entry.is_healthy ? 1 : 0,
                    tooltipTime: new Date(entry.timestamp).toLocaleString(),
                    services: entry.services.map(s => ({
                        name: s.name,
                        available: s.available
                    }))
                }));

                setAvailabilityData(timelineData);
                setLoading(false);
            } catch (err) {
                console.error('Error fetching availability data:', err);
                setError(err.message);
                setLoading(false);
            }
        };

        fetchData();
        const interval = setInterval(fetchData, 10000);
        return () => clearInterval(interval);
    }, [nodeId]);

    if (loading) {
        return (
            <div className="flex items-center justify-center h-48">
                <div className="text-lg">Loading timeline...</div>
            </div>
        );
    }

    if (error) {
        return (
            <div className="flex items-center justify-center h-48">
                <div className="text-red-500">{error}</div>
            </div>
        );
    }

    const CustomTooltip = ({ active, payload, label }) => {
        if (active && payload && payload.length) {
            const data = payload[0].payload;
            return (
                <div className="bg-white p-4 rounded shadow-lg border">
                    <p className="text-sm font-semibold">{data.tooltipTime}</p>
                    <p className="text-sm">Status: {data.status === 1 ? 'Online' : 'Offline'}</p>
                    <div className="mt-2">
                        <p className="text-xs font-semibold">Services:</p>
                        {data.services.map(service => (
                            <p key={service.name} className="text-xs">
                                {service.name}: {service.available ? 'Available' : 'Unavailable'}
                            </p>
                        ))}
                    </div>
                </div>
            );
        }
        return null;
    };

    return (
        <div className="bg-white rounded-lg shadow p-4">
            <h3 className="text-lg font-semibold mb-4">Node Availability Timeline</h3>
            <div className="h-48">
                <ResponsiveContainer width="100%" height="100%">
                    <LineChart data={availabilityData}>
                        <CartesianGrid strokeDasharray="3 3" />
                        <XAxis
                            dataKey="timestamp"
                            type="number"
                            domain={['auto', 'auto']}
                            tickFormatter={(timestamp) => new Date(timestamp).toLocaleTimeString()}
                        />
                        <YAxis
                            domain={[0, 1]}
                            ticks={[0, 1]}
                            tickFormatter={(value) => value === 1 ? 'Online' : 'Offline'}
                        />
                        <Tooltip content={<CustomTooltip />} />
                        <Line
                            type="stepAfter"
                            dataKey="status"
                            stroke="#8884d8"
                            dot={false}
                            isAnimationActive={false}
                        />
                    </LineChart>
                </ResponsiveContainer>
            </div>
        </div>
    );
};

export default NodeTimeline;