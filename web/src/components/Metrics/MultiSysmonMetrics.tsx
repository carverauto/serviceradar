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
import { Activity, Server } from 'lucide-react';
import { ErrorMessage, EmptyState, LoadingState } from './error-components';
import SystemMetrics from './system-metrics';

interface SysmonService {
    agent_id: string;
    poller_id: string;
    name: string;
    available: boolean;
    type: string;
    service_name: string;
    service_type: string;
}

interface MultiSysmonMetricsProps {
    pollerId: string;
    preselectedAgentId?: string | null;
}

const MultiSysmonMetrics: React.FC<MultiSysmonMetricsProps> = ({ pollerId, preselectedAgentId }) => {
    const { token } = useAuth();
    const [sysmonServices, setSysmonServices] = useState<SysmonService[]>([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);
    const [selectedService, setSelectedService] = useState<string | null>(null);

    useEffect(() => {
        const checkSysmonAvailability = async () => {
            setLoading(true);
            setError(null);

            try {
                // Instead of looking for sysmon in the services API, 
                // check if sysmon data is available by testing the sysmon endpoints
                const end = new Date();
                const start = new Date(end.getTime() - 60 * 60 * 1000); // Last hour
                const queryParams = `?start=${encodeURIComponent(start.toISOString())}&end=${encodeURIComponent(end.toISOString())}`;
                
                // Test if any sysmon data is available
                const [cpuResponse, memoryResponse] = await Promise.all([
                    fetch(`/api/pollers/${pollerId}/sysmon/cpu${queryParams}`, {
                        headers: {
                            'Content-Type': 'application/json',
                            ...(token && { Authorization: `Bearer ${token}` })
                        },
                    }).catch(() => null),
                    fetch(`/api/pollers/${pollerId}/sysmon/memory${queryParams}`, {
                        headers: {
                            'Content-Type': 'application/json',
                            ...(token && { Authorization: `Bearer ${token}` })
                        },
                    }).catch(() => null)
                ]);

                // Check if we got any sysmon data
                const hasCpuData = cpuResponse?.ok;
                const hasMemoryData = memoryResponse?.ok;
                
                if (hasCpuData || hasMemoryData) {
                    // Create a virtual sysmon service since the data is available
                    const virtualSysmonService: SysmonService = {
                        agent_id: preselectedAgentId || 'default-agent',
                        poller_id: pollerId,
                        name: 'sysmon',
                        available: true,
                        type: 'sysmon',
                        service_name: 'sysmon',
                        service_type: 'sysmon'
                    };
                    
                    setSysmonServices([virtualSysmonService]);
                    setSelectedService(virtualSysmonService.agent_id);
                } else {
                    // No sysmon data available
                    setSysmonServices([]);
                }
            } catch (err) {
                console.error('Error checking sysmon availability:', err);
                setError('Failed to check sysmon availability');
            } finally {
                setLoading(false);
            }
        };

        if (pollerId) {
            checkSysmonAvailability();
        }
    }, [pollerId, token, preselectedAgentId]);

    if (loading) {
        return <LoadingState message="Loading sysmon services..." />;
    }

    if (error) {
        return (
            <ErrorMessage
                title="Failed to load sysmon services"
                message={error}
                onRetry={() => window.location.reload()}
            />
        );
    }

    if (sysmonServices.length === 0) {
        return (
            <EmptyState
                message="No sysmon services found for this poller."
                onAction={() => window.location.reload()}
                actionLabel="Refresh"
            />
        );
    }

    // If only one sysmon service, show it directly
    if (sysmonServices.length === 1) {
        return <SystemMetrics pollerId={pollerId} />;
    }

    return (
        <div className="space-y-6">
            {/* Service selector */}
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4">
                <div className="flex items-center space-x-3 mb-4">
                    <Server className="h-5 w-5 text-gray-600 dark:text-gray-400" />
                    <h2 className="text-lg font-semibold text-gray-800 dark:text-gray-100">
                        Sysmon Instances for {pollerId}
                    </h2>
                </div>
                
                <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
                    {sysmonServices.map((service) => {
                        const serviceId = service.agent_id || service.service_name;
                        const isSelected = selectedService === serviceId;
                        
                        return (
                            <button
                                key={serviceId}
                                onClick={() => setSelectedService(serviceId)}
                                className={`p-3 rounded-lg border-2 text-left transition-colors ${
                                    isSelected
                                        ? 'border-blue-500 bg-blue-50 dark:bg-blue-900/20'
                                        : 'border-gray-200 dark:border-gray-700 hover:border-gray-300 dark:hover:border-gray-600'
                                }`}
                            >
                                <div className="flex items-center space-x-2">
                                    <Activity className={`h-4 w-4 ${
                                        service.available ? 'text-green-500' : 'text-gray-400'
                                    }`} />
                                    <span className="font-medium text-gray-800 dark:text-gray-200">
                                        {service.service_name || service.name}
                                    </span>
                                </div>
                                <div className="text-xs text-gray-500 dark:text-gray-400 mt-1">
                                    Agent: {service.agent_id}
                                </div>
                                <div className={`text-xs mt-1 ${
                                    service.available ? 'text-green-600' : 'text-red-600'
                                }`}>
                                    {service.available ? 'Active' : 'Inactive'}
                                </div>
                            </button>
                        );
                    })}
                </div>
                
                <div className="mt-4 text-sm text-gray-600 dark:text-gray-400">
                    Found {sysmonServices.length} sysmon instance{sysmonServices.length !== 1 ? 's' : ''} for this poller.
                </div>
            </div>

            {/* Selected service metrics */}
            {selectedService && (
                <SystemMetrics pollerId={pollerId} key={selectedService} />
            )}
        </div>
    );
};

export default MultiSysmonMetrics;