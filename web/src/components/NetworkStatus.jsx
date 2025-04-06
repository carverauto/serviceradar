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
import { useRouter } from 'next/navigation';

// Constants
const REFRESH_INTERVAL = 10000; // 10 seconds to match other components

// Helper functions for formatting
const formatResponseTime = (time) => {
    if (!time && time !== 0) return 'N/A';
    return `${(time / 1000000).toFixed(2)}ms`;
};

const formatPacketLoss = (loss) => {
    if (typeof loss !== 'number') return 'N/A';
    return `${loss.toFixed(1)}%`;
};

// Individual ping status component with auto-refresh
const PingStatus = ({ details, nodeId, serviceName }) => {
    const router = useRouter();
    const [pingData, setPingData] = useState(null);
    const [isLoading, setIsLoading] = useState(true);

    // Initialize from props
    useEffect(() => {
        try {
            const parsedDetails = typeof details === 'string' ? JSON.parse(details) : details;
            setPingData(parsedDetails);
            setIsLoading(false);
        } catch (e) {
            console.error('Error parsing ping details:', e);
            setPingData(null);
            setIsLoading(false);
        }
    }, [details]);

    // Set up auto-refresh using router.refresh()
    useEffect(() => {
        if (!nodeId || !serviceName) return; // Skip if we don't have IDs for direct refresh

        const interval = setInterval(() => {
            router.refresh(); // This will trigger a server-side refetch
        }, REFRESH_INTERVAL);

        return () => clearInterval(interval);
    }, [router, nodeId, serviceName]);

    if (isLoading) {
        return (
            <div className="grid grid-cols-2 gap-2 text-sm transition-colors">
                <div className="font-medium text-gray-600 dark:text-gray-400">Loading ping data...</div>
                <div className="h-4 w-32 bg-gray-200 dark:bg-gray-700 animate-pulse rounded"></div>
            </div>
        );
    }

    if (!pingData) {
        return (
            <div className="text-gray-500 dark:text-gray-400 transition-colors">
                No ping data available
            </div>
        );
    }

    return (
        <div className="grid grid-cols-2 gap-2 text-sm transition-colors">
            <div className="font-medium text-gray-600 dark:text-gray-400">Response Time:</div>
            <div className="text-gray-800 dark:text-gray-100">
                {formatResponseTime(pingData.response_time)}
            </div>

            <div className="font-medium text-gray-600 dark:text-gray-400">Packet Loss:</div>
            <div className="text-gray-800 dark:text-gray-100">
                {formatPacketLoss(pingData.packet_loss)}
            </div>

            <div className="font-medium text-gray-600 dark:text-gray-400">Status:</div>
            <div
                className={`font-medium ${
                    pingData.available
                        ? 'text-green-600 dark:text-green-400'
                        : 'text-red-600 dark:text-red-400'
                }`}
            >
                {pingData.available ? 'Available' : 'Unavailable'}
            </div>

            {(nodeId && serviceName) && (
                <div className="col-span-2 mt-2 text-xs text-gray-500 dark:text-gray-400">
                    Auto-refreshing data
                </div>
            )}
        </div>
    );
};

// Summary component for multiple hosts
const ICMPSummary = ({ hosts }) => {
    if (!Array.isArray(hosts) || hosts.length === 0) {
        return (
            <div className="text-gray-500 dark:text-gray-400 transition-colors">
                No ICMP data available
            </div>
        );
    }

    const respondingHosts = hosts.filter((h) => h.available).length;
    const totalResponseTime = hosts.reduce((sum, host) => {
        if (host.available && host.response_time) {
            return sum + host.response_time;
        }
        return sum;
    }, 0);
    const avgResponseTime = respondingHosts > 0 ? totalResponseTime / respondingHosts : 0;

    return (
        <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
            <div className="grid grid-cols-2 gap-4 text-sm">
                <div className="font-medium text-gray-600 dark:text-gray-400">ICMP Responding:</div>
                <div className="text-gray-800 dark:text-gray-100">{respondingHosts} hosts</div>

                <div className="font-medium text-gray-600 dark:text-gray-400">
                    Average Response Time:
                </div>
                <div className="text-gray-800 dark:text-gray-100">
                    {formatResponseTime(avgResponseTime)}
                </div>
            </div>
        </div>
    );
};

// Network sweep ICMP summary
const NetworkSweepICMP = ({ sweepData }) => {
    if (!sweepData || !sweepData.hosts) {
        return (
            <div className="text-gray-500 dark:text-gray-400 transition-colors">
                No sweep data available
            </div>
        );
    }

    const hosts = sweepData.hosts.filter((host) => host.icmp_status);
    const respondingHosts = hosts.filter((host) => host.icmp_status.available).length;

    let avgResponseTime = 0;
    const respondingHostsWithTime = hosts.filter((host) => {
        return host.icmp_status.available && host.icmp_status.round_trip;
    });

    if (respondingHostsWithTime.length > 0) {
        const totalTime = respondingHostsWithTime.reduce((sum, host) => {
            return sum + (host.icmp_status.round_trip || 0);
        }, 0);
        avgResponseTime = totalTime / respondingHostsWithTime.length;
    }

    return (
        <div className="space-y-4 transition-colors">
            <h3 className="text-lg font-medium text-gray-800 dark:text-gray-100">
                ICMP Status Summary
            </h3>
            <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
                <div className="grid grid-cols-2 gap-4 text-sm">
                    <div className="font-medium text-gray-600 dark:text-gray-400">
                        ICMP Responding:
                    </div>
                    <div className="text-gray-800 dark:text-gray-100">{respondingHosts} hosts</div>

                    <div className="font-medium text-gray-600 dark:text-gray-400">
                        Average Response Time:
                    </div>
                    <div className="text-gray-800 dark:text-gray-100">
                        {formatResponseTime(avgResponseTime)}
                    </div>
                </div>
            </div>
        </div>
    );
};

export { PingStatus, ICMPSummary, NetworkSweepICMP };