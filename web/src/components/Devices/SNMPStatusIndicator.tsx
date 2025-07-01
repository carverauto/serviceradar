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
import { Router, ExternalLink, AlertCircle, Network } from 'lucide-react';
import Link from 'next/link';

interface SNMPStatusIndicatorProps {
    deviceId?: string;
    pollerId?: string; // Keep for backward compatibility
    compact?: boolean;
    hasMetrics?: boolean; // Pre-fetched status from bulk API
}

interface SNMPStatus {
    hasData: boolean;
    lastUpdate?: Date;
    targetCount?: number;
    error?: string;
}

const SNMPStatusIndicator: React.FC<SNMPStatusIndicatorProps> = ({ 
    deviceId,
    pollerId, 
    compact = false,
    hasMetrics
}) => {
    // Use deviceId if available, otherwise fall back to pollerId for backward compatibility
    const targetId = deviceId || pollerId;
    const idType = deviceId ? 'device' : 'poller';
    
    const { token } = useAuth();
    const [status, setStatus] = useState<SNMPStatus>({ hasData: false });
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        // If hasMetrics is provided, use that instead of making API call
        if (hasMetrics !== undefined) {
            setStatus({ hasData: hasMetrics });
            setLoading(false);
            return;
        }

        // Don't make individual API calls if we're in a context where bulk status should be available
        // This prevents the N+1 query problem on the devices page
        if (deviceId && hasMetrics === undefined) {
            // When hasMetrics is undefined but we have a deviceId, it likely means
            // the bulk status is still loading. Keep loading state.
            setLoading(true);
            return;
        }

        // If hasMetrics is explicitly false, don't make API call
        if (deviceId && hasMetrics === false) {
            setStatus({ hasData: false });
            setLoading(false);
            return;
        }

        const checkSNMPStatus = async () => {
            setLoading(true);
            
            try {
                // Only allow individual API calls for pollers (backward compatibility) 
                // or when explicitly needed (not in bulk context)
                if (idType === 'poller') {
                    // Try to fetch recent SNMP data to check if SNMP monitoring is active
                    const response = await fetch(`/api/pollers/${targetId}/snmp?hours=1`, {
                        headers: {
                            'Content-Type': 'application/json',
                            ...(token && { Authorization: `Bearer ${token}` })
                        },
                    });

                    if (response.ok) {
                        const data = await response.json();
                        
                        if (data && data.length > 0) {
                            const latestReading = data[0]; // API returns data sorted by timestamp DESC, so first item is newest
                            const lastUpdate = new Date(latestReading.timestamp);
                            const now = new Date();
                            const diffMinutes = (now.getTime() - lastUpdate.getTime()) / (1000 * 60);
                            
                            // Consider data stale if older than 10 minutes
                            if (diffMinutes < 10) {
                                setStatus({
                                    hasData: true,
                                    lastUpdate,
                                    targetCount: Object.keys(latestReading.targets || {}).length,
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
                } else {
                    // For devices, we should not make individual API calls
                    // This prevents the N+1 query problem
                    setStatus({
                        hasData: false,
                        error: 'Use bulk status endpoint'
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

        if (targetId) {
            checkSNMPStatus();
        }
    }, [targetId, idType, token, hasMetrics, deviceId]);

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
        if (status.hasData) return 'text-blue-500';
        return 'text-gray-400 dark:text-gray-500';
    };

    const getStatusIcon = () => {
        if (status.hasData) return <Router className={`h-3 w-3 ${getStatusColor()}`} />;
        return <AlertCircle className={`h-3 w-3 ${getStatusColor()}`} />;
    };

    const getTooltipText = () => {
        if (status.hasData) {
            return `View SNMP network metrics - Last update: ${status.lastUpdate?.toLocaleTimeString()}`;
        }
        return `No SNMP network metrics available${status.error ? ` - ${status.error}` : ''}`;
    };

    if (compact) {
        // Only render in compact mode if there's actual SNMP data
        if (!status.hasData) {
            return null;
        }
        
        return (
            <div title={getTooltipText()} className="flex items-center justify-center">
                <Link 
                    href={idType === 'device' ? `/service/device/${encodeURIComponent(targetId!)}/snmp` : `/network?pollerId=${targetId}`} 
                    className="inline-flex items-center justify-center p-1 rounded hover:bg-gray-700/50 transition-colors"
                >
                    <Network className="h-4 w-4 text-blue-500" />
                </Link>
            </div>
        );
    }

    return (
        <div className="flex items-center space-x-2">
            {getStatusIcon()}
            <div className="flex flex-col">
                <span className={`text-xs ${getStatusColor()}`}>
                    {status.hasData ? 'SNMP Active' : 'No SNMP Data'}
                </span>
                {status.hasData && status.lastUpdate && (
                    <span className="text-xs text-gray-500 dark:text-gray-400">
                        {status.lastUpdate.toLocaleTimeString()}
                    </span>
                )}
                {status.hasData && (
                    <Link 
                        href={idType === 'device' ? `/service/device/${encodeURIComponent(targetId!)}/snmp` : `/network?pollerId=${targetId}`}
                        className="text-xs text-blue-600 dark:text-blue-400 hover:text-blue-800 dark:hover:text-blue-200 flex items-center space-x-1 mt-1"
                    >
                        <span>View Network</span>
                        <ExternalLink className="h-3 w-3" />
                    </Link>
                )}
            </div>
        </div>
    );
};

export default SNMPStatusIndicator;