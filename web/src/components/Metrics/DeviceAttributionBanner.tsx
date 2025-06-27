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
import { Device } from '@/types/devices';
import { Server, MapPin, Clock, ExternalLink } from 'lucide-react';
import Link from 'next/link';

interface DeviceAttributionBannerProps {
    pollerId: string;
}

interface SysmonAgent {
    hostId?: string;
    agentId: string;
    lastSeen?: Date;
    cpuCount?: number;
    memoryTotal?: number;
}

const DeviceAttributionBanner: React.FC<DeviceAttributionBannerProps> = ({ pollerId }) => {
    const { token } = useAuth();
    const [agent, setAgent] = useState<SysmonAgent | null>(null);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);

    useEffect(() => {
        const fetchSysmonAgentInfo = async () => {
            setLoading(true);
            setError(null);
            
            try {
                // Get recent CPU metrics to extract agent and host identification
                const cpuResponse = await fetch(`/api/pollers/${pollerId}/sysmon/cpu?hours=1`, {
                    headers: {
                        'Content-Type': 'application/json',
                        ...(token && { Authorization: `Bearer ${token}` })
                    },
                });

                if (!cpuResponse.ok) {
                    throw new Error('Failed to fetch sysmon CPU data');
                }

                const cpuData = await cpuResponse.json();
                
                // Extract agent info from the first CPU metric (they all should have the same agent_id)
                if (cpuData && cpuData.length > 0 && cpuData[0].cpus && cpuData[0].cpus.length > 0) {
                    const firstMetric = cpuData[0].cpus[0];
                    
                    if (firstMetric.agent_id) {
                        // Get memory data to show additional info
                        const memoryResponse = await fetch(`/api/pollers/${pollerId}/sysmon/memory?hours=1`, {
                            headers: {
                                'Content-Type': 'application/json',
                                ...(token && { Authorization: `Bearer ${token}` })
                            },
                        });
                        
                        let memoryTotal = undefined;
                        if (memoryResponse.ok) {
                            const memoryData = await memoryResponse.json();
                            if (memoryData && memoryData.length > 0) {
                                memoryTotal = memoryData[0].memory.total_bytes;
                            }
                        }
                        
                        setAgent({
                            agentId: firstMetric.agent_id,
                            hostId: firstMetric.host_id,
                            lastSeen: new Date(firstMetric.timestamp),
                            cpuCount: cpuData[0].cpus.length,
                            memoryTotal: memoryTotal
                        });
                    } else {
                        throw new Error('No agent_id found in sysmon metrics - backend may not be updated');
                    }
                } else {
                    throw new Error('No sysmon metrics found for this poller');
                }
            } catch (err) {
                setError(err instanceof Error ? err.message : 'Unknown error');
            } finally {
                setLoading(false);
            }
        };

        if (pollerId) {
            fetchSysmonAgentInfo();
        }
    }, [pollerId, token]);

    const formatLastSeen = (dateString: string) => {
        try {
            const date = new Date(dateString);
            const now = new Date();
            const diffMs = now.getTime() - date.getTime();
            const diffMins = Math.floor(diffMs / (1000 * 60));
            const diffHours = Math.floor(diffMins / 60);
            const diffDays = Math.floor(diffHours / 24);

            if (diffMins < 1) return 'Just now';
            if (diffMins < 60) return `${diffMins}m ago`;
            if (diffHours < 24) return `${diffHours}h ago`;
            return `${diffDays}d ago`;
        } catch {
            return 'Unknown';
        }
    };

    if (loading) {
        return (
            <div className="bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg p-4 mb-6">
                <div className="flex items-center space-x-3">
                    <Server className="h-5 w-5 text-blue-600 dark:text-blue-400" />
                    <div className="h-4 w-48 bg-blue-200 dark:bg-blue-700 rounded animate-pulse"></div>
                </div>
            </div>
        );
    }

    if (error || !agent) {
        return (
            <div className="bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg p-4 mb-6">
                <div className="flex items-center space-x-3">
                    <Server className="h-5 w-5 text-yellow-600 dark:text-yellow-400" />
                    <div>
                        <p className="text-sm font-medium text-yellow-800 dark:text-yellow-200">
                            Sysmon Metrics (No recent data)
                        </p>
                        <p className="text-xs text-yellow-600 dark:text-yellow-400">
                            {error || 'No recent sysmon metrics found for this poller'}
                        </p>
                        <p className="text-xs text-yellow-600 dark:text-yellow-400">
                            Poller: {pollerId}
                        </p>
                    </div>
                </div>
            </div>
        );
    }

    const formatMemorySize = (bytes: number) => {
        const gb = bytes / (1024 * 1024 * 1024);
        return `${gb.toFixed(1)} GB`;
    };

    // Show agent-specific information
    return (
        <div className="bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded-lg p-4 mb-6">
            <div className="flex items-center justify-between">
                <div className="flex items-center space-x-3">
                    <Server className="h-5 w-5 text-green-600 dark:text-green-400" />
                    <div>
                        <p className="text-sm font-medium text-green-800 dark:text-green-200">
                            System Metrics from Agent: {agent.agentId}
                        </p>
                        <div className="flex items-center space-x-4 text-xs text-green-600 dark:text-green-400 mt-1">
                            {agent.hostId && (
                                <span className="flex items-center space-x-1">
                                    <MapPin className="h-3 w-3" />
                                    <span>Host: {agent.hostId}</span>
                                </span>
                            )}
                            <span className="flex items-center space-x-1">
                                <Clock className="h-3 w-3" />
                                <span>Last data: {agent.lastSeen ? formatLastSeen(agent.lastSeen.toISOString()) : 'Unknown'}</span>
                            </span>
                            {agent.cpuCount && (
                                <span>{agent.cpuCount} CPU cores</span>
                            )}
                            {agent.memoryTotal && (
                                <span>{formatMemorySize(agent.memoryTotal)} RAM</span>
                            )}
                        </div>
                    </div>
                </div>
                <Link 
                    href={`/devices?search=${agent.agentId}`}
                    className="flex items-center space-x-1 text-green-600 dark:text-green-400 hover:text-green-800 dark:hover:text-green-200 text-sm"
                >
                    <span>View Agent</span>
                    <ExternalLink className="h-4 w-4" />
                </Link>
            </div>
        </div>
    );
};

export default DeviceAttributionBanner;