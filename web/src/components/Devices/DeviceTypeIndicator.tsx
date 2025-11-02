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

import React from 'react';
import { Server, Box, Cpu, ExternalLink } from 'lucide-react';
import Link from 'next/link';

export type DeviceType = 'poller' | 'agent' | 'checker' | 'integration' | 'discovered' | 'unknown';

interface DeviceTypeIndicatorProps {
    deviceId: string;
    deviceType?: DeviceType;
    compact?: boolean;
    discoverySource?: string; // For determining integration vs discovered devices
}

const DeviceTypeIndicator: React.FC<DeviceTypeIndicatorProps> = ({
    deviceId,
    deviceType,
    compact = false,
    discoverySource
}) => {
    // Determine device type from device_id prefix if not provided
    const getDeviceType = (): DeviceType => {
        if (deviceType) return deviceType;

        if (deviceId.startsWith('serviceradar:poller:')) return 'poller';
        if (deviceId.startsWith('serviceradar:agent:')) return 'agent';
        if (deviceId.startsWith('serviceradar:checker:')) return 'checker';

        // Check discovery source for integration vs discovered
        if (discoverySource) {
            if (discoverySource.includes('armis') ||
                discoverySource.includes('netbox') ||
                discoverySource.includes('unifi')) {
                return 'integration';
            }
            if (discoverySource.includes('sweep') ||
                discoverySource.includes('mapper')) {
                return 'discovered';
            }
        }

        return 'unknown';
    };

    const type = getDeviceType();

    // Don't show indicator for non-service components in compact mode
    if (compact && !['poller', 'agent', 'checker'].includes(type)) {
        return null;
    }

    const getIcon = () => {
        switch (type) {
            case 'poller':
                return <Server className="h-4 w-4 text-purple-500" />;
            case 'agent':
                return <Box className="h-4 w-4 text-blue-500" />;
            case 'checker':
                return <Cpu className="h-4 w-4 text-green-500" />;
            default:
                return null;
        }
    };

    const getLabel = () => {
        switch (type) {
            case 'poller':
                return 'Poller';
            case 'agent':
                return 'Agent';
            case 'checker':
                return 'Checker';
            case 'integration':
                return 'Integration';
            case 'discovered':
                return 'Discovered';
            default:
                return 'Device';
        }
    };

    const getTooltipText = () => {
        switch (type) {
            case 'poller':
                return 'ServiceRadar Poller - Click to view registration details';
            case 'agent':
                return 'ServiceRadar Agent - Click to view registration details';
            case 'checker':
                return 'ServiceRadar Checker - Click to view registration details';
            case 'integration':
                return `Device from ${discoverySource || 'integration'}`;
            case 'discovered':
                return `Device discovered via ${discoverySource || 'network scan'}`;
            default:
                return 'Device';
        }
    };

    const getColor = () => {
        switch (type) {
            case 'poller':
                return 'text-purple-500';
            case 'agent':
                return 'text-blue-500';
            case 'checker':
                return 'text-green-500';
            case 'integration':
                return 'text-orange-500';
            case 'discovered':
                return 'text-gray-500';
            default:
                return 'text-gray-400';
        }
    };

    if (compact) {
        // Only show for service components (poller, agent, checker)
        if (!['poller', 'agent', 'checker'].includes(type)) {
            return null;
        }

        return (
            <div title={getTooltipText()} className="flex items-center justify-center">
                <Link
                    href={`/service/device/${encodeURIComponent(deviceId)}/registry`}
                    className="inline-flex items-center justify-center p-1 rounded hover:bg-gray-700/50 transition-colors"
                >
                    {getIcon()}
                </Link>
            </div>
        );
    }

    // Full display mode
    return (
        <div className="flex items-center space-x-2">
            {getIcon()}
            <div className="flex flex-col">
                <span className={`text-xs font-medium ${getColor()}`}>
                    {getLabel()}
                </span>
                {['poller', 'agent', 'checker'].includes(type) && (
                    <Link
                        href={`/service/device/${encodeURIComponent(deviceId)}/registry`}
                        className="text-xs text-blue-600 dark:text-blue-400 hover:text-blue-800 dark:hover:text-blue-200 flex items-center space-x-1 mt-1"
                    >
                        <span>View Registry</span>
                        <ExternalLink className="h-3 w-3" />
                    </Link>
                )}
            </div>
        </div>
    );
};

export default DeviceTypeIndicator;
