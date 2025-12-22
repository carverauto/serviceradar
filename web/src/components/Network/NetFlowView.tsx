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
import { Activity, ArrowUpDown, Network } from 'lucide-react';
import { cachedQuery } from '@/lib/cached-query';
import { useAuth } from '@/components/AuthProvider';

interface FlowStats {
    src_endpoint_ip?: string;
    dst_endpoint_port?: number;
    total_bytes: number;
}

interface FlowRecord {
    time: string;
    src_endpoint_ip?: string;
    src_endpoint_port?: number;
    dst_endpoint_ip?: string;
    dst_endpoint_port?: number;
    protocol_num?: number;
    protocol_name?: string;
    bytes_total: number;
    packets_total: number;
    bytes_in: number;
    bytes_out: number;
}

const formatBytes = (bytes: number): string => {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return `${(bytes / Math.pow(k, i)).toFixed(2)} ${sizes[i]}`;
};

const formatNumber = (num: number): string => {
    return num.toLocaleString();
};

export default function NetFlowView() {
    const { token } = useAuth();
    const [topTalkers, setTopTalkers] = useState<FlowStats[]>([]);
    const [topPorts, setTopPorts] = useState<FlowStats[]>([]);
    const [recentFlows, setRecentFlows] = useState<FlowRecord[]>([]);
    const [loadingTalkers, setLoadingTalkers] = useState(true);
    const [loadingPorts, setLoadingPorts] = useState(true);
    const [loadingRecent, setLoadingRecent] = useState(true);

    useEffect(() => {
        if (!token) return;

        // Fetch top talkers by source IP
        const fetchTopTalkers = async () => {
            try {
                setLoadingTalkers(true);
                const query = 'in:flows time:last_24h stats:"sum(bytes_total) as total_bytes by src_endpoint_ip" sort:total_bytes:desc limit:10';
                const response = await cachedQuery(query, token, {
                    staleTime: 30000,
                    cacheTime: 60000,
                });
                if (response?.results) {
                    setTopTalkers(response.results as FlowStats[]);
                }
            } catch (error) {
                console.error('Error fetching top talkers:', error);
            } finally {
                setLoadingTalkers(false);
            }
        };

        // Fetch top destination ports
        const fetchTopPorts = async () => {
            try {
                setLoadingPorts(true);
                const query = 'in:flows time:last_24h stats:"sum(bytes_total) as total_bytes by dst_endpoint_port" sort:total_bytes:desc limit:10';
                const response = await cachedQuery(query, token, {
                    staleTime: 30000,
                    cacheTime: 60000,
                });
                if (response?.results) {
                    setTopPorts(response.results as FlowStats[]);
                }
            } catch (error) {
                console.error('Error fetching top ports:', error);
            } finally {
                setLoadingPorts(false);
            }
        };

        // Fetch recent flows
        const fetchRecentFlows = async () => {
            try {
                setLoadingRecent(true);
                const query = 'in:flows time:last_1h sort:time:desc limit:20';
                const response = await cachedQuery(query, token, {
                    staleTime: 10000,
                    cacheTime: 30000,
                });
                if (response?.results) {
                    setRecentFlows(response.results as FlowRecord[]);
                }
            } catch (error) {
                console.error('Error fetching recent flows:', error);
            } finally {
                setLoadingRecent(false);
            }
        };

        fetchTopTalkers();
        fetchTopPorts();
        fetchRecentFlows();

        // Refresh every 30 seconds
        const interval = setInterval(() => {
            fetchTopTalkers();
            fetchTopPorts();
            fetchRecentFlows();
        }, 30000);

        return () => clearInterval(interval);
    }, [token]);

    const getProtocolName = (num?: number, name?: string): string => {
        if (name) return name;
        if (!num) return 'Unknown';
        const protocols: Record<number, string> = {
            1: 'ICMP',
            6: 'TCP',
            17: 'UDP',
            47: 'GRE',
            50: 'ESP',
            51: 'AH',
        };
        return protocols[num] || `Protocol ${num}`;
    };

    const getPortName = (port: number): string => {
        const wellKnown: Record<number, string> = {
            20: 'FTP Data',
            21: 'FTP',
            22: 'SSH',
            23: 'Telnet',
            25: 'SMTP',
            53: 'DNS',
            80: 'HTTP',
            110: 'POP3',
            143: 'IMAP',
            443: 'HTTPS',
            3306: 'MySQL',
            3389: 'RDP',
            5432: 'PostgreSQL',
            8080: 'HTTP Alt',
        };
        return wellKnown[port] || `Port ${port}`;
    };

    return (
        <div className="space-y-6">
            {/* Summary Cards */}
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-6">
                    <div className="flex items-center gap-3 mb-2">
                        <Network size={24} className="text-blue-500 dark:text-blue-400" />
                        <h3 className="text-lg font-semibold text-gray-900 dark:text-white">Top Talkers</h3>
                    </div>
                    <p className="text-3xl font-bold text-gray-900 dark:text-white">
                        {loadingTalkers ? '...' : topTalkers.length}
                    </p>
                    <p className="text-sm text-gray-600 dark:text-gray-400">Active sources (24h)</p>
                </div>

                <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-6">
                    <div className="flex items-center gap-3 mb-2">
                        <ArrowUpDown size={24} className="text-green-500 dark:text-green-400" />
                        <h3 className="text-lg font-semibold text-gray-900 dark:text-white">Total Bandwidth</h3>
                    </div>
                    <p className="text-3xl font-bold text-gray-900 dark:text-white">
                        {loadingTalkers
                            ? '...'
                            : formatBytes(topTalkers.reduce((sum, t) => sum + t.total_bytes, 0))}
                    </p>
                    <p className="text-sm text-gray-600 dark:text-gray-400">Last 24 hours</p>
                </div>

                <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-6">
                    <div className="flex items-center gap-3 mb-2">
                        <Activity size={24} className="text-purple-500 dark:text-purple-400" />
                        <h3 className="text-lg font-semibold text-gray-900 dark:text-white">Active Flows</h3>
                    </div>
                    <p className="text-3xl font-bold text-gray-900 dark:text-white">
                        {loadingRecent ? '...' : recentFlows.length}
                    </p>
                    <p className="text-sm text-gray-600 dark:text-gray-400">Last hour</p>
                </div>
            </div>

            {/* Top Talkers and Top Ports */}
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                {/* Top Talkers */}
                <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-6">
                    <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">
                        Top Talkers by Bytes (24h)
                    </h3>
                    {loadingTalkers ? (
                        <p className="text-gray-600 dark:text-gray-400 text-center py-8">Loading...</p>
                    ) : topTalkers.length === 0 ? (
                        <p className="text-gray-600 dark:text-gray-400 text-center py-8">No flow data available</p>
                    ) : (
                        <div className="space-y-3">
                            {topTalkers.map((talker, index) => (
                                <div
                                    key={talker.src_endpoint_ip || index}
                                    className="flex items-center justify-between p-3 bg-gray-50 dark:bg-gray-800/50 rounded-md"
                                >
                                    <div className="flex items-center gap-3">
                                        <span className="text-sm font-medium text-gray-500 dark:text-gray-400 w-6">
                                            {index + 1}
                                        </span>
                                        <span className="font-mono text-sm text-gray-900 dark:text-white">
                                            {talker.src_endpoint_ip || 'Unknown'}
                                        </span>
                                    </div>
                                    <span className="text-sm font-semibold text-blue-600 dark:text-blue-400">
                                        {formatBytes(talker.total_bytes)}
                                    </span>
                                </div>
                            ))}
                        </div>
                    )}
                </div>

                {/* Top Destination Ports */}
                <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-6">
                    <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">
                        Top Destination Ports (24h)
                    </h3>
                    {loadingPorts ? (
                        <p className="text-gray-600 dark:text-gray-400 text-center py-8">Loading...</p>
                    ) : topPorts.length === 0 ? (
                        <p className="text-gray-600 dark:text-gray-400 text-center py-8">No port data available</p>
                    ) : (
                        <div className="space-y-3">
                            {topPorts.map((portStat, index) => (
                                <div
                                    key={portStat.dst_endpoint_port || index}
                                    className="flex items-center justify-between p-3 bg-gray-50 dark:bg-gray-800/50 rounded-md"
                                >
                                    <div className="flex items-center gap-3">
                                        <span className="text-sm font-medium text-gray-500 dark:text-gray-400 w-6">
                                            {index + 1}
                                        </span>
                                        <div>
                                            <span className="font-mono text-sm text-gray-900 dark:text-white">
                                                {portStat.dst_endpoint_port || 'Unknown'}
                                            </span>
                                            {portStat.dst_endpoint_port && (
                                                <span className="ml-2 text-xs text-gray-500 dark:text-gray-400">
                                                    {getPortName(portStat.dst_endpoint_port)}
                                                </span>
                                            )}
                                        </div>
                                    </div>
                                    <span className="text-sm font-semibold text-green-600 dark:text-green-400">
                                        {formatBytes(portStat.total_bytes)}
                                    </span>
                                </div>
                            ))}
                        </div>
                    )}
                </div>
            </div>

            {/* Recent Flows Table */}
            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg p-6">
                <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Recent Flows (Last Hour)</h3>
                {loadingRecent ? (
                    <p className="text-gray-600 dark:text-gray-400 text-center py-8">Loading...</p>
                ) : recentFlows.length === 0 ? (
                    <p className="text-gray-600 dark:text-gray-400 text-center py-8">No recent flows</p>
                ) : (
                    <div className="overflow-x-auto">
                        <table className="w-full text-sm">
                            <thead>
                                <tr className="border-b border-gray-200 dark:border-gray-700">
                                    <th className="text-left py-3 px-2 font-semibold text-gray-700 dark:text-gray-300">
                                        Time
                                    </th>
                                    <th className="text-left py-3 px-2 font-semibold text-gray-700 dark:text-gray-300">
                                        Source
                                    </th>
                                    <th className="text-left py-3 px-2 font-semibold text-gray-700 dark:text-gray-300">
                                        Destination
                                    </th>
                                    <th className="text-left py-3 px-2 font-semibold text-gray-700 dark:text-gray-300">
                                        Protocol
                                    </th>
                                    <th className="text-right py-3 px-2 font-semibold text-gray-700 dark:text-gray-300">
                                        Bytes
                                    </th>
                                    <th className="text-right py-3 px-2 font-semibold text-gray-700 dark:text-gray-300">
                                        Packets
                                    </th>
                                </tr>
                            </thead>
                            <tbody>
                                {recentFlows.map((flow, index) => (
                                    <tr
                                        key={index}
                                        className="border-b border-gray-100 dark:border-gray-800 hover:bg-gray-50 dark:hover:bg-gray-800/50"
                                    >
                                        <td className="py-2 px-2 text-gray-600 dark:text-gray-400 font-mono text-xs">
                                            {new Date(flow.time).toLocaleTimeString()}
                                        </td>
                                        <td className="py-2 px-2 text-gray-900 dark:text-white font-mono text-xs">
                                            {flow.src_endpoint_ip || 'Unknown'}
                                            {flow.src_endpoint_port && `:${flow.src_endpoint_port}`}
                                        </td>
                                        <td className="py-2 px-2 text-gray-900 dark:text-white font-mono text-xs">
                                            {flow.dst_endpoint_ip || 'Unknown'}
                                            {flow.dst_endpoint_port && `:${flow.dst_endpoint_port}`}
                                        </td>
                                        <td className="py-2 px-2 text-gray-600 dark:text-gray-400">
                                            {getProtocolName(flow.protocol_num, flow.protocol_name)}
                                        </td>
                                        <td className="py-2 px-2 text-right text-gray-900 dark:text-white">
                                            {formatBytes(flow.bytes_total)}
                                        </td>
                                        <td className="py-2 px-2 text-right text-gray-600 dark:text-gray-400">
                                            {formatNumber(flow.packets_total)}
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>
                )}
            </div>
        </div>
    );
}
