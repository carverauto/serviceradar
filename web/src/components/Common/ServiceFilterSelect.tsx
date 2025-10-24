'use client';

import React from 'react';

interface ServiceFilterSelectProps {
    label?: string;
    value: string;
    services: string[];
    onChange: (value: string) => void;
    includeAllOption?: boolean;
    className?: string;
    disabled?: boolean;
}

export const ServiceFilterSelect: React.FC<ServiceFilterSelectProps> = ({
    label = 'Service:',
    value,
    services,
    onChange,
    includeAllOption = true,
    className = '',
    disabled = false
}) => {
    return (
        <div className={`flex items-center gap-2 ${className}`}>
            <label className="text-xs text-gray-700 dark:text-gray-300 whitespace-nowrap">
                {label}
            </label>
            <select
                value={value}
                onChange={(e) => onChange(e.target.value)}
                disabled={disabled}
                className="text-sm border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white px-2 py-1 focus:ring-green-500 focus:border-green-500 disabled:opacity-60 disabled:cursor-not-allowed"
            >
                {includeAllOption && <option value="all">All</option>}
                {services.map((service) => (
                    <option key={service} value={service}>
                        {service}
                    </option>
                ))}
            </select>
        </div>
    );
};

export default ServiceFilterSelect;

