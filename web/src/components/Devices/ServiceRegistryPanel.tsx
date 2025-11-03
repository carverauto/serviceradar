/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

'use client';

import React, { useState, useEffect } from 'react';
import { useAuth } from '@/components/AuthProvider';
import { Server, Box, Cpu, Shield, Clock, CheckCircle, AlertCircle, Loader } from 'lucide-react';
import Link from 'next/link';

interface ServiceRegistryInfo {
    device_id: string;
    device_type: 'poller' | 'agent' | 'checker';
    registration_source?: string;
    first_registered?: string;
    first_seen?: string;
    last_seen?: string;
    status?: string;
    spiffe_identity?: string;
    metadata?: Record<string, string>;
    parent_id?: string;
    component_id?: string;
    checker_kind?: string;
}

interface ServiceRegistryPanelProps {
    deviceId: string;
}

const ServiceRegistryPanel: React.FC<ServiceRegistryPanelProps> = ({ deviceId }) => {
    const { token } = useAuth();
    const [registryInfo, setRegistryInfo] = useState<ServiceRegistryInfo | null>(null);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);

    useEffect(() => {
        const fetchRegistryInfo = async () => {
            setLoading(true);
            setError(null);

            try {
                const response = await fetch(`/api/devices/${encodeURIComponent(deviceId)}/registry`, {
                    headers: {
                        'Content-Type': 'application/json',
                        ...(token && { Authorization: `Bearer ${token}` })
                    },
                });

                if (response.ok) {
                    const data = await response.json();
                    setRegistryInfo(data);
                } else if (response.status === 404) {
                    setError('This device is not a service component (poller/agent/checker)');
                } else {
                    setError('Failed to load registry information');
                }
            } catch (err) {
                setError('Connection error');
            } finally {
                setLoading(false);
            }
        };

        if (deviceId) {
            fetchRegistryInfo();
        }
    }, [deviceId, token]);

    if (loading) {
        return (
            <div className="bg-white dark:bg-gray-800 shadow rounded-lg p-6">
                <div className="flex items-center space-x-2 text-gray-500 dark:text-gray-400">
                    <Loader className="h-5 w-5 animate-spin" />
                    <span>Loading service registry information...</span>
                </div>
            </div>
        );
    }

    if (error || !registryInfo) {
        return null; // Don't show panel if device is not a service component
    }

    const getTypeIcon = () => {
        switch (registryInfo.device_type) {
            case 'poller':
                return <Server className="h-6 w-6 text-purple-500" />;
            case 'agent':
                return <Box className="h-6 w-6 text-blue-500" />;
            case 'checker':
                return <Cpu className="h-6 w-6 text-green-500" />;
        }
    };

    const getTypeLabel = () => {
        switch (registryInfo.device_type) {
            case 'poller':
                return 'ServiceRadar Poller';
            case 'agent':
                return 'ServiceRadar Agent';
            case 'checker':
                return 'ServiceRadar Checker';
        }
    };

    const getStatusColor = () => {
        switch (registryInfo.status?.toLowerCase()) {
            case 'active':
                return 'text-green-500';
            case 'pending':
                return 'text-yellow-500';
            case 'inactive':
                return 'text-gray-500';
            case 'revoked':
            case 'deleted':
                return 'text-red-500';
            default:
                return 'text-gray-400';
        }
    };

    const formatDate = (dateStr?: string) => {
        if (!dateStr) return 'N/A';
        const date = new Date(dateStr);
        return date.toLocaleString();
    };

    const formatRelativeTime = (dateStr?: string) => {
        if (!dateStr) return '';
        const date = new Date(dateStr);
        const now = new Date();
        const diffMs = now.getTime() - date.getTime();
        const diffMins = Math.floor(diffMs / 60000);

        if (diffMins < 1) return 'just now';
        if (diffMins < 60) return `${diffMins} minute${diffMins !== 1 ? 's' : ''} ago`;
        const diffHours = Math.floor(diffMins / 60);
        if (diffHours < 24) return `${diffHours} hour${diffHours !== 1 ? 's' : ''} ago`;
        const diffDays = Math.floor(diffHours / 24);
        return `${diffDays} day${diffDays !== 1 ? 's' : ''} ago`;
    };

    return (
        <div className="bg-white dark:bg-gray-800 shadow rounded-lg p-6">
            <div className="flex items-center space-x-3 mb-6">
                {getTypeIcon()}
                <h2 className="text-2xl font-bold text-gray-900 dark:text-white">
                    {getTypeLabel()}
                </h2>
            </div>

            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                {/* Status */}
                <div className="flex items-start space-x-3">
                    <CheckCircle className={`h-5 w-5 mt-0.5 ${getStatusColor()}`} />
                    <div>
                        <h3 className="text-sm font-medium text-gray-500 dark:text-gray-400">Status</h3>
                        <p className={`text-lg font-semibold ${getStatusColor()}`}>
                            {registryInfo.status || 'Unknown'}
                        </p>
                    </div>
                </div>

                {/* Registration Source */}
                {registryInfo.registration_source && (
                    <div className="flex items-start space-x-3">
                        <Shield className="h-5 w-5 mt-0.5 text-blue-500" />
                        <div>
                            <h3 className="text-sm font-medium text-gray-500 dark:text-gray-400">Registration Source</h3>
                            <p className="text-lg font-semibold text-gray-900 dark:text-white">
                                {registryInfo.registration_source}
                            </p>
                        </div>
                    </div>
                )}

                {/* First Registered */}
                {registryInfo.first_registered && (
                    <div className="flex items-start space-x-3">
                        <Clock className="h-5 w-5 mt-0.5 text-green-500" />
                        <div>
                            <h3 className="text-sm font-medium text-gray-500 dark:text-gray-400">First Registered</h3>
                            <p className="text-sm text-gray-900 dark:text-white">
                                {formatDate(registryInfo.first_registered)}
                            </p>
                            <p className="text-xs text-gray-500 dark:text-gray-400">
                                {formatRelativeTime(registryInfo.first_registered)}
                            </p>
                        </div>
                    </div>
                )}

                {/* Last Seen */}
                {registryInfo.last_seen && (
                    <div className="flex items-start space-x-3">
                        <Clock className="h-5 w-5 mt-0.5 text-orange-500" />
                        <div>
                            <h3 className="text-sm font-medium text-gray-500 dark:text-gray-400">Last Seen</h3>
                            <p className="text-sm text-gray-900 dark:text-white">
                                {formatDate(registryInfo.last_seen)}
                            </p>
                            <p className="text-xs text-gray-500 dark:text-gray-400">
                                {formatRelativeTime(registryInfo.last_seen)}
                            </p>
                        </div>
                    </div>
                )}

                {/* Component ID */}
                {registryInfo.component_id && (
                    <div className="col-span-1 md:col-span-2">
                        <h3 className="text-sm font-medium text-gray-500 dark:text-gray-400 mb-1">Component ID</h3>
                        <code className="text-xs bg-gray-100 dark:bg-gray-900 px-2 py-1 rounded">
                            {registryInfo.component_id}
                        </code>
                    </div>
                )}

                {/* Parent ID (for agents and checkers) */}
                {registryInfo.parent_id && (
                    <div className="col-span-1 md:col-span-2">
                        <h3 className="text-sm font-medium text-gray-500 dark:text-gray-400 mb-1">
                            {registryInfo.device_type === 'agent' ? 'Poller ID' : 'Agent ID'}
                        </h3>
                        <Link
                            href={`/service/device/${encodeURIComponent(registryInfo.parent_id)}`}
                            className="text-xs text-blue-600 dark:text-blue-400 hover:text-blue-800 dark:hover:text-blue-200 font-mono"
                        >
                            {registryInfo.parent_id}
                        </Link>
                    </div>
                )}

                {/* Checker Kind (for checkers only) */}
                {registryInfo.checker_kind && (
                    <div>
                        <h3 className="text-sm font-medium text-gray-500 dark:text-gray-400 mb-1">Checker Kind</h3>
                        <p className="text-sm text-gray-900 dark:text-white font-mono">
                            {registryInfo.checker_kind}
                        </p>
                    </div>
                )}

                {/* SPIFFE Identity */}
                {registryInfo.spiffe_identity && (
                    <div className="col-span-1 md:col-span-2">
                        <h3 className="text-sm font-medium text-gray-500 dark:text-gray-400 mb-1">SPIFFE Identity</h3>
                        <code className="text-xs bg-gray-100 dark:bg-gray-900 px-2 py-1 rounded break-all">
                            {registryInfo.spiffe_identity}
                        </code>
                    </div>
                )}

                {/* Metadata */}
                {registryInfo.metadata && Object.keys(registryInfo.metadata).length > 0 && (
                    <div className="col-span-1 md:col-span-2">
                        <h3 className="text-sm font-medium text-gray-500 dark:text-gray-400 mb-2">Metadata</h3>
                        <div className="bg-gray-50 dark:bg-gray-900 rounded p-3">
                            {Object.entries(registryInfo.metadata).map(([key, value]) => (
                                <div key={key} className="flex justify-between py-1 text-xs">
                                    <span className="text-gray-600 dark:text-gray-400 font-medium">{key}:</span>
                                    <span className="text-gray-900 dark:text-white font-mono">{value}</span>
                                </div>
                            ))}
                        </div>
                    </div>
                )}
            </div>
        </div>
    );
};

export default ServiceRegistryPanel;
