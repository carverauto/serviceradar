// web/src/components/NetworkDiscoveryDetails.tsx
import React from 'react';

/**
 * RawBackendDevice represents a device object as it might be received directly from the backend JSON.
 * It uses snake_case keys where applicable and `unknown` for arbitrary additional properties.
 */
interface RawBackendDevice {
    name?: string; // Often a display name, may be derived
    ip_address?: string; // Derived IP address
    mac_address?: string; // Derived MAC address
    description?: string;
    // Raw properties from backend (snake_case)
    device_id?: string;
    hostname?: string;
    ip?: string; // raw ip address
    mac?: string; // raw mac address
    sys_descr?: string;
    sys_contact?: string;
    discovery_source?: string;
    [key: string]: unknown; // For any other properties not explicitly listed
}

/**
 * RawBackendInterface represents an interface object as it might be received directly from the backend JSON.
 * It uses snake_case keys where applicable and `unknown` for arbitrary additional properties.
 */
interface RawBackendInterface {
    name?: string; // Display name
    ip_address?: string; // Derived IP address
    mac_address?: string; // Derived MAC address
    status?: string; // Derived status
    // Raw properties from backend (snake_case)
    if_index?: number;
    if_name?: string;
    if_descr?: string;
    if_speed?: { value?: number } | number;
    if_phys_address?: string;
    if_admin_status?: number;
    if_oper_status?: number;
    if_type?: number;
    ip_addresses?: string[];
    [key: string]: unknown; // For any other properties not explicitly listed
}

/**
 * Basic interface for network topology, allowing for flexible structure with `unknown`.
 */
interface NetworkTopology {
    nodes?: { [key: string]: unknown }[];
    edges?: { [key: string]: unknown }[];
    subnets?: string[];
    [key: string]: unknown; // For any other properties not explicitly listed at the top level of topology
}

/**
 * NetworkDiscoveryServiceDetails represents the expected structure of the parsed JSON details.
 * It's based on the raw `snake_case` keys likely coming from the Go backend.
 */
interface NetworkDiscoveryServiceDetails {
    devices?: RawBackendDevice[];
    interfaces?: RawBackendInterface[];
    topology?: NetworkTopology | null; // Can be null or a more complex object
    last_discovery?: string;
    discovery_duration?: number;
    total_devices?: number;
    active_devices?: number;
    [key: string]: unknown; // Allow other top-level properties not explicitly listed
}

interface NetworkDiscoveryDetailsProps {
    details: string | NetworkDiscoveryServiceDetails | null | undefined; // Can be JSON string, parsed object, null, or undefined
}

const NetworkDiscoveryDetails: React.FC<NetworkDiscoveryDetailsProps> = ({ details }) => {
    let parsedDetails: NetworkDiscoveryServiceDetails | undefined;

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
    // (though the interfaces are defined as arrays, defensive programming is good).
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
                                {String(iface.name || iface.ip_address || iface.if_descr || 'Unknown Interface')}
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