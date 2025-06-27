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
import { Activity, ExternalLink, AlertCircle } from 'lucide-react';
import Link from 'next/link';

interface SysmonStatusIndicatorProps {
    pollerId: string;
    compact?: boolean;
}

interface SysmonStatus {
    hasData: boolean;
    lastUpdate?: Date;
    cpuUsage?: number;
    memoryUsage?: number;
    error?: string;
}

const SysmonStatusIndicator: React.FC<SysmonStatusIndicatorProps> = ({ 
    pollerId, 
    compact = false 
}) => {
    const { token } = useAuth();
    const [status, setStatus] = useState<SysmonStatus>({ hasData: false });
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        const checkSysmonStatus = async () => {
            setLoading(true);
            
            try {
                // Try to fetch recent CPU data to check if Sysmon is active
                const response = await fetch(`/api/pollers/${pollerId}/sysmon/cpu?hours=1`, {
                    headers: {
                        'Content-Type': 'application/json',
                        ...(token && { Authorization: `Bearer ${token}` })
                    },
                });

                if (response.ok) {
                    const data = await response.json();
                    
                    if (data && data.length > 0) {
                        const latestReading = data[data.length - 1];
                        const lastUpdate = new Date(latestReading.timestamp);
                        const now = new Date();
                        const diffMinutes = (now.getTime() - lastUpdate.getTime()) / (1000 * 60);
                        
                        // Consider data stale if older than 10 minutes
                        if (diffMinutes < 10) {
                            setStatus({
                                hasData: true,
                                lastUpdate,
                                cpuUsage: latestReading.value,
                            });
                        } else {
                            setStatus({
                                hasData: false,
                                error: 'Data is stale (>10min old)'
                            });
                        }
                    } else {
                        setStatus({
                            hasData: false,
                            error: 'No recent data'
                        });
                    }
                } else {
                    setStatus({
                        hasData: false,
                        error: 'API error'
                    });
                }
            } catch {
                setStatus({
                    hasData: false,
                    error: 'Connection failed'
                });
            } finally {
                setLoading(false);
            }
        };

        if (pollerId) {
            checkSysmonStatus();
        }
    }, [pollerId, token]);

    if (loading) {
        return compact ? (
            <div className="w-3 h-3 bg-gray-300 dark:bg-gray-600 rounded-full animate-pulse"></div>
        ) : (
            <div className="flex items-center space-x-2">
                <div className="w-3 h-3 bg-gray-300 dark:bg-gray-600 rounded-full animate-pulse"></div>
                <span className="text-xs text-gray-500 dark:text-gray-400">Checking...</span>
            </div>
        );
    }

    const getStatusColor = () => {
        if (status.hasData) return 'text-green-500';
        return 'text-gray-400 dark:text-gray-500';
    };

    const getStatusIcon = () => {
        if (status.hasData) return <Activity className={`h-3 w-3 ${getStatusColor()}`} />;
        return <AlertCircle className={`h-3 w-3 ${getStatusColor()}`} />;
    };

    const getTooltipText = () => {
        if (status.hasData) {
            return `Sysmon active - Last update: ${status.lastUpdate?.toLocaleTimeString()}`;
        }
        return `Sysmon inactive${status.error ? ` - ${status.error}` : ''}`;
    };

    if (compact) {
        return (
            <div title={getTooltipText()}>
                {status.hasData ? (
                    <Link href={`/metrics?pollerId=${pollerId}`} className="inline-block">
                        {getStatusIcon()}
                    </Link>
                ) : (
                    getStatusIcon()
                )}
            </div>
        );
    }

    return (
        <div className="flex items-center space-x-2">
            {getStatusIcon()}
            <div className="flex flex-col">
                <span className={`text-xs ${getStatusColor()}`}>
                    {status.hasData ? 'Sysmon Active' : 'No Sysmon Data'}
                </span>
                {status.hasData && status.lastUpdate && (
                    <span className="text-xs text-gray-500 dark:text-gray-400">
                        {status.lastUpdate.toLocaleTimeString()}
                    </span>
                )}
                {status.hasData && (
                    <Link 
                        href={`/metrics?pollerId=${pollerId}`}
                        className="text-xs text-blue-600 dark:text-blue-400 hover:text-blue-800 dark:hover:text-blue-200 flex items-center space-x-1 mt-1"
                    >
                        <span>View Metrics</span>
                        <ExternalLink className="h-3 w-3" />
                    </Link>
                )}
            </div>
        </div>
    );
};

export default SysmonStatusIndicator;