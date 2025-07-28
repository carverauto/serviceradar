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
import ReactJson from '@microlink/react-json-view';
import { Event } from '@/types/events';

interface EventTableProps {
    events: Event[];
    jsonViewTheme?: 'rjv-default' | 'pop';
    showSortHeaders?: boolean;
}

const EventTable: React.FC<EventTableProps> = ({ 
    events, 
    jsonViewTheme = 'pop',
    showSortHeaders = false
}) => {
    const [expandedRow, setExpandedRow] = useState<string | null>(null);

    const getSeverityBadge = (severity: string | undefined | null) => {
        const lowerSeverity = (severity || '').toLowerCase();

        switch (lowerSeverity) {
            case 'critical':
                return 'bg-red-100 dark:bg-red-600/50 text-red-800 dark:text-red-200 border border-red-300 dark:border-red-500/60';
            case 'high':
                return 'bg-orange-100 dark:bg-orange-500/50 text-orange-800 dark:text-orange-200 border border-orange-300 dark:border-orange-400/60';
            case 'medium':
                return 'bg-yellow-100 dark:bg-yellow-500/50 text-yellow-800 dark:text-yellow-200 border border-yellow-300 dark:border-yellow-400/60';
            case 'low':
                return 'bg-sky-100 dark:bg-sky-600/50 text-sky-800 dark:text-sky-200 border border-sky-300 dark:border-sky-500/60';
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

    if (!events || events.length === 0) {
        return (
            <div className="text-center p-8 text-gray-600 dark:text-gray-400">
                No events found.
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
                            Host
                        </th>
                        <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                            Message
                        </th>
                    </tr>
                </thead>
                <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                    {events.map(event => (
                        <Fragment key={event.id}>
                            <tr className="hover:bg-gray-100 dark:hover:bg-gray-700/30">
                                <td className="pl-4">
                                    <button
                                        onClick={() => setExpandedRow(expandedRow === event.id ? null : event.id)}
                                        className="p-1 rounded-full hover:bg-gray-200 dark:hover:bg-gray-600 text-gray-600 dark:text-gray-400"
                                    >
                                        {expandedRow === event.id ? (
                                            <ChevronDown className="h-5 w-5" />
                                        ) : (
                                            <ChevronRight className="h-5 w-5" />
                                        )}
                                    </button>
                                </td>
                                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300">
                                    {formatDate(event.event_timestamp)}
                                </td>
                                <td className="px-6 py-4 whitespace-nowrap">
                                    <span className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${getSeverityBadge(event.severity)}`}>
                                        {event.severity || 'Unknown'}
                                    </span>
                                </td>
                                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300">
                                    {event.host}
                                </td>
                                <td
                                    className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300 font-mono max-w-lg truncate"
                                    title={event.short_message}
                                >
                                    {event.short_message}
                                </td>
                            </tr>

                            {expandedRow === event.id && (
                                <tr className="bg-gray-100 dark:bg-gray-800/50">
                                    <td colSpan={5} className="p-0">
                                        <div className="p-4">
                                            <h4 className="text-md font-semibold text-gray-900 dark:text-white mb-2">
                                                Event Details
                                            </h4>
                                            <div className="grid grid-cols-2 gap-4 mb-4">
                                                <div>
                                                    <span className="text-sm text-gray-600 dark:text-gray-400">ID:</span>
                                                    <span className="text-sm text-gray-800 dark:text-gray-200 ml-2 font-mono">
                                                        {event.id}
                                                    </span>
                                                </div>
                                                <div>
                                                    <span className="text-sm text-gray-600 dark:text-gray-400">Type:</span>
                                                    <span className="text-sm text-gray-800 dark:text-gray-200 ml-2">
                                                        {event.type}
                                                    </span>
                                                </div>
                                                <div>
                                                    <span className="text-sm text-gray-600 dark:text-gray-400">Source:</span>
                                                    <span className="text-sm text-gray-800 dark:text-gray-200 ml-2">
                                                        {event.source}
                                                    </span>
                                                </div>
                                                <div>
                                                    <span className="text-sm text-gray-600 dark:text-gray-400">Remote Address:</span>
                                                    <span className="text-sm text-gray-800 dark:text-gray-200 ml-2">
                                                        {event.remote_addr}
                                                    </span>
                                                </div>
                                                <div>
                                                    <span className="text-sm text-gray-600 dark:text-gray-400">Level:</span>
                                                    <span className="text-sm text-gray-800 dark:text-gray-200 ml-2">
                                                        {event.level}
                                                    </span>
                                                </div>
                                                <div>
                                                    <span className="text-sm text-gray-600 dark:text-gray-400">Version:</span>
                                                    <span className="text-sm text-gray-800 dark:text-gray-200 ml-2">
                                                        {event.version}
                                                    </span>
                                                </div>
                                            </div>
                                            
                                            <h4 className="text-md font-semibold text-gray-900 dark:text-white mb-2">
                                                Raw Event Data
                                            </h4>
                                            <ReactJson
                                                src={JSON.parse(event.raw_data)}
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
                                    </td>
                                </tr>
                            )}
                        </Fragment>
                    ))}
                </tbody>
            </table>
        </div>
    );
};

export default EventTable;