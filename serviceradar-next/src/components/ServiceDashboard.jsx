'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import {
    LineChart,
    Line,
    XAxis,
    YAxis,
    CartesianGrid,
    Tooltip,
    Legend,
    ResponsiveContainer,
} from 'recharts';
import NetworkSweepView from './NetworkSweepView';
import { PingStatus } from './NetworkStatus';
import SNMPDashboard from './SNMPDashboard';
import { fetchWithCache } from '../lib/api';

const ServiceDashboard = ({
                              nodeId,
                              serviceName,
                              initialService = null,
                              initialMetrics = [],
                              initialSnmpData = [],
                              initialError = null,
                          }) => {
    const router = useRouter();
    const [serviceData, setServiceData] = useState(initialService);
    const [metricsData, setMetricsData] = useState(initialMetrics);
    const [snmpData, setSnmpData] = useState(initialSnmpData);
    const [loading, setLoading] = useState(!initialService && !initialError);
    const [error, setError] = useState(initialError);
    const [selectedTimeRange, setSelectedTimeRange] = useState('1h');

    const refreshInterval = 30000;

    const fetchData = useCallback(async () => {
        try {
            if (initialService && initialMetrics.length > 0 && initialSnmpData.length > 0 && !initialError) {
                setServiceData(initialService);
                setMetricsData(initialMetrics);
                setSnmpData(initialSnmpData);
                setLoading(false);
                return;
            }

            setLoading(true);

            console.log("Fetching nodes...");
            const nodes = await fetchWithCache('/api/nodes');
            console.log("Nodes fetched:", nodes.length);

            const node = nodes.find((n) => n.node_id === nodeId);
            if (!node) throw new Error('Node not found');

            const service = node.services?.find((s) => s.name === serviceName);
            if (!service) throw new Error('Service not found');

            setServiceData(service);

            console.log("Fetching metrics...");
            const metrics = await fetchWithCache(`/api/nodes/${nodeId}/metrics`);
            const serviceMetrics = metrics.filter((m) => m.service_name === serviceName);
            console.log("Metrics fetched:", serviceMetrics.length);
            setMetricsData(serviceMetrics);

            if (service.type === 'snmp') {
                console.log("Fetching SNMP data...");
                const end = new Date();
                const start = new Date();
                start.setHours(end.getHours() - 1);
                const snmpResponse = await fetchWithCache(
                    `/api/nodes/${nodeId}/snmp?start=${start.toISOString()}&end=${end.toISOString()}`
                );
                console.log("SNMP data fetched:", snmpResponse.length);
                setSnmpData(snmpResponse);
            }

            setLoading(false);
            setError(null);
        } catch (err) {
            console.error('Error fetching data:', err);
            setError(err.message);
            setLoading(false);
        }
    }, [nodeId, serviceName, initialService, initialMetrics, initialSnmpData, initialError]);

    useEffect(() => {
        console.log("ServiceDashboard mounted", { nodeId, serviceName, snmpDataLength: initialSnmpData.length });
        return () => console.log("ServiceDashboard unmounted");
    }, [nodeId, serviceName, initialSnmpData]);

    const filterDataByTimeRange = (data, range) => {
        const now = Date.now();
        const ranges = {
            '1h': 60 * 60 * 1000,
            '6h': 6 * 60 * 60 * 1000,
            '24h': 24 * 60 * 60 * 1000,
        };
        const timeLimit = now - ranges[range];
        return data.filter((point) => new Date(point.timestamp).getTime() >= timeLimit);
    };

    const renderMetricsChart = () => {
        if (!metricsData.length) return null;

        const chartData = filterDataByTimeRange(
            metricsData.map((metric) => ({
                timestamp: new Date(metric.timestamp).getTime(),
                response_time: metric.response_time / 1000000,
            })),
            selectedTimeRange
        );

        if (chartData.length === 0) {
            return (
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
                    <div className="flex justify-between items-center mb-4">
                        <h3 className="text-lg font-semibold text-gray-800 dark:text-gray-100">Response Time</h3>
                        <div className="flex gap-2">
                            {['1h', '6h', '24h'].map((range) => (
                                <button
                                    key={range}
                                    onClick={() => setSelectedTimeRange(range)}
                                    className={`px-3 py-1 rounded transition-colors ${
                                        selectedTimeRange === range
                                            ? 'bg-blue-500 text-white'
                                            : 'bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-100'
                                    }`}
                                >
                                    {range}
                                </button>
                            ))}
                        </div>
                    </div>
                    <div className="h-64 flex items-center justify-center text-gray-500 dark:text-gray-400">
                        No data available for the selected time range
                    </div>
                </div>
            );
        }

        return (
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
                <div className="flex justify-between items-center mb-4">
                    <h3 className="text-lg font-semibold text-gray-800 dark:text-gray-100">Response Time</h3>
                    <div className="flex gap-2">
                        {['1h', '6h', '24h'].map((range) => (
                            <button
                                key={range}
                                onClick={() => setSelectedTimeRange(range)}
                                className={`px-3 py-1 rounded transition-colors ${
                                    selectedTimeRange === range
                                        ? 'bg-blue-500 text-white'
                                        : 'bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-100'
                                }`}
                            >
                                {range}
                            </button>
                        ))}
                    </div>
                </div>
                <div className="h-64">
                    <ResponsiveContainer width="100%" height="100%">
                        <LineChart data={chartData}>
                            <CartesianGrid strokeDasharray="3 3" />
                            <XAxis
                                dataKey="timestamp"
                                type="number"
                                domain={['auto', 'auto']}
                                tickFormatter={(ts) => new Date(ts).toLocaleTimeString()}
                            />
                            <YAxis unit="ms" domain={['auto', 'auto']} />
                            <Tooltip
                                labelFormatter={(ts) => new Date(ts).toLocaleString()}
                                formatter={(value) => [`${value.toFixed(2)} ms`, 'Response Time']}
                            />
                            <Legend />
                            <Line
                                type="monotone"
                                dataKey="response_time"
                                stroke="#8884d8"
                                dot={false}
                                name="Response Time"
                            />
                        </LineChart>
                    </ResponsiveContainer>
                </div>
            </div>
        );
    };

    const renderServiceContent = () => {
        if (!serviceData) return null;

        if (serviceData.type === 'snmp') {
            return (
                <SNMPDashboard
                    nodeId={nodeId}
                    serviceName={serviceName}
                    initialData={snmpData}
                />
            );
        }

        if (serviceData.type === 'sweep') {
            return <NetworkSweepView nodeId={nodeId} service={serviceData} standalone />;
        }

        if (serviceData.type === 'icmp') {
            return (
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
                    <h3 className="text-lg font-semibold mb-4 text-gray-800 dark:text-gray-100">ICMP Status</h3>
                    <PingStatus details={serviceData.message} />
                </div>
            );
        }

        let details;
        try {
            details = typeof serviceData.details === 'string'
                ? JSON.parse(serviceData.details)
                : serviceData.details;
        } catch (e) {
            console.error('Error parsing service details:', e);
            return null;
        }

        if (!details) return null;

        return (
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                {Object.entries(details)
                    .filter(([key]) => key !== 'history')
                    .map(([key, value]) => (
                        <div
                            key={key}
                            className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors"
                        >
                            <h3 className="text-lg font-semibold mb-2 text-gray-800 dark:text-gray-100">
                                {key.split('_').map((word) => word.charAt(0).toUpperCase() + word.slice(1)).join(' ')}
                            </h3>
                            <div className="text-lg break-all text-gray-700 dark:text-gray-100">
                                {typeof value === 'boolean' ? (value ? 'Yes' : 'No') : value}
                            </div>
                        </div>
                    ))}
            </div>
        );
    };

    if (loading) {
        return (
            <div className="space-y-4">
                <div className="flex justify-between items-center">
                    <div className="h-8 bg-gray-200 dark:bg-gray-700 rounded w-64 animate-pulse"></div>
                    <div className="h-8 bg-gray-200 dark:bg-gray-700 rounded w-32 animate-pulse"></div>
                </div>
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6">
                    <div className="h-6 bg-gray-200 dark:bg-gray-700 rounded w-40 mb-4 animate-pulse"></div>
                    <div className="flex justify-between">
                        <div className="h-8 bg-gray-200 dark:bg-gray-700 rounded w-24 animate-pulse"></div>
                    </div>
                </div>
                <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6">
                    <div className="h-6 bg-gray-200 dark:bg-gray-700 rounded w-40 mb-4 animate-pulse"></div>
                    <div className="h-64 bg-gray-100 dark:bg-gray-700 rounded animate-pulse"></div>
                </div>
            </div>
        );
    }

    if (error) {
        return (
            <div className="bg-red-50 dark:bg-red-900 p-6 rounded-lg shadow text-red-600 dark:text-red-200">
                <h2 className="text-xl font-bold mb-4">Error Loading Service</h2>
                <p>{error}</p>
                <button
                    onClick={() => router.push('/nodes')}
                    className="mt-4 px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-800 dark:text-gray-100 hover:bg-gray-300 dark:hover:bg-gray-600 rounded transition-colors"
                >
                    Back to Nodes
                </button>
            </div>
        );
    }

    console.log("ServiceDashboard rendered", { snmpDataLength: snmpData.length });

    return (
        <div className="space-y-6 transition-colors">
            <div className="flex justify-between items-center">
                <h2 className="text-2xl font-bold text-gray-800 dark:text-gray-100">
                    {serviceName} Service Status
                </h2>
                <button
                    onClick={() => router.push('/nodes')}
                    className="px-4 py-2 bg-gray-100 dark:bg-gray-700 dark:text-gray-100 hover:bg-gray-200 dark:hover:bg-gray-600 rounded transition-colors"
                >
                    Back to Nodes
                </button>
            </div>
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
                <div className="flex items-center justify-between">
                    <h3 className="text-lg font-semibold text-gray-800 dark:text-gray-100">Service Status</h3>
                    <div
                        className={`px-3 py-1 rounded transition-colors ${
                            serviceData?.available
                                ? 'bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-100'
                                : 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-100'
                        }`}
                    >
                        {serviceData?.available ? 'Online' : 'Offline'}
                    </div>
                </div>
            </div>
            {renderMetricsChart()}
            {renderServiceContent()}
        </div>
    );
};

export default React.memo(ServiceDashboard);