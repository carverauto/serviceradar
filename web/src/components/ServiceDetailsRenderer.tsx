// src/components/ServiceDetailsRenderer.tsx
import React from 'react';
import { Service } from '@/types/types';
import { PingStatus } from './NetworkStatus';

interface ServiceDetailsRendererProps {
    service: Service;
}

const ServiceDetailsRenderer: React.FC<ServiceDetailsRendererProps> = ({ service }) => {
    // Helper function to recursively render nested objects and arrays
    const renderValue = (value: any, depth: number = 0): JSX.Element | string => {
        if (value === null || value === undefined) {
            return <span className="text-gray-500 italic">N/A</span>;
        }

        if (Array.isArray(value)) {
            if (value.length === 0) {
                return <span className="text-gray-500 italic">[Empty]</span>;
            }
            return (
                <ul className={`list-disc pl-${depth * 4}`}>
                    {value.map((item, index) => (
                        <li key={index} className="text-sm text-gray-900 dark:text-white">
                            {typeof item === 'object' ? renderValue(item, depth + 1) : String(item)}
                        </li>
                    ))}
                </ul>
            );
        }

        if (typeof value === 'object') {
            return (
                <div className={`ml-${depth * 4}`}>
                    {Object.entries(value).map(([key, val]) => (
                        <div key={key} className="text-sm">
              <span className="font-medium text-gray-700 dark:text-gray-300">
                {key.split('_').map(word => word.charAt(0).toUpperCase() + word.slice(1)).join(' ')}:
              </span>
                            <span className="ml-2 text-gray-900 dark:text-white">
                {renderValue(val, depth + 1)}
              </span>
                        </div>
                    ))}
                </div>
            );
        }

        return String(value);
    };

    // Type-specific rendering
    if (service.type === 'icmp' && service.details) {
        return (
            <div className="mb-4">
                <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">ICMP Status</h4>
                <PingStatus details={service.details} />
            </div>
        );
    }

    if (service.type === 'network_sweep' && service.details) {
        const details = typeof service.details === 'string' ? JSON.parse(service.details) : service.details;
        return (
            <div className="mb-4">
                <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Network Sweep Details</h4>
                <div className="grid grid-cols-2 gap-3">
                    {Object.entries(details).map(([key, value]) => (
                        <div key={key} className="text-sm">
              <span className="font-medium text-gray-700 dark:text-gray-300">
                {key.split('_').map(word => word.charAt(0).toUpperCase() + word.slice(1)).join(' ')}:
              </span>
                            <span className="ml-2 text-gray-900 dark:text-white">
                {renderValue(value)}
              </span>
                        </div>
                    ))}
                </div>
            </div>
        );
    }

    if (service.type === 'snmp' && service.details) {
        const details = typeof service.details === 'string' ? JSON.parse(service.details) : service.details;
        return (
            <div className="mb-4">
                <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">SNMP Details</h4>
                <div className="grid grid-cols-2 gap-3">
                    {Object.entries(details).map(([key, value]) => (
                        <div key={key} className="text-sm">
              <span className="font-medium text-gray-700 dark:text-gray-300">
                {key.split('_').map(word => word.charAt(0).toUpperCase() + word.slice(1)).join(' ')}:
              </span>
                            <span className="ml-2 text-gray-900 dark:text-white">
                {renderValue(value)}
              </span>
                        </div>
                    ))}
                </div>
            </div>
        );
    }

    if (service.name === 'rperf-checker' && service.details) {
        const details = typeof service.details === 'string' ? JSON.parse(service.details) : service.details;
        return (
            <div className="mb-4">
                <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Rperf Checker Details</h4>
                <div className="grid grid-cols-2 gap-3">
                    {Object.entries(details).map(([key, value]) => (
                        <div key={key} className="text-sm">
              <span className="font-medium text-gray-700 dark:text-gray-300">
                {key.split('_').map(word => word.charAt(0).toUpperCase() + word.slice(1)).join(' ')}:
              </span>
                            <span className="ml-2 text-gray-900 dark:text-white">
                {renderValue(value)}
              </span>
                        </div>
                    ))}
                </div>
            </div>
        );
    }

    // Generic rendering for other service types
    if (service.details) {
        const details = typeof service.details === 'string' ? JSON.parse(service.details) : service.details;
        return (
            <div className="mb-4">
                <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Details</h4>
                <div className="grid grid-cols-2 gap-3">
                    {Object.entries(details).map(([key, value]) => (
                        <div key={key} className="text-sm">
              <span className="font-medium text-gray-700 dark:text-gray-300">
                {key.split('_').map(word => word.charAt(0).toUpperCase() + word.slice(1)).join(' ')}:
              </span>
                            <span className="ml-2 text-gray-900 dark:text-white">
                {renderValue(value)}
              </span>
                        </div>
                    ))}
                </div>
            </div>
        );
    }

    return <div className="text-gray-500 italic">No details available</div>;
};

export default ServiceDetailsRenderer;