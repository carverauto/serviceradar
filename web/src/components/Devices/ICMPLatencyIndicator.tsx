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
import { Timer, Wifi, WifiOff } from 'lucide-react';

interface ICMPLatencyIndicatorProps {
    deviceId: string;
    compact?: boolean;
    hasMetrics?: boolean;
}

interface ICMPLatencyStatus {
    hasData: boolean;
    latencyMs?: number;
    available?: boolean;
    lastUpdate?: Date;
    error?: string;
}

const ICMPLatencyIndicator: React.FC<ICMPLatencyIndicatorProps> = ({ 
    deviceId,
    compact = false,
    hasMetrics
}) => {
    const [status, setStatus] = useState<ICMPLatencyStatus>({ hasData: false });
    const [isLoading, setIsLoading] = useState(false);

    useEffect(() => {
        if (hasMetrics === undefined) {
            // Only fetch if hasMetrics not provided from bulk API
            fetchLatencyStatus();
        } else {
            setStatus({ hasData: hasMetrics });
        }
    }, [deviceId, hasMetrics]);

    const fetchLatencyStatus = async () => {
        if (!deviceId) return;
        
        console.log(`ICMPLatencyIndicator: Fetching latency for device ${deviceId}`);
        setIsLoading(true);
        try {
            const response = await fetch(`/api/devices/${encodeURIComponent(deviceId)}/icmp/latest`);
            console.log(`ICMPLatencyIndicator: Response status ${response.status} for device ${deviceId}`);
            if (response.ok) {
                const data = await response.json();
                console.log(`ICMPLatencyIndicator: Response data for ${deviceId}:`, data);
                if (data.metrics && data.metrics.length > 0) {
                    const latestMetric = data.metrics[0];
                    
                    // Parse metadata for additional info
                    let metadata: { available?: string | boolean; [key: string]: unknown } = {};
                    try {
                        metadata = typeof latestMetric.metadata === 'string' 
                            ? JSON.parse(latestMetric.metadata) 
                            : latestMetric.metadata || {};
                    } catch {
                        metadata = {};
                    }
                    
                    // Get response time from the value field (now stored as string in nanoseconds)
                    const responseTimeNs = parseInt(latestMetric.value) || 0;
                    const responseTimeMs = Math.round(responseTimeNs / 1000000);
                    
                    setStatus({
                        hasData: true,
                        latencyMs: responseTimeMs,
                        available: metadata?.available === 'true' || metadata?.available === true || responseTimeNs > 0,
                        lastUpdate: new Date(latestMetric.timestamp)
                    });
                    console.log(`ICMPLatencyIndicator: Set status with latency ${responseTimeMs}ms (${responseTimeNs}ns) for ${deviceId}`);
                } else {
                    console.log(`ICMPLatencyIndicator: No metrics found for device ${deviceId}`);
                    setStatus({ hasData: false });
                }
            } else {
                console.log(`ICMPLatencyIndicator: HTTP error ${response.status} for device ${deviceId}`);
                setStatus({ hasData: false, error: `HTTP ${response.status}` });
            }
        } catch (error) {
            console.log(`ICMPLatencyIndicator: Network error for device ${deviceId}:`, error);
            setStatus({ hasData: false, error: 'Network error' });
        } finally {
            setIsLoading(false);
        }
    };

    if (compact) {
        // Only show the indicator if we have ICMP metrics
        if (hasMetrics === false || (!isLoading && hasMetrics === undefined && !status.hasData)) {
            return null;
        }

        const getIcon = () => {
            if (isLoading || hasMetrics === undefined) {
                return <Timer className="h-4 w-4 text-gray-400 animate-pulse" />;
            }
            
            if (!status.hasData) {
                return null; // Don't show if no data
            }

            if (status.available === false) {
                return <WifiOff className="h-4 w-4 text-red-500" />;
            }

            if (status.latencyMs !== undefined) {
                // Color code based on latency: green < 50ms, yellow < 100ms, red >= 100ms
                const color = status.latencyMs < 50 ? 'text-green-500' :
                             status.latencyMs < 100 ? 'text-yellow-500' : 'text-red-500';
                return <Wifi className={`h-4 w-4 ${color}`} />;
            }

            return <Timer className="h-4 w-4 text-gray-500" />;
        };

        const getTooltip = () => {
            if (isLoading) return 'Loading ICMP latency...';
            if (!status.hasData) return 'No ICMP data available';
            if (status.available === false) return 'ICMP: Unreachable';
            if (status.latencyMs !== undefined) return `ICMP: ${status.latencyMs}ms`;
            return 'ICMP status unknown';
        };

        const icon = getIcon();
        if (!icon) return null;

        return (
            <div className="relative group">
                {icon}
                <div className="absolute bottom-full left-1/2 transform -translate-x-1/2 mb-1 px-2 py-1 text-xs text-white bg-gray-900 rounded-md opacity-0 group-hover:opacity-100 transition-opacity whitespace-nowrap z-10">
                    {getTooltip()}
                </div>
            </div>
        );
    }

    // Full size version (for potential future use)
    return (
        <div className="flex items-center gap-2 p-2 bg-gray-800 rounded-md">
            <Timer className="h-5 w-5 text-blue-400" />
            <div>
                <div className="text-sm font-medium text-white">ICMP Latency</div>
                {isLoading ? (
                    <div className="text-xs text-gray-400">Loading...</div>
                ) : status.hasData ? (
                    <div className="text-xs text-gray-400">
                        {status.latencyMs !== undefined ? `${status.latencyMs}ms` : 'Unknown'}
                        {status.available === false && ' (Unreachable)'}
                    </div>
                ) : (
                    <div className="text-xs text-gray-500">No data</div>
                )}
            </div>
        </div>
    );
};

export default ICMPLatencyIndicator;