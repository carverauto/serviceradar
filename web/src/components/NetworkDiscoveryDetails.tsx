// web/src/components/NetworkDiscoveryDetails.tsx
import React from 'react';

interface NetworkDiscoveryServiceDetails {
    devices?: Array<{
        name?: string;
        ip_address?: string;
        mac_address?: string;
        description?: string;
        [key: string]: any;
    }>;
    interfaces?: Array<{
        name?: string;
        ip_address?: string;
        mac_address?: string;
        status?: string;
        [key: string]: any;
    }>;
    topology?: any; // Can be null or a more complex object
}

interface NetworkDiscoveryDetailsProps {
    details: any; // Can be string (from json.RawMessage) or object
}

// web/src/components/NetworkDiscoveryDetails.tsx
// ...
const NetworkDiscoveryDetails: React.FC<NetworkDiscoveryDetailsProps> = ({ details }) => {
    let parsedDetails: NetworkDiscoveryServiceDetails | undefined;

    try {
        parsedDetails = typeof details === 'string' ? JSON.parse(details) : details;
    } catch (error) {
        console.error('Error parsing network discovery details:', error);
        parsedDetails = undefined;
    }

    if (!parsedDetails) {
        return <div className="text-gray-500 italic">No network discovery details available or failed to parse.</div>;
    }

    // Ensure devices and interfaces are arrays, gracefully handling single objects if they appear
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
                                {String(device.name || device.ip_address || 'Unknown Device')}
                                {device.ip_address && ` (${String(device.ip_address)})`}
                                {device.mac_address && ` [MAC: ${String(device.mac_address)}]`}
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
                    <ul className="list-disc list-inside space-y-1">
                        {safeInterfaces.map((iface, index) => (
                            <li key={index} className="text-sm text-gray-900 dark:text-white">
                                {String(iface.name || iface.ip_address || 'Unknown Interface')}
                                {iface.ip_address && ` (${String(iface.ip_address)})`}
                                {iface.mac_address && ` [MAC: ${String(iface.mac_address)}]`}
                                {iface.status && ` (Status: ${String(iface.status)})`}
                            </li>
                        ))}
                    </ul>
                ) : (
                    <p className="text-sm text-gray-500 italic">No interfaces discovered.</p>
                )}
            </div>

            <div>
                <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Topology</h4>
                {parsedDetails.topology ? (
                    <pre className="bg-gray-50 dark:bg-gray-700 p-2 rounded-md text-xs overflow-auto text-gray-900 dark:text-white">
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