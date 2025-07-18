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
import { Router, ExternalLink, AlertCircle, ChartLine } from 'lucide-react';
import Link from 'next/link';

interface SNMPStatusIndicatorProps {
    deviceId?: string;
    pollerId?: string; // Keep for backward compatibility
    compact?: boolean;
    hasMetrics?: boolean; // Pre-fetched status from bulk API (preferred method)
    hasSnmpSource?: boolean; // Legacy: indicates device was discovered via SNMP (deprecated - use hasMetrics)
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

    const [status, setStatus] = useState<SNMPStatus>({ hasData: false });
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        // The component is loading if the primary source of truth, `hasMetrics`, is undefined.
        const isLoading = hasMetrics === undefined;
        setLoading(isLoading);

        if (!isLoading) {
            // Once loading is complete, set the status based on the definitive `hasMetrics` prop.
            // This prevents a premature decision based on the `hasSnmpSource` fallback.
            setStatus({ hasData: hasMetrics });
        } else {
            // While loading, ensure the status is reset to a neutral state to prevent showing a stale icon.
            setStatus({ hasData: false });
        }
    }, [hasMetrics]);


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
                    <ChartLine className="h-4 w-4 text-blue-500" />
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