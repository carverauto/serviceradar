import React from 'react';
import { AlertTriangle, ArrowDown, ArrowUp } from 'lucide-react';

export const StatusIndicator = ({ value, warning, critical }) => {
    const isWarning = value >= warning;
    const isCritical = value >= critical;

    if (isCritical) {
        return (
            <div className="flex items-center text-red-500 dark:text-red-400">
                <AlertTriangle size={14} className="mr-1" />
                Critical
            </div>
        );
    }

    if (isWarning) {
        return (
            <div className="flex items-center text-yellow-500 dark:text-yellow-400">
                <AlertTriangle size={14} className="mr-1" />
                Warning
            </div>
        );
    }

    return (
        <div className="flex items-center text-green-500 dark:text-green-400">
            <div className="w-2 h-2 rounded-full bg-green-500 dark:bg-green-400 mr-1"></div>
            Normal
        </div>
    );
};

export const ValueDisplay = ({ value, unit, warning, critical, change }) => {
    const isWarning = value >= warning;
    const isCritical = value >= critical;
    let valueColor = 'text-green-500 dark:text-green-400';

    if (isCritical) valueColor = 'text-red-500 dark:text-red-400';
    else if (isWarning) valueColor = 'text-yellow-500 dark:text-yellow-400';

    return (
        <div className="flex items-center">
            <span className={`text-xl font-bold ${valueColor}`}>{value}</span>
            <span className="text-sm ml-1 text-gray-500 dark:text-gray-400">{unit}</span>

            {change !== undefined && (
                <span className={`ml-2 text-xs flex items-center ${change >= 0 ? 'text-red-400 dark:text-red-300' : 'text-green-400 dark:text-green-300'}`}>
                    {change >= 0 ? (
                        <>
                            <ArrowUp size={12} className="mr-1" />
                            +{change.toFixed(1)}%
                        </>
                    ) : (
                        <>
                            <ArrowDown size={12} className="mr-1" />
                            {change.toFixed(1)}%
                        </>
                    )}
                </span>
            )}
        </div>
    );
};

export const ProgressBar = ({ value, warning, critical, max = 100 }) => {
    const percent = (value / max) * 100;
    const isWarning = percent >= warning;
    const isCritical = percent >= critical;

    let barColor = 'bg-green-500 dark:bg-green-400';
    if (isCritical) barColor = 'bg-red-500 dark:bg-red-400';
    else if (isWarning) barColor = 'bg-yellow-500 dark:bg-yellow-400';

    return (
        <div className="w-full bg-gray-200 dark:bg-gray-700 rounded-full h-1.5 my-1">
            <div
                className={`h-1.5 rounded-full ${barColor} transition-all duration-500`}
                style={{ width: `${Math.min(100, percent)}%` }}
            ></div>
        </div>
    );
};

export const CustomTooltip = ({ active, payload, label, metricData }) => {
    if (active && payload && payload.length) {
        return (
            <div className="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded p-2 shadow-lg">
                <p className="text-gray-600 dark:text-gray-300 text-sm">{payload[0].payload.formattedTime}</p>
                <div className="mt-1">
                    {payload.map((entry, index) => {
                        const metricName = entry.dataKey;
                        const unit = metricData && metricData[metricName]?.unit || '';
                        return (
                            <p key={`item-${index}`} className="text-sm" style={{ color: entry.color }}>
                                {metricName.charAt(0).toUpperCase() + metricName.slice(1)}: {entry.value}{unit}
                            </p>
                        );
                    })}
                </div>
            </div>
        );
    }
    return null;
};

export const MetricCard = ({ title, current, unit, warning, critical, change, icon, children }) => {
    return (
        <div className="bg-white dark:bg-gray-800 rounded-lg p-3 shadow transition-colors">
            <div className="flex justify-between items-center mb-2">
                <div className="flex items-center">
                    {icon}
                    <span className="text-sm font-medium text-gray-600 dark:text-gray-300">{title}</span>
                </div>
                <StatusIndicator
                    value={current}
                    warning={warning}
                    critical={critical}
                />
            </div>
            <ValueDisplay
                value={current}
                unit={unit}
                warning={warning}
                critical={critical}
                change={change}
            />
            <ProgressBar
                value={current}
                warning={warning}
                critical={critical}
            />
            {children}
        </div>
    );
};