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

// web/src/components/NetworkDiscoveryDetails.tsx
import React from 'react';
import { RawBackendLanDiscoveryData } from '@/types/lan_discovery';
import InterfaceTable from './InterfaceTable';

interface NetworkDiscoveryDetailsProps {
    details: string | RawBackendLanDiscoveryData | null | undefined;
}

const NetworkDiscoveryDetails: React.FC<NetworkDiscoveryDetailsProps> = ({ details }) => {
    let parsedDetails: RawBackendLanDiscoveryData | undefined;

    try {
        if (details === null || details === undefined) {
            parsedDetails = undefined;
        } else if (typeof details === 'string') {
            parsedDetails = JSON.parse(details);
        } else {
            parsedDetails = details;
        }
    } catch (error) {
        console.error('Error parsing network discovery details:', error);
        parsedDetails = undefined;
    }

    if (!parsedDetails) {
        return <div className="text-gray-500 italic">No network discovery details available or failed to parse.</div>;
    }

    // Ensure devices and interfaces are arrays. Gracefully handle cases where they might be a single object
    const safeDevices = Array.isArray(parsedDetails.devices) ? parsedDetails.devices : (parsedDetails.devices ? [parsedDetails.devices] : []);
    const safeInterfaces = Array.isArray(parsedDetails.interfaces) ? parsedDetails.interfaces : (parsedDetails.interfaces ? [parsedDetails.interfaces] : []);

    return (
        <div className="space-y-4">
            <div>
                <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Devices</h4>
                {safeDevices.length > 0 ? (
                    <ul className="list-disc list-inside space-y-1">
                        {safeDevices.map((device, index) => (
                            <li key={index} className="text-sm text-gray-900 dark:text-white">
                                {String(device.name || device.ip_address || device.hostname || 'Unknown Device')}
                                {typeof device.ip_address === 'string' && ` (${device.ip_address})`}
                                {typeof device.mac_address === 'string' && ` [MAC: ${device.mac_address}]`}
                            </li>
                        ))}
                    </ul>
                ) : (
                    <p className="text-sm text-gray-500 italic">No devices discovered.</p>
                )}
            </div>

            <div>
                <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Interfaces</h4>
                {safeInterfaces.length > 0 ? (
                    <div className="mt-4">
                        <InterfaceTable 
                            interfaces={safeInterfaces} 
                            showDeviceColumn={false}
                            jsonViewTheme="pop"
                        />
                    </div>
                ) : (
                    <p className="text-sm text-gray-500 italic">No interfaces discovered.</p>
                )}
            </div>

            <div>
                <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Topology</h4>
                {parsedDetails.topology ? (
                    <pre className="bg-gray-50 dark:bg-gray-700 p-2 rounded-md text-xs overflow-auto text-gray-900 dark:text-white">
                        {/* Use JSON.stringify and explicitly check for null/undefined before stringifying */}
                        {JSON.stringify(parsedDetails.topology, null, 2)}
                    </pre>
                ) : (
                    <p className="text-sm text-gray-500 italic">No topology data available.</p>
                )}
            </div>
        </div>
    );
};

export default NetworkDiscoveryDetails;