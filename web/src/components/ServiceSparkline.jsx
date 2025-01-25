import React from 'react';
import { LineChart, Line, YAxis, Tooltip } from 'recharts';

const ServiceSparkline = ({ history, serviceName }) => {
    // Transform history into proper data format
    const data = history?.map(point => ({
        value: point.response_time ? point.response_time / 1000000 : 0, // Convert ns to ms
        timestamp: new Date(point.timestamp).getTime()
    })) || [];

    if (!data.length) return null;

    return (
        <div className="h-12 w-32">
            <LineChart width={128} height={48} data={data}>
                <YAxis
                    type="number"
                    domain={['dataMin', 'dataMax']}
                    hide={true}
                />
                <Tooltip
                    formatter={(value) => `${(value).toFixed(2)}ms`}
                    labelFormatter={(ts) => new Date(ts).toLocaleTimeString()}
                />
                <Line
                    type="monotone"
                    dataKey="value"
                    stroke="#6366f1"
                    dot={false}
                    strokeWidth={1.5}
                    isAnimationActive={false}
                />
            </LineChart>
        </div>
    );
};

export default ServiceSparkline;