// web/src/components/NodeTimeline.jsx
import React, { useState, useEffect } from 'react';
import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts';

const NodeTimeline = ({ nodeId }) => {
    const [availabilityData, setAvailabilityData] = useState([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState(null);

    useEffect(() => {
        const fetchData = async () => {
            try {
                const response = await fetch(`/api/nodes/${nodeId}`);
                if (!response.ok) throw new Error('Failed to fetch node data');
                const data = await response.json();

                console.log('Raw node data:', data); // Debug logging

                // Ensure we have the required data
                if (!data || !data.services) {
                    throw new Error('Invalid data format received');
                }

                // Transform the data into timeline format
                const timelinePoint = {
                    timestamp: new Date(data.last_update).getTime(),
                    status: data.is_healthy ? 1 : 0,
                    tooltipTime: new Date(data.last_update).toLocaleString(),
                    services: data.services.map(s => ({
                        name: s.name,
                        available: s.available
                    })) || []
                };

                // Add to availability data, keeping last 100 points
                setAvailabilityData(prev => {
                    const newData = [...prev, timelinePoint];
                    if (newData.length > 100) {
                        return newData.slice(-100);
                    }
                    return newData;
                });

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

    const CustomTooltip = ({ active, payload }) => {
        if (!active || !payload || !payload.length) return null;

        const data = payload[0].payload;
        if (!data) return null;

        return (
            <div className="bg-white p-4 rounded shadow-lg border">
                <p className="text-sm font-semibold">{data.tooltipTime}</p>
                <p className="text-sm">Status: {data.status === 1 ? 'Online' : 'Offline'}</p>
                {data.services && data.services.length > 0 && (
                    <div className="mt-2">
                        <p className="text-xs font-semibold">Services:</p>
                        {data.services.map((service, idx) => (
                            <p key={`${service.name}-${idx}`} className="text-xs">
                                {service.name}: {service.available ? 'Available' : 'Unavailable'}
                            </p>
                        ))}
                    </div>
                )}
            </div>
        );
    };

    if (loading && availabilityData.length === 0) {
        return (
            <div className="bg-white rounded-lg shadow p-4">
                <div className="flex items-center justify-center h-48">
                    <div className="text-lg">Loading timeline...</div>
                </div>
            </div>
        );
    }

    if (error && availabilityData.length === 0) {
        return (
            <div className="bg-white rounded-lg shadow p-4">
                <div className="flex items-center justify-center h-48">
                    <div className="text-red-500">{error}</div>
                </div>
            </div>
        );
    }

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