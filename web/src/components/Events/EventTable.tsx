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
import { Event } from '@/types/events';
import { AliasMetadataSnapshot, extractAliasMetadata } from '@/lib/alias';

interface EventTableProps {
    events: Event[];
    jsonViewTheme?: 'rjv-default' | 'pop';
    showSortHeaders?: boolean;
}

const safeParseJSON = (raw: string): unknown => {
    try {
        return JSON.parse(raw);
    } catch {
        return null;
    }
};

const extractAliasEventDetails = (parsed: unknown): AliasMetadataSnapshot | null => {
    if (!parsed || typeof parsed !== 'object') {
        return null;
    }

    const payload = parsed as { type?: unknown; data?: unknown };
    const type = typeof payload.type === 'string' ? payload.type : '';

    if (type !== 'com.carverauto.serviceradar.device.lifecycle') {
        return null;
    }

    if (!payload.data || typeof payload.data !== 'object') {
        return null;
    }

    const data = payload.data as { action?: unknown; metadata?: unknown };
    const action = typeof data.action === 'string' ? data.action.toLowerCase() : '';

    if (action !== 'alias_updated') {
        return null;
    }

    const metadata = (data.metadata && typeof data.metadata === 'object' && data.metadata !== null)
        ? (data.metadata as Record<string, unknown>)
        : undefined;

    return extractAliasMetadata(metadata);
};

const formatRelativeTime = (value?: string): string => {
    if (!value) {
        return 'Unknown';
    }
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
        return 'Unknown';
    }

    const diffMs = date.getTime() - Date.now();
    const formatter = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });

    const seconds = Math.round(diffMs / 1000);
    if (Math.abs(seconds) < 60) {
        return formatter.format(seconds, 'second');
    }

    const minutes = Math.round(seconds / 60);
    if (Math.abs(minutes) < 60) {
        return formatter.format(minutes, 'minute');
    }

    const hours = Math.round(minutes / 60);
    if (Math.abs(hours) < 24) {
        return formatter.format(hours, 'hour');
    }

    const days = Math.round(hours / 24);
    if (Math.abs(days) < 30) {
        return formatter.format(days, 'day');
    }

    const months = Math.round(days / 30);
    if (Math.abs(months) < 12) {
        return formatter.format(months, 'month');
    }

    const years = Math.round(months / 12);
    return formatter.format(years, 'year');
};

const formatAbsoluteTime = (value?: string): string => {
    if (!value) {
        return 'Unknown';
    }
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
        return 'Unknown';
    }
    return date.toLocaleString();
};

const AliasSummaryCard = ({ label, value, previous }: { label: string; value?: string; previous?: string }) => {
    const currentValue = value && value.trim().length > 0 ? value : undefined;
    const previousValue = previous && previous.trim().length > 0 ? previous : undefined;

    let displayValue = currentValue ?? 'Unknown';
    let previousText: string | null = null;

    if (!currentValue && previousValue) {
        displayValue = 'Removed';
        previousText = `Previously ${previousValue}`;
    } else if (currentValue && previousValue && currentValue !== previousValue) {
        previousText = `Previously ${previousValue}`;
    }

    return (
        <div className="rounded-md bg-white dark:bg-gray-900/40 border border-indigo-100 dark:border-indigo-700/40 px-3 py-2">
            <p className="text-xs uppercase tracking-wide text-indigo-700 dark:text-indigo-300">{label}</p>
            <p className="text-sm font-medium text-indigo-900 dark:text-indigo-100 break-words">
                {displayValue}
            </p>
            {previousText && (
                <p className="text-xs text-indigo-700/80 dark:text-indigo-300/80 mt-1">
                    {previousText}
                </p>
            )}
        </div>
    );
};

const EventTable: React.FC<EventTableProps> = ({ 
    events, 
    jsonViewTheme = 'pop'
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
                            {(() => {
                                const parsedRawData = safeParseJSON(event.raw_data);
                                const aliasDetails = extractAliasEventDetails(parsedRawData);
                                const rawObject: Record<string, unknown> =
                                    (parsedRawData && typeof parsedRawData === 'object' && parsedRawData !== null)
                                        ? (parsedRawData as Record<string, unknown>)
                                        : { raw: event.raw_data };

                                return (
                                    <>
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
                                            {aliasDetails && (
                                                <div className="mb-6 rounded-lg border border-indigo-200 dark:border-indigo-700/40 bg-indigo-50/40 dark:bg-indigo-900/20 p-4">
                                                    <div className="flex flex-col md:flex-row md:items-center md:justify-between gap-3 mb-4">
                                                        <div>
                                                            <h4 className="text-md font-semibold text-indigo-900 dark:text-indigo-100">
                                                                Alias Change Detected
                                                            </h4>
                                                            {aliasDetails.lastSeenAt && (
                                                                <p className="text-xs text-indigo-800 dark:text-indigo-300">
                                                                    Last seen {formatRelativeTime(aliasDetails.lastSeenAt)} ({formatAbsoluteTime(aliasDetails.lastSeenAt)})
                                                                </p>
                                                            )}
                                                        </div>
                                                        <span className="self-start md:self-auto rounded-full border border-indigo-300 dark:border-indigo-600/60 bg-indigo-100 dark:bg-indigo-700/40 px-3 py-1 text-xs font-semibold text-indigo-800 dark:text-indigo-200">
                                                            alias_updated
                                                        </span>
                                                    </div>

                                                    <div className="grid gap-3 md:grid-cols-3">
                                                        <AliasSummaryCard
                                                            label="Current Service"
                                                            value={aliasDetails.currentServiceId}
                                                            previous={aliasDetails.previousServiceId}
                                                        />
                                                        <AliasSummaryCard
                                                            label="Current Host IP"
                                                            value={aliasDetails.currentIP}
                                                            previous={aliasDetails.previousIP}
                                                        />
                                                        <AliasSummaryCard
                                                            label="Collector IP"
                                                            value={aliasDetails.collectorIP}
                                                            previous={aliasDetails.previousCollectorIP}
                                                        />
                                                    </div>

                                                    {aliasDetails.services.length > 0 && (
                                                        <div className="mt-4">
                                                            <h5 className="text-xs font-semibold uppercase tracking-wide text-indigo-900 dark:text-indigo-100 mb-2">
                                                                Service History
                                                            </h5>
                                                            <ul className="divide-y divide-indigo-100 dark:divide-indigo-700/40 rounded-md border border-indigo-100 dark:border-indigo-700/40 bg-white dark:bg-indigo-900/10">
                                                                {aliasDetails.services.map((service, index) => {
                                                                    const hasTimestamp = Boolean(service.lastSeen);
                                                                    const label = service.id ?? 'Unknown';
                                                                    return (
                                                                        <li key={service.id ?? `service-${index}`} className="flex items-center justify-between px-3 py-2 text-sm">
                                                                            <span className="font-mono text-indigo-900 dark:text-indigo-100 truncate mr-4">
                                                                                {label}
                                                                            </span>
                                                                            <span className="text-xs text-indigo-700 dark:text-indigo-300 shrink-0">
                                                                                {hasTimestamp
                                                                                    ? `${formatRelativeTime(service.lastSeen)} (${formatAbsoluteTime(service.lastSeen)})`
                                                                                    : 'Unknown'}
                                                                            </span>
                                                                        </li>
                                                                    );
                                                                })}
                                                            </ul>
                                                        </div>
                                                    )}

                                                    {aliasDetails.ips.length > 0 && (
                                                        <div className="mt-4">
                                                            <h5 className="text-xs font-semibold uppercase tracking-wide text-indigo-900 dark:text-indigo-100 mb-2">
                                                                IP History
                                                            </h5>
                                                            <ul className="divide-y divide-indigo-100 dark:divide-indigo-700/40 rounded-md border border-indigo-100 dark:border-indigo-700/40 bg-white dark:bg-indigo-900/10">
                                                                {aliasDetails.ips.map((ipEntry, index) => {
                                                                    const hasTimestamp = Boolean(ipEntry.lastSeen);
                                                                    const ipLabel = ipEntry.ip ?? 'Unknown';
                                                                    return (
                                                                        <li key={ipEntry.ip ?? `ip-${index}`} className="flex items-center justify-between px-3 py-2 text-sm">
                                                                            <span className="font-mono text-indigo-900 dark:text-indigo-100 truncate mr-4">
                                                                                {ipLabel}
                                                                            </span>
                                                                            <span className="text-xs text-indigo-700 dark:text-indigo-300 shrink-0">
                                                                                {hasTimestamp
                                                                                    ? `${formatRelativeTime(ipEntry.lastSeen)} (${formatAbsoluteTime(ipEntry.lastSeen)})`
                                                                                    : 'Unknown'}
                                                                            </span>
                                                                        </li>
                                                                    );
                                                                })}
                                                            </ul>
                                                        </div>
                                                    )}
                                                </div>
                                            )}
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
                                                src={rawObject}
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
                                    </>
                                );
                            })()}
                        </Fragment>
                    ))}
                </tbody>
            </table>
        </div>
    );
};

export default EventTable;
