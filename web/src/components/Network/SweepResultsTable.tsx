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

import React, { useState, Fragment } from 'react';
import { CheckCircle, XCircle, ChevronDown, ChevronRight, Clock, Server } from 'lucide-react';
import ReactJson from '@/components/Common/DynamicReactJson';

export interface SweepResult {
    _tp_time: string;
    agent_id: string;
    available: boolean;
    discovery_source: string;
    hostname?: string | null;
    ip: string;
    mac?: string | null;
    metadata: Record<string, unknown>;
    partition: string;
    poller_id: string;
    timestamp: string;
}

interface SweepResultsTableProps {
    sweepResults: SweepResult[];
    showPollerColumn?: boolean;
    showPartitionColumn?: boolean;
    jsonViewTheme?: 'rjv-default' | 'pop';
}

const SweepResultsTable: React.FC<SweepResultsTableProps> = ({ 
    sweepResults, 
    showPollerColumn = false,
    showPartitionColumn = false,
    jsonViewTheme = 'pop'
}) => {
    const [expandedRow, setExpandedRow] = useState<string | null>(null);

    const getAvailabilityColor = (available: boolean) => {
        return available ? 'text-green-500' : 'text-red-500';
    };

    const formatTimestamp = (timestamp: string) => {
        try {
            return new Date(timestamp).toLocaleString();
        } catch {
            return 'Invalid Date';
        }
    };

    const getRelativeTime = (timestamp: string) => {
        try {
            const date = new Date(timestamp);
            const now = new Date();
            const diffMs = now.getTime() - date.getTime();
            const diffMinutes = Math.floor(diffMs / (1000 * 60));
            const diffHours = Math.floor(diffMinutes / 60);
            const diffDays = Math.floor(diffHours / 24);

            if (diffMinutes < 1) return 'Just now';
            if (diffMinutes < 60) return `${diffMinutes}m ago`;
            if (diffHours < 24) return `${diffHours}h ago`;
            return `${diffDays}d ago`;
        } catch {
            return 'Unknown';
        }
    };

    if (!sweepResults || sweepResults.length === 0) {
        return (
            <div className="text-center p-8 text-gray-400">
                No sweep results found.
            </div>
        );
    }

    return (
        <div className="overflow-x-auto">
            <table className="min-w-full divide-y divide-gray-700">
                <thead className="bg-gray-800/50">
                    <tr>
                        <th scope="col" className="w-12"></th>
                        <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider">
                            Status
                        </th>
                        <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider">
                            Host
                        </th>
                        {showPollerColumn && (
                            <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider">
                                Poller
                            </th>
                        )}
                        {showPartitionColumn && (
                            <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider">
                                Partition
                            </th>
                        )}
                        <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider">
                            Discovery Source
                        </th>
                        <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider">
                            Last Checked
                        </th>
                    </tr>
                </thead>
                <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                    {sweepResults.map((result, index) => {
                        const rowKey = `${result.ip}-${result.timestamp}-${index}`;
                        return (
                            <Fragment key={rowKey}>
                                <tr className="hover:bg-gray-700/30">
                                    <td className="pl-4">
                                        <button
                                            onClick={() => setExpandedRow(expandedRow === rowKey ? null : rowKey)}
                                            className="p-1 rounded-full hover:bg-gray-600"
                                        >
                                            {expandedRow === rowKey ? 
                                                <ChevronDown className="h-5 w-5 text-gray-400" /> : 
                                                <ChevronRight className="h-5 w-5 text-gray-400" />
                                            }
                                        </button>
                                    </td>
                                    <td className="px-6 py-4 whitespace-nowrap">
                                        <div className="flex items-center">
                                            {result.available ? (
                                                <CheckCircle className="h-5 w-5 text-green-500" />
                                            ) : (
                                                <XCircle className="h-5 w-5 text-red-500" />
                                            )}
                                            <span className={`ml-2 text-sm font-medium ${getAvailabilityColor(result.available)}`}>
                                                {result.available ? 'Available' : 'Unavailable'}
                                            </span>
                                        </div>
                                    </td>
                                    <td className="px-6 py-4 whitespace-nowrap">
                                        <div className="text-sm font-medium text-white">
                                            {result.hostname || result.ip}
                                        </div>
                                        {result.hostname && (
                                            <div className="text-sm text-gray-400 font-mono">
                                                {result.ip}
                                            </div>
                                        )}
                                        {result.mac && (
                                            <div className="text-xs text-gray-500 font-mono">
                                                MAC: {result.mac}
                                            </div>
                                        )}
                                    </td>
                                    {showPollerColumn && (
                                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-300">
                                            {result.poller_id}
                                        </td>
                                    )}
                                    {showPartitionColumn && (
                                        <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-300">
                                            {result.partition}
                                        </td>
                                    )}
                                    <td className="px-6 py-4 whitespace-nowrap">
                                        <div className="flex items-center">
                                            <Server className="h-4 w-4 text-gray-400 mr-2" />
                                            <span className="text-sm text-gray-300 capitalize">
                                                {result.discovery_source}
                                            </span>
                                        </div>
                                    </td>
                                    <td className="px-6 py-4 whitespace-nowrap">
                                        <div className="flex items-center">
                                            <Clock className="h-4 w-4 text-gray-400 mr-2" />
                                            <div>
                                                <div className="text-sm text-gray-300">
                                                    {getRelativeTime(result.timestamp)}
                                                </div>
                                                <div className="text-xs text-gray-500">
                                                    {formatTimestamp(result.timestamp)}
                                                </div>
                                            </div>
                                        </div>
                                    </td>
                                </tr>
                                {expandedRow === rowKey && (
                                    <tr className="bg-gray-800/50">
                                        <td colSpan={showPollerColumn && showPartitionColumn ? 7 : showPollerColumn || showPartitionColumn ? 6 : 5} className="p-0">
                                            <div className="p-4">
                                                <h4 className="text-md font-semibold text-white mb-2">
                                                    Sweep Result Details
                                                </h4>
                                                <div className="grid grid-cols-2 gap-4 mb-4">
                                                    <div>
                                                        <span className="text-sm text-gray-400">Agent ID:</span>
                                                        <span className="text-sm text-gray-200 ml-2">
                                                            {result.agent_id}
                                                        </span>
                                                    </div>
                                                    <div>
                                                        <span className="text-sm text-gray-400">Discovery Time:</span>
                                                        <span className="text-sm text-gray-200 ml-2">
                                                            {formatTimestamp(result._tp_time)}
                                                        </span>
                                                    </div>
                                                    <div>
                                                        <span className="text-sm text-gray-400">Timestamp:</span>
                                                        <span className="text-sm text-gray-200 ml-2">
                                                            {formatTimestamp(result.timestamp)}
                                                        </span>
                                                    </div>
                                                    <div>
                                                        <span className="text-sm text-gray-400">Source:</span>
                                                        <span className="text-sm text-gray-200 ml-2 capitalize">
                                                            {result.discovery_source}
                                                        </span>
                                                    </div>
                                                </div>
                                                {Object.keys(result.metadata).length > 0 && (
                                                    <>
                                                        <h4 className="text-md font-semibold text-white mb-2">
                                                            Metadata
                                                        </h4>
                                                        <ReactJson
                                                            src={result.metadata}
                                                            theme={jsonViewTheme}
                                                            collapsed={false}
                                                            displayDataTypes={false}
                                                            enableClipboard={true}
                                                            style={{
                                                                padding: '1rem',
                                                                borderRadius: '0.375rem',
                                                                backgroundColor: '#1C1B22'
                                                            }}
                                                        />
                                                    </>
                                                )}
                                            </div>
                                        </td>
                                    </tr>
                                )}
                            </Fragment>
                        );
                    })}
                </tbody>
            </table>
        </div>
    );
};

export default SweepResultsTable;