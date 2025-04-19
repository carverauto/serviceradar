// src/components/PollerDetail.tsx
'use client';

import React from 'react';
import Link from 'next/link';
import { Poller, ServiceMetric, Service } from '@/types/types';

interface PollerHistoryEntry {
    timestamp: string;
    is_healthy: boolean;
}

interface PollerDetailProps {
    poller?: Poller;
    metrics: ServiceMetric[];
    history: PollerHistoryEntry[];
    error?: string;
}

const PollerDetail: React.FC<PollerDetailProps> = ({ poller, metrics, history, error }) => {
    if (error) {
        return (
            <div className="p-4 text-red-500">
                <div className="flex items-center">
                    <span className="mr-2">⚠</span>
                    {error}
                </div>
            </div>
        );
    }

    if (!poller) {
        return <div className="p-4 text-gray-400">No poller data available</div>;
    }

    const pollerId = poller.poller_id;
    const services = poller.services || []; // Default to empty array if undefined

    // Group services by category
    const groupedServices = services.reduce((acc: { [key: string]: Service[] }, service: Service) => {
        const group = service.group || 'Other';
        if (!acc[group]) acc[group] = [];
        acc[group].push(service);
        return acc;
    }, {});

    // Calculate overall service status
    const totalServices = services.length;
    const healthyServices = services.filter(s => s.status === 'healthy').length;

    // Get the latest response time from metrics
    const latestMetric = metrics.length > 0 ? metrics[metrics.length - 1] : null;
    const responseTime = latestMetric?.response_time_ms ?? latestMetric?.response_time ?? 0;

    // Get the latest timestamp from history
    const lastUpdated = history.length > 0 ? new Date(history[history.length - 1].timestamp) : new Date();

    return (
        <div className="p-4 space-y-6">
            {/* Poller Overview */}
            <div className="bg-gray-900 rounded-lg shadow p-4">
                <div className="flex justify-between items-center">
                    <div className="flex items-center">
                        <span className="text-green-500 mr-2">✔</span>
                        <h2 className="text-lg font-semibold text-white">{pollerId}</h2>
                    </div>
                    <div className="text-sm text-gray-400">
                        {healthyServices} / {totalServices} Services Healthy
                    </div>
                </div>
                <div className="mt-4 grid grid-cols-1 md:grid-cols-3 gap-4">
                    <div>
                        <h3 className="text-sm font-medium text-gray-300">Response Time Trend</h3>
                        <p className="text-lg font-bold text-white">{responseTime.toFixed(1)}ms</p>
                        {/* Optionally, add a small chart here using history data */}
                    </div>
                    <div>
                        <h3 className="text-sm font-medium text-gray-300">Services Status</h3>
                        <div className="flex space-x-2">
                            <span className="text-green-500">{healthyServices}</span>
                            <span className="text-yellow-500">{services.filter(s => s.status === 'warning').length}</span>
                            <span className="text-red-500">{services.filter(s => s.status === 'critical').length}</span>
                        </div>
                    </div>
                    <div>
                        <h3 className="text-sm font-medium text-gray-300">Last Updated</h3>
                        <p>{lastUpdated.toLocaleString()}</p>
                    </div>
                </div>
            </div>

            {/* Service Groups */}
            <div>
                <h2 className="text-lg font-semibold text-white mb-4">Service Groups</h2>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    {Object.entries(groupedServices).map(([group, groupServices]) => (
                        <div key={group} className="bg-gray-900 rounded-lg shadow p-4">
                            <div className="flex justify-between items-center mb-4">
                                <h3 className="text-md font-medium text-white">{group}</h3>
                                <div className="text-sm text-gray-400">
                                    {groupServices.filter(s => s.status === 'healthy').length} / {groupServices.length} healthy
                                </div>
                            </div>
                            <div className="grid grid-cols-2 gap-2">
                                {groupServices.map(service => (
                                    <div key={service.name} className="bg-gray-800 rounded-lg p-2 flex justify-between items-center">
                                        {service.name === 'sysmon' ? (
                                            <Link href={`/metrics?pollerId=${pollerId}`}>
                                                <span className="text-gray-300 hover:text-white">{service.name}</span>
                                            </Link>
                                        ) : (
                                            <Link href={`/pollers/${pollerId}/services/${service.name}`}>
                                                <span className="text-gray-300 hover:text-white">{service.name}</span>
                                            </Link>
                                        )}
                                        <span
                                            className={
                                                service.status === 'healthy'
                                                    ? 'text-green-500'
                                                    : service.status === 'warning'
                                                        ? 'text-yellow-500'
                                                        : 'text-red-500'
                                            }
                                        >
                      {service.status === 'healthy' ? '✔' : service.status === 'warning' ? '⚠' : '✖'}
                    </span>
                                    </div>
                                ))}
                            </div>
                        </div>
                    ))}
                </div>
            </div>

            <div className="flex justify-end">
                <Link href={`/metrics?pollerId=${pollerId}`}>
                    <button className="bg-blue-600 text-white px-4 py-2 rounded-lg hover:bg-blue-700">
                        View Detailed Dashboard
                    </button>
                </Link>
            </div>
        </div>
    );
};

export default PollerDetail;