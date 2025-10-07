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
import { ChevronDown, ChevronRight } from 'lucide-react';
import ReactJson from '@/components/Common/DynamicReactJson';
import { Log } from '@/types/logs';

interface LogTableProps {
    logs: Log[];
    jsonViewTheme?: 'rjv-default' | 'pop';
}

const LogTable: React.FC<LogTableProps> = ({ 
    logs, 
    jsonViewTheme = 'pop'
}) => {
    const [expandedRow, setExpandedRow] = useState<string | null>(null);

    const getSeverityBadge = (severity: string | undefined | null) => {
        const upperSeverity = (severity || '').toUpperCase();

        switch (upperSeverity) {
            case 'ERROR':
            case 'FATAL':
            case 'CRITICAL':
                return 'bg-red-100 dark:bg-red-600/50 text-red-800 dark:text-red-200 border border-red-300 dark:border-red-500/60';
            case 'WARN':
            case 'WARNING':
                return 'bg-orange-100 dark:bg-orange-500/50 text-orange-800 dark:text-orange-200 border border-orange-300 dark:border-orange-400/60';
            case 'INFO':
                return 'bg-sky-100 dark:bg-sky-600/50 text-sky-800 dark:text-sky-200 border border-sky-300 dark:border-sky-500/60';
            case 'DEBUG':
            case 'TRACE':
                return 'bg-gray-100 dark:bg-gray-600/50 text-gray-800 dark:text-gray-200 border border-gray-300 dark:border-gray-500/60';
            default:
                return 'bg-gray-100 dark:bg-gray-600/50 text-gray-800 dark:text-gray-200 border border-gray-300 dark:border-gray-500/60';
        }
    };

    const formatDate = (dateString: string) => {
        try {
            return new Date(dateString).toLocaleString();
        } catch {
            return 'Invalid Date';
        }
    };

    const parseAttributes = (attrString: string): Record<string, string> => {
        if (!attrString || attrString.trim() === '') return {};
        try {
            const attrs: Record<string, string> = {};
            const pairs = attrString.split(',');
            for (const pair of pairs) {
                const [key, value] = pair.split('=');
                if (key && value) {
                    attrs[key.trim()] = value.trim();
                }
            }
            return attrs;
        } catch {
            return {};
        }
    };

    if (!logs || logs.length === 0) {
        return (
            <div className="text-center p-8 text-gray-600 dark:text-gray-400">
                No logs found.
            </div>
        );
    }

    return (
        <div className="overflow-x-auto">
            <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                <thead className="bg-gray-50 dark:bg-gray-800/50">
                    <tr>
                        <th scope="col" className="w-12"></th>
                        <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                            Timestamp
                        </th>
                        <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                            Severity
                        </th>
                        <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                            Service
                        </th>
                        <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                            Message
                        </th>
                        <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                            Trace ID
                        </th>
                    </tr>
                </thead>
                <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                    {logs.map((log, index) => {
                        const uniqueKey = `${log.timestamp}-${log.trace_id || 'no-trace'}-${log.span_id || 'no-span'}-${index}`;
                        const expandKey = `${log.timestamp}-${log.trace_id || 'no-trace'}-${index}`;
                        return (
                            <Fragment key={uniqueKey}>
                                <tr className="hover:bg-gray-100 dark:hover:bg-gray-700/30">
                                    <td className="pl-4">
                                        <button
                                            onClick={() => setExpandedRow(expandedRow === expandKey ? null : expandKey)}
                                            className="p-1 rounded-full hover:bg-gray-200 dark:hover:bg-gray-600 text-gray-600 dark:text-gray-400"
                                        >
                                            {expandedRow === expandKey ? (
                                                <ChevronDown className="h-5 w-5" />
                                            ) : (
                                                <ChevronRight className="h-5 w-5" />
                                            )}
                                        </button>
                                    </td>
                                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300">
                                        {formatDate(log.timestamp)}
                                    </td>
                                    <td className="px-6 py-4 whitespace-nowrap">
                                        <span className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${getSeverityBadge(log.severity_text)}`}>
                                            {log.severity_text || 'Unknown'}
                                        </span>
                                    </td>
                                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300">
                                        {log.service_name || '-'}
                                    </td>
                                    <td
                                        className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300 font-mono max-w-lg truncate"
                                        title={log.body}
                                    >
                                        {log.body}
                                    </td>
                                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300 font-mono">
                                        {log.trace_id ? log.trace_id.substring(0, 8) + '...' : '-'}
                                    </td>
                                </tr>

                                {expandedRow === expandKey && (
                                    <tr className="bg-gray-100 dark:bg-gray-800/50">
                                        <td colSpan={6} className="p-0">
                                            <div className="p-4 space-y-4">
                                                <div>
                                                    <h4 className="text-md font-semibold text-gray-900 dark:text-white mb-2">
                                                        Log Details
                                                    </h4>
                                                    <div className="grid grid-cols-2 gap-4 text-sm">
                                                        <div>
                                                            <p className="text-gray-600 dark:text-gray-400">Trace ID:</p>
                                                            <p className="font-mono text-gray-900 dark:text-white">{log.trace_id || '-'}</p>
                                                        </div>
                                                        <div>
                                                            <p className="text-gray-600 dark:text-gray-400">Span ID:</p>
                                                            <p className="font-mono text-gray-900 dark:text-white">{log.span_id || '-'}</p>
                                                        </div>
                                                        <div>
                                                            <p className="text-gray-600 dark:text-gray-400">Service Version:</p>
                                                            <p className="text-gray-900 dark:text-white">{log.service_version || '-'}</p>
                                                        </div>
                                                        <div>
                                                            <p className="text-gray-600 dark:text-gray-400">Service Instance:</p>
                                                            <p className="text-gray-900 dark:text-white">{log.service_instance || '-'}</p>
                                                        </div>
                                                        <div>
                                                            <p className="text-gray-600 dark:text-gray-400">Scope:</p>
                                                            <p className="text-gray-900 dark:text-white">{log.scope_name || '-'}</p>
                                                        </div>
                                                        <div>
                                                            <p className="text-gray-600 dark:text-gray-400">Severity Number:</p>
                                                            <p className="text-gray-900 dark:text-white">{log.severity_number}</p>
                                                        </div>
                                                    </div>
                                                </div>

                                                {log.attributes && (
                                                    <div>
                                                        <h5 className="text-sm font-semibold text-gray-900 dark:text-white mb-1">
                                                            Attributes
                                                        </h5>
                                                        <div className="bg-gray-200 dark:bg-gray-700 p-2 rounded text-xs font-mono">
                                                            {Object.entries(parseAttributes(log.attributes)).map(([key, value]) => (
                                                                <div key={key}>
                                                                    <span className="text-gray-600 dark:text-gray-400">{key}:</span> {value}
                                                                </div>
                                                            ))}
                                                        </div>
                                                    </div>
                                                )}

                                                {log.raw_data && (
                                                    <div>
                                                        <h5 className="text-sm font-semibold text-gray-900 dark:text-white mb-1">
                                                            Raw Data
                                                        </h5>
                                                        <ReactJson
                                                            src={JSON.parse(log.raw_data)}
                                                            theme={jsonViewTheme}
                                                            collapsed={false}
                                                            displayDataTypes={false}
                                                            enableClipboard={true}
                                                            style={{
                                                                padding: '1rem',
                                                                borderRadius: '0.375rem',
                                                                backgroundColor: jsonViewTheme === 'pop' ? '#1C1B22' : '#f8f9fa',
                                                                maxHeight: '400px',
                                                                overflowY: 'auto'
                                                            }}
                                                        />
                                                    </div>
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

export default LogTable;