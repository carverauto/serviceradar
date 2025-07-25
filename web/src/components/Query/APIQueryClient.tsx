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

// src/components/ApiQueryClient.tsx
'use client';

import React, { useState, useCallback, useEffect } from 'react';
import { useSearchParams, useRouter } from 'next/navigation';
import {Loader2, AlertTriangle, Eye, EyeOff, FileJson, Table} from 'lucide-react';
import { useAuth } from '@/components/AuthProvider';
import ReactJson from '@microlink/react-json-view';
import { fetchAPI } from '@/lib/client-api';
import { Device } from '@/types/devices';
import DeviceTable from '@/components/Devices/DeviceTable';
import InterfaceTable, { NetworkInterface } from '@/components/Network/InterfaceTable';
import SweepResultsTable, { SweepResult } from '@/components/Network/SweepResultsTable';

type ViewFormat = 'json' | 'table';

interface ApiQueryClientProps {
    query: string;
}

const ApiQueryClient: React.FC<ApiQueryClientProps> = ({ query: initialQuery }) => {
    const searchParams = useSearchParams();
    const router = useRouter();
    const [results, setResults] = useState<unknown>(null);
    const [responseData, setResponseData] = useState<unknown>(null);
    const [pagination, setPagination] = useState<{
        next_cursor?: string;
        prev_cursor?: string;
        limit?: number;
    } | null>(null);
    const [limit, setLimit] = useState<number>(20);
    const [isLoading, setIsLoading] = useState<boolean>(false);
    const [error, setError] = useState<string | null>(null);
    const [viewFormat, setViewFormat] = useState<ViewFormat>('table');
    const [showRawJson, setShowRawJson] = useState<boolean>(false);
    const { token } = useAuth();
    
    // Derive query from URL params, falling back to initialQuery
    const query = searchParams.get('q') || initialQuery;


    const [jsonViewTheme, setJsonViewTheme] = useState<'rjv-default' | 'pop'>('rjv-default');

    const handleSubmit = useCallback(
        async (
            e?: React.FormEvent<HTMLFormElement>,
            cursorParam?: string,
            directionParam?: 'next' | 'prev',
            overrideQuery?: string
        ) => {
            if (e) e.preventDefault();
            const q = overrideQuery || query;
            if (!q.trim()) {
                setError('Query cannot be empty.');
                return;
            }

            setIsLoading(true);
            setError(null);
            setResults(null);
            setResponseData(null);

            try {
                const body: Record<string, unknown> = { query: q, limit };
                if (cursorParam) body.cursor = cursorParam;
                if (directionParam) body.direction = directionParam;

                const options: RequestInit = {
                    method: 'POST', // Explicitly set POST
                    headers: {
                        'Content-Type': 'application/json',
                        ...(token ? { Authorization: `Bearer ${token}` } : {}),
                    },
                    body: JSON.stringify(body),
                    cache: 'no-store' as RequestCache,
                    credentials: 'include',
                };

                // Add timeout to prevent hanging requests
                const timeoutPromise = new Promise((_, reject) => {
                    setTimeout(() => reject(new Error('Request timeout after 30 seconds')), 30000);
                });
                
                const data: unknown = await Promise.race([
                    fetchAPI('/query', options),
                    timeoutPromise
                ]);

                setResponseData(data);
                if (data && typeof data === 'object' && 'results' in data) {
                    const d = data as { results: unknown; pagination?: { next_cursor?: string; prev_cursor?: string; limit?: number; } };
                    setResults(d.results);
                    setPagination(d.pagination ?? null);
                    
                } else {
                    setResults(data);
                    setPagination(null);
                }
            } catch (err) {
                console.error('Query execution error:', err);
                setError(
                    err instanceof Error
                        ? err.message
                        : 'An unknown error occurred while executing the query.'
                );
                setResults(null);
                setResponseData(null);
                setPagination(null);
            } finally {
                setIsLoading(false);
            }
        },
        [query, token, limit]
    );

    // Run query on mount if we have one
    useEffect(() => {
        if (query) {
            handleSubmit(undefined, undefined, undefined, query);
        }
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []); // Only run on mount - we intentionally don't want to re-run when query changes

    useEffect(() => {
        const updateTheme = () => {
            if (document.documentElement.classList.contains('dark')) {
                setJsonViewTheme('pop');
            } else {
                setJsonViewTheme('rjv-default');
            }
        };
        updateTheme();
        const observer = new MutationObserver((mutationsList) => {
            for (const mutation of mutationsList) {
                if (mutation.type === 'attributes' && mutation.attributeName === 'class') {
                    updateTheme();
                }
            }
        });
        observer.observe(document.documentElement, { attributes: true });
        return () => observer.disconnect();
    }, []);



    const isDeviceQuery = (query: string): boolean => {
        const normalizedQuery = query.trim().toUpperCase();
        return normalizedQuery.startsWith('SHOW DEVICES') || 
               normalizedQuery.startsWith('FIND DEVICES') ||
               normalizedQuery.startsWith('COUNT DEVICES');
    };

    const isInterfaceQuery = (query: string): boolean => {
        const normalizedQuery = query.trim().toUpperCase();
        return normalizedQuery.startsWith('SHOW INTERFACES') || 
               normalizedQuery.startsWith('FIND INTERFACES') ||
               normalizedQuery.startsWith('COUNT INTERFACES');
    };

    const isSweepQuery = (query: string): boolean => {
        const normalizedQuery = query.trim().toUpperCase();
        return normalizedQuery.startsWith('SHOW SWEEP') || 
               normalizedQuery.startsWith('FIND SWEEP') ||
               normalizedQuery.startsWith('COUNT SWEEP');
    };


    const isDeviceData = (data: unknown): data is Device[] => {
        if (!Array.isArray(data) || data.length === 0) return false;
        const firstItem = data[0];
        return (
            typeof firstItem === 'object' &&
            firstItem !== null &&
            'device_id' in firstItem &&
            'ip' in firstItem &&
            'discovery_sources' in firstItem
        );
    };

    const isInterfaceData = (data: unknown): data is NetworkInterface[] => {
        if (!Array.isArray(data) || data.length === 0) return false;
        const firstItem = data[0];
        return (
            typeof firstItem === 'object' &&
            firstItem !== null &&
            (
                // Snake_case properties (from LAN Discovery)
                'if_index' in firstItem ||
                'if_name' in firstItem ||
                'if_descr' in firstItem ||
                // CamelCase properties (from SHOW INTERFACES query)
                'ifIndex' in firstItem ||
                'ifName' in firstItem ||
                'ifDescr' in firstItem ||
                // Generic interface patterns
                ('name' in firstItem && ('ip_address' in firstItem || 'mac_address' in firstItem))
            )
        );
    };

    const isSweepData = (data: unknown): data is SweepResult[] => {
        if (!Array.isArray(data) || data.length === 0) return false;
        const firstItem = data[0];
        return (
            typeof firstItem === 'object' &&
            firstItem !== null &&
            'available' in firstItem &&
            'discovery_source' in firstItem &&
            'ip' in firstItem &&
            'timestamp' in firstItem
        );
    };

    const renderResultsTable = (data: unknown) => {
        if (data === null || typeof data === 'undefined')
            return <p className="text-gray-500 dark:text-gray-400">No data to display.</p>;

        if (typeof data !== 'object' && !Array.isArray(data)) {
            return (
                <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                    <thead className="bg-gray-50 dark:bg-gray-700">
                    <tr>
                        <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                            Value
                        </th>
                    </tr>
                    </thead>
                    <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                    <tr>
                        <td className="px-6 py-4 whitespace-pre-wrap break-all text-sm text-gray-900 dark:text-gray-100">
                            {String(data)}
                        </td>
                    </tr>
                    </tbody>
                </table>
            );
        }

        let dataArray: unknown[];
        if (Array.isArray(data)) {
            dataArray = data;
        } else if (typeof data === 'object') {
            dataArray = [data];
        } else {
            return (
                <p className="text-gray-500 dark:text-gray-400">
                    Cannot render this data type as table.
                </p>
            );
        }

        if (dataArray.length === 0) {
            return (
                <p className="text-gray-500 dark:text-gray-400">
                    Query returned no results or an empty structure.
                </p>
            );
        }

        if (dataArray.every((item) => typeof item !== 'object' || item === null)) {
            return (
                <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                    <thead className="bg-gray-50 dark:bg-gray-700">
                    <tr>
                        <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                            Value
                        </th>
                    </tr>
                    </thead>
                    <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                    {dataArray.map((item, index) => (
                        <tr key={index}>
                            <td className="px-6 py-4 whitespace-pre-wrap break-all text-sm text-gray-900 dark:text-gray-100">
                                {String(item)}
                            </td>
                        </tr>
                    ))}
                    </tbody>
                </table>
            );
        }

        const firstItem = dataArray[0];
        if (typeof firstItem !== 'object' || firstItem === null) {
            return (
                <p className="text-gray-500 dark:text-gray-400">
                    Table view expects an array of objects or a single object. Data structure is
                    mixed or starts with a non-object. Try JSON view.
                </p>
            );
        }
        const headers = Object.keys(firstItem);

        return (
            <div className="overflow-x-auto">
                <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                    <thead className="bg-gray-50 dark:bg-gray-700">
                    <tr>
                        {headers.map((header) => (
                            <th
                                key={header}
                                scope="col"
                                className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider"
                            >
                                {header}
                            </th>
                        ))}
                    </tr>
                    </thead>
                    <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                    {dataArray.map((row, rowIndex) => (
                        <tr
                            key={rowIndex}
                            className="hover:bg-gray-50 dark:hover:bg-gray-700/50"
                        >
                            {headers.map((header) => {
                                const cellValue =
                                    typeof row === 'object' && row !== null
                                        ? (row as Record<string, unknown>)[header]
                                        : undefined;
                                return (
                                    <td
                                        key={`${rowIndex}-${header}`}
                                        className="px-6 py-4 whitespace-pre-wrap break-all text-sm text-gray-900 dark:text-gray-100"
                                    >
                                        {typeof cellValue === 'object'
                                            ? JSON.stringify(cellValue)
                                            : String(cellValue ?? '')}
                                    </td>
                                );
                            })}
                        </tr>
                    ))}
                    </tbody>
                </table>
            </div>
        );
    };

    const exampleQueries = [
        {
            name: 'All Devices',
            query: 'show devices',
        },
        {
            name: 'Test Query',
            query: 'show pollers',
        },
        {
            name: 'All Interfaces',
            query: 'show interfaces',
        },
        {
            name: 'Critical Traps Today',
            query: 'show traps where severity = "critical" and date(timestamp) = TODAY',
        },
        {
            name: 'High Traffic Flows',
            query: 'find flows where bytes > 1000000 order by bytes desc limit 10',
        },
        {
            name: 'Latest Device Updates',
            query: 'show devices',
        },
    ];

    return (
        <div className="space-y-4">
            {/* Show example queries only when no query has been executed yet */}
            {!responseData && !isLoading && !error && (
                <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 p-4 rounded-lg">
                    <h3 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-3">Try these example queries:</h3>
                    <div className="flex flex-wrap gap-2">
                        {exampleQueries.map((eg) => (
                            <button
                                key={eg.name}
                                onClick={() => {
                                    router.push(`/query?q=${encodeURIComponent(eg.query)}`);
                                }}
                                className="px-3 py-1 text-xs bg-gray-200 dark:bg-gray-700/50 text-gray-700 dark:text-gray-300 rounded-full hover:bg-gray-300 dark:hover:bg-gray-600/50 transition-colors"
                            >
                                {eg.name}
                            </button>
                        ))}
                    </div>
                </div>
            )}

            {error && (
                <div className="bg-red-900/20 border border-red-500/30 p-4 rounded-lg shadow flex items-start">
                    <AlertTriangle className="h-5 w-5 text-red-500 mr-3 flex-shrink-0" />
                    <div>
                        <h3 className="text-md font-semibold text-red-700 dark:text-red-400">
                            Error
                        </h3>
                        <p className="text-sm text-red-600 dark:text-red-300 mt-1 whitespace-pre-wrap">
                            {error}
                        </p>
                    </div>
                </div>
            )}

            {isLoading && !responseData && (
                <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 p-4 rounded-lg text-center">
                    <div className="flex items-center justify-center gap-2">
                        <Loader2 className="animate-spin h-5 w-5 text-green-400" />
                        <span className="text-sm text-gray-600 dark:text-gray-400">Fetching results...</span>
                    </div>
                </div>
            )}

            {responseData !== null && !isLoading && (
                <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg shadow-lg">
                    <div className="p-4 border-b border-gray-200 dark:border-gray-700 flex flex-wrap justify-between items-center gap-4">
                        <div className="flex items-center gap-4">
                            <h3 className="text-lg font-semibold text-gray-900 dark:text-white">Results</h3>
                            {query && (
                                <code className="text-xs bg-gray-200 dark:bg-gray-700 px-2 py-1 rounded text-gray-700 dark:text-gray-300">{query}</code>
                            )}
                        </div>
                        <div className="flex items-center gap-2">
                            {/* View Format Toggle */}
                            <div className="flex items-center rounded-md border border-gray-300 dark:border-gray-600 bg-gray-100 dark:bg-gray-900">
                                <button type="button" onClick={() => setViewFormat('json')} className={`px-2 py-1 text-xs rounded-l-md flex items-center gap-1 ${viewFormat === 'json' ? 'bg-green-600 text-white' : 'text-gray-700 dark:text-gray-400 hover:bg-gray-200 dark:hover:bg-gray-700'}`}>
                                    <FileJson size={14} /> JSON
                                </button>
                                <button type="button" onClick={() => setViewFormat('table')} className={`px-2 py-1 text-xs rounded-r-md flex items-center gap-1 ${viewFormat === 'table' ? 'bg-green-600 text-white' : 'text-gray-700 dark:text-gray-400 hover:bg-gray-200 dark:hover:bg-gray-700'}`}>
                                    <Table size={14} /> Table
                                </button>
                            </div>
                            
                            {/* JSON View Toggle */}
                            {viewFormat === 'json' && (
                                <button type="button" onClick={() => setShowRawJson(!showRawJson)} title={showRawJson ? 'Show Rich JSON View' : 'Show Raw JSON'} className="p-1.5 rounded-md hover:bg-gray-200 dark:hover:bg-gray-700 text-gray-700 dark:text-gray-400">
                                    {showRawJson ? <Eye className="h-4 w-4" /> : <EyeOff className="h-4 w-4" />}
                                </button>
                            )}
                            
                            {/* Limit Selector */}
                            <select
                                value={limit}
                                onChange={(e) => {
                                    setLimit(Number(e.target.value));
                                    setPagination(null);
                                }}
                                className="px-2 py-1 text-xs border border-gray-300 dark:border-gray-600 rounded-md bg-gray-100 dark:bg-gray-900 text-gray-900 dark:text-gray-100 focus:ring-green-500 focus:border-green-500"
                            >
                                {[20, 50, 100, 200].map((val) => (
                                    <option key={val} value={val}>{val}</option>
                                ))}
                            </select>
                        </div>
                    </div>
                    <div className="p-4">
                        {viewFormat === 'json' ? (
                            showRawJson ? (
                                <pre className="bg-gray-100 dark:bg-gray-900 p-4 rounded-md overflow-auto text-sm text-gray-800 dark:text-gray-200 max-h-[600px]">
                                {JSON.stringify(responseData, null, 2)}
                            </pre>
                            ) : typeof responseData !== 'undefined' ? (
                                <ReactJson
                                    src={
                                        typeof responseData === 'object' && responseData !== null
                                            ? responseData
                                            : { value: responseData }
                                    }
                                    theme={jsonViewTheme}
                                    collapsed={false}
                                    displayDataTypes={false}
                                    enableClipboard={true}
                                    style={{
                                        padding: '1rem',
                                        borderRadius: '0.375rem',
                                        maxHeight: '600px',
                                        overflowY: 'auto',
                                    }}
                                />
                            ) : (
                                <p className="text-gray-500 dark:text-gray-400">
                                    No data to display in JSON format.
                                </p>
                            )
                        ) : (
                            /* Table view - use specialized components when available */
                            isDeviceQuery(query) && isDeviceData(results) ? (
                                <DeviceTable devices={results as Device[]} />
                            ) : isInterfaceQuery(query) && isInterfaceData(results) ? (
                                <InterfaceTable interfaces={results as NetworkInterface[]} showDeviceColumn={true} jsonViewTheme={jsonViewTheme} />
                            ) : isSweepQuery(query) && isSweepData(results) ? (
                                <SweepResultsTable sweepResults={results as SweepResult[]} showPollerColumn={true} showPartitionColumn={true} jsonViewTheme={jsonViewTheme} />
                            ) : (
                                /* Fallback to generic table */
                                renderResultsTable(results)
                            )
                        )}

                        {pagination && (pagination.prev_cursor || pagination.next_cursor) && (
                            <div className="flex justify-between items-center pt-4 border-t border-gray-200 dark:border-gray-700">
                                <button
                                    onClick={() => handleSubmit(undefined, pagination.prev_cursor, 'prev')}
                                    disabled={!pagination.prev_cursor}
                                    className="px-3 py-1 rounded bg-gray-200 dark:bg-gray-700 text-gray-700 dark:text-gray-200 disabled:opacity-50 disabled:cursor-not-allowed"
                                >
                                    Previous
                                </button>
                                <button
                                    onClick={() => handleSubmit(undefined, pagination.next_cursor, 'next')}
                                    disabled={!pagination.next_cursor}
                                    className="px-3 py-1 rounded bg-gray-200 dark:bg-gray-700 text-gray-700 dark:text-gray-200 disabled:opacity-50 disabled:cursor-not-allowed"
                                >
                                    Next
                                </button>
                            </div>
                        )}
                    </div>
                </div>
            )}
        </div>
    );
};

export default ApiQueryClient;