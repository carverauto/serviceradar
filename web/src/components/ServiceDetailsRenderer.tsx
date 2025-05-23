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

// src/components/ServiceDetailsRenderer.tsx
import React from 'react';
import {
    Service,
    SweepDetails,
    SnmpDetails,
    RperfDetails,
    GenericServiceDetails,
    ServiceDetails,
    RperfResult
} from '@/types/types';
import NetworkDiscoveryDetails from "@/components/NetworkDiscoveryDetails";

interface ServiceDetailsRendererProps {
    service: Service;
}

const ServiceDetailsRenderer: React.FC<ServiceDetailsRendererProps> = ({ service }) => {
    // Helper function to format timestamps
    const formatTimestamp = (timestamp: string | number): string => {
        try {
            return new Date(timestamp).toLocaleString();
        } catch {
            return 'N/A';
        }
    };

    // Helper function to calculate average for arrays of numbers
    const calculateAverage = (values: number[]): number => {
        if (!values || values.length === 0) return 0;
        const sum = values.reduce((acc, val) => acc + val, 0);
        return sum / values.length;
    };

    // Helper function to convert bytes to a human-readable format
    const formatBytes = (bytes: number): string => {
        if (bytes < 1024) return `${bytes} B`;
        if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(2)} KB`;
        if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
        return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
    };

    // Safely parse service.details
    let details: ServiceDetails | undefined;
    try {
        details = typeof service.details === 'string' ? JSON.parse(service.details) : service.details;
    } catch (error) {
        console.error(`Failed to parse service.details for ${service.name}:`, error);
        details = undefined;
    }

    // Log the details for debugging
    console.log(`Service: ${service.name}, Type: ${service.type}, Details:`, details);

    // If details is undefined or null, show a fallback message
    if (!details) {
        return <div className="text-gray-500 italic">Service details not available</div>;
    }

    // Special handling for lan_discovery_via_mapper service
    if (service.name === 'lan_discovery_via_mapper' || service.type === 'network_discovery') {
        console.log("Rendering network discovery details");
        return <NetworkDiscoveryDetails details={details} />;
    }

    // Type-specific summary rendering
    if (service.type === 'icmp' && details) {
        const icmpDetails = details as GenericServiceDetails;
        return (
            <div className="mb-4">
                <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">ICMP Summary</h4>
                <div className="grid grid-cols-2 gap-3">
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">Available:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{icmpDetails.available ? 'Yes' : 'No'}</span>
                    </div>
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">Response Time:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">
              {icmpDetails.response_time ? `${(icmpDetails.response_time / 1000000).toFixed(2)} ms` : 'N/A'}
            </span>
                    </div>
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">Packet Loss:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{icmpDetails.packet_loss || 0}%</span>
                    </div>
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">Round Trip:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{icmpDetails.round_trip || 0} ms</span>
                    </div>
                </div>
            </div>
        );
    }

    if (service.type === 'sweep' && details) {
        const sweepDetails = details as SweepDetails;
        const portsCount = sweepDetails.ports ? sweepDetails.ports.length : 0;
        const hosts = sweepDetails.hosts || [];
        const availableHosts = hosts.filter((host) => host.available).length;
        const lastSweep = sweepDetails.last_sweep ? formatTimestamp(sweepDetails.last_sweep) : 'N/A';

        return (
            <div className="mb-4">
                <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Network Sweep Summary</h4>
                <div className="grid grid-cols-2 gap-3">
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">Available Hosts:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{availableHosts} / {hosts.length}</span>
                    </div>
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">Last Sweep:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{lastSweep}</span>
                    </div>
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">Ports Scanned:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{portsCount}</span>
                    </div>
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">Total Hosts:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{sweepDetails.total_hosts || 0}</span>
                    </div>
                </div>
            </div>
        );
    }

    if (service.type === 'snmp' && details) {
        const snmpDetails = details as SnmpDetails;
        // Dynamically select the first device in the details object
        const deviceKeys = Object.keys(snmpDetails);
        const deviceKey = deviceKeys.length > 0 ? deviceKeys[0] : null;
        const device = deviceKey ? snmpDetails[deviceKey] : {};
        const lastPoll = device?.last_poll ? formatTimestamp(device.last_poll) : 'N/A';
        const oidStatus = device?.oid_status || {};
        const ifInOctets = oidStatus['ifInOctets_4']?.last_value || 0;
        const ifOutOctets = oidStatus['ifOutOctets_4']?.last_value || 0;
        const errorCount = oidStatus['ifInOctets_4']?.error_count || oidStatus['ifOutOctets_4']?.error_count || 0;
        const available = device?.available !== undefined ? (device.available ? 'Yes' : 'No') : 'Unknown';

        return (
            <div className="mb-4">
                <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">SNMP Summary</h4>
                <div className="grid grid-cols-2 gap-3">
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">Device:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{deviceKey || 'Unknown'}</span>
                    </div>
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">Available:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{available}</span>
                    </div>
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">Last Poll:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{lastPoll}</span>
                    </div>
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">IfInOctets:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{formatBytes(ifInOctets)}</span>
                    </div>
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">IfOutOctets:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{formatBytes(ifOutOctets)}</span>
                    </div>
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">Error Count:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{errorCount}</span>
                    </div>
                </div>
            </div>
        );
    }

    if (service.name === 'rperf-checker' && details) {
        const rperfDetails = details as RperfDetails;
        // Try both possible key names to handle naming discrepancies
        const resultsKey = Object.keys(rperfDetails).find(key => key.toLowerCase() === 'results') as keyof RperfDetails | undefined;
        const results = resultsKey && resultsKey in rperfDetails
            ? rperfDetails[resultsKey] as RperfResult[] | undefined
            : rperfDetails.Results || [];

        // Ensure results is an array, default to empty array if undefined
        const safeResults = Array.isArray(results) ? results : [];

        // Log the results for debugging
        console.log(`Rperf Results for ${service.name}:`, safeResults);

        const successCount = safeResults.filter((result: RperfResult) => result.success || result.success).length;
        const bitsPerSecond = calculateAverage(safeResults.map((result: RperfResult) => result.summary?.bits_per_second || 0));
        const lossPercent = calculateAverage(safeResults.map((result: RperfResult) => result.summary?.loss_percent || 0));
        const jitterMs = calculateAverage(safeResults.map((result: RperfResult) => result.summary?.jitter_ms || 0));

        return (
            <div className="mb-4">
                <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Rperf Checker Summary</h4>
                <div className="grid grid-cols-2 gap-3">
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">Successful Tests:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{successCount} / {safeResults.length}</span>
                    </div>
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">Avg Bits Per Second:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{formatBytes(bitsPerSecond)}</span>
                    </div>
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">Avg Loss Percent:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{lossPercent.toFixed(2)}%</span>
                    </div>
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">Avg Jitter:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{jitterMs.toFixed(2)} ms</span>
                    </div>
                </div>
            </div>
        );
    }

    if (service.type === 'port' && details) {
        const portDetails = details as GenericServiceDetails;
        const lastUpdate = portDetails.last_update ? formatTimestamp(portDetails.last_update) : 'N/A';
        const available = portDetails.available !== undefined ? (portDetails.available ? 'Yes' : 'No') : 'Unknown';

        return (
            <div className="mb-4">
                <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Port Summary</h4>
                <div className="grid grid-cols-2 gap-3">
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">Available:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{available}</span>
                    </div>
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">Last Update:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{lastUpdate}</span>
                    </div>
                </div>
            </div>
        );
    }

    // Generic rendering for other service types
    const genericDetails = details as GenericServiceDetails;
    const lastUpdate = genericDetails.last_update ? formatTimestamp(genericDetails.last_update) : 'N/A';
    const available = genericDetails.available !== undefined ? (genericDetails.available ? 'Yes' : 'No') : 'Unknown';
    const keyMetric = Object.keys(genericDetails).find(key => key.includes('value') || key.includes('count'));
    const keyMetricValue = keyMetric ? genericDetails[keyMetric] : 'N/A';

    // Convert keyMetricValue to a string representation for display
    const displayValue = keyMetricValue === null || keyMetricValue === undefined
        ? 'N/A'
        : typeof keyMetricValue === 'object'
            ? JSON.stringify(keyMetricValue)
            : String(keyMetricValue);

    return (
        <div className="mb-4">
            <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Service Summary</h4>
            <div className="grid grid-cols-2 gap-3">
                <div className="text-sm">
                    <span className="font-medium text-gray-700 dark:text-gray-300">Available:</span>
                    <span className="ml-2 text-gray-900 dark:text-white">{available}</span>
                </div>
                <div className="text-sm">
                    <span className="font-medium text-gray-700 dark:text-gray-300">Last Update:</span>
                    <span className="ml-2 text-gray-900 dark:text-white">{lastUpdate}</span>
                </div>
                {keyMetric && (
                    <div className="text-sm">
                        <span className="font-medium text-gray-700 dark:text-gray-300">{keyMetric.replace('_', ' ')}:</span>
                        <span className="ml-2 text-gray-900 dark:text-white">{displayValue}</span>
                    </div>
                )}
            </div>
        </div>
    );

};

export default ServiceDetailsRenderer;