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
import { Loader2, Send, AlertTriangle, Eye, EyeOff, FileJson, Table } from 'lucide-react';
import { useAuth } from '@/components/AuthProvider';
import ReactJson from '@microlink/react-json-view';
import { fetchAPI } from '@/lib/client-api';

type ViewFormat = 'json' | 'table';

const ApiQueryClient: React.FC = () => {
    const [query, setQuery] = useState<string>('');
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
    const [viewFormat, setViewFormat] = useState<ViewFormat>('json');
    const [showRawJson, setShowRawJson] = useState<boolean>(false);
    const { token } = useAuth();

    const [jsonViewTheme, setJsonViewTheme] = useState<'rjv-default' | 'pop'>('rjv-default');

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

    const handleSubmit = useCallback(
        async (
            e?: React.FormEvent<HTMLFormElement>,
            cursorParam?: string,
            directionParam?: 'next' | 'prev'
        ) => {
            if (e) e.preventDefault();
            if (!query.trim()) {
                setError('Query cannot be empty.');
                return;
            }

            setIsLoading(true);
            setError(null);
            setResults(null);
            setResponseData(null);

            try {
                const body: Record<string, unknown> = { query, limit };
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

                const data = await fetchAPI('/query', options);

                setResponseData(data);
                if (data && typeof data === 'object' && 'results' in data) {
                    // eslint-disable-next-line @typescript-eslint/no-explicit-any
                    const d = data as any;
                    setResults(d.results);
                    setPagination(d.pagination ?? null);
                } else {
                    setResults(data);
                    setPagination(null);
                }
            } catch (err) {
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
            name: 'Critical Traps Today',
            query: 'show traps where severity = "critical" and date(timestamp) = TODAY',
        },
        {
            name: 'High Traffic Flows',
            query: 'find flows where bytes > 1000000 order by bytes desc limit 10',
        },
        {
            name: 'Latest Sweep Results',
            query: 'show sweep_results',
        },
    ];

    return (
        <div className="space-y-6">
            <div className="bg-[#25252e] border border-gray-700 p-6 rounded-lg shadow-lg">
                <h2 className="text-xl font-bold text-white mb-4">
                    API Query Tool
                </h2>
                <form onSubmit={handleSubmit} className="space-y-4">
                    <div>
                        <label
                            htmlFor="query"
                            className="block text-sm font-medium text-gray-300 mb-2"
                        >
                            Enter your ServiceRadar Query Language (SRQL) query:
                        </label>
                        <textarea
                            id="query"
                            name="query"
                            rows={5}
                            className="w-full p-3 font-mono text-sm border border-gray-600 rounded-md shadow-sm focus:ring-violet-500 focus:border-violet-500 bg-[#16151c] text-gray-100 placeholder-gray-500"
                            placeholder="e.g., show devices where status = 'offline'"
                            value={query}
                            onChange={(e) => setQuery(e.target.value)}
                        />
                    </div>

                    <div className="flex flex-wrap justify-between items-center gap-4 pt-4 border-t border-gray-700">
                        <div className="flex items-center space-x-2">
                            <label
                                htmlFor="viewFormat"
                                className="text-sm font-medium text-gray-300"
                            >
                                View as:
                            </label>
                            <div className="flex items-center rounded-md border border-gray-600 bg-[#16151c]">
                                <button type="button" onClick={() => setViewFormat('json')} className={`px-3 py-1.5 rounded-l-md flex items-center gap-2 ${viewFormat === 'json' ? 'bg-violet-600 text-white' : 'text-gray-400 hover:bg-gray-700'}`}>
                                    <FileJson size={16} /> JSON
                                </button>
                                <button type="button" onClick={() => setViewFormat('table')} className={`px-3 py-1.5 rounded-r-md flex items-center gap-2 ${viewFormat === 'table' ? 'bg-violet-600 text-white' : 'text-gray-400 hover:bg-gray-700'}`}>
                                    <Table size={16} /> Table
                                </button>
                            </div>
                        </div>
                        <div className="flex items-center space-x-2">
                            <label
                                htmlFor="limit"
                                className="text-sm font-medium text-gray-300"
                            >
                                Limit:
                            </label>
                            <select
                                id="limit"
                                value={limit}
                                onChange={(e) => {
                                    setLimit(Number(e.target.value));
                                    setPagination(null); // Reset pagination on limit change
                                }}
                                className="px-3 py-2 border border-gray-600 rounded-md shadow-sm bg-[#16151c] text-gray-100 focus:ring-violet-500 focus:border-violet-500"
                            >
                                {[20, 50, 100, 200].map((val) => (
                                    <option key={val} value={val}>
                                        {val}
                                    </option>
                                ))}
                            </select>
                        </div>
                        <button
                            type="submit"
                            disabled={isLoading}
                            className="w-full sm:w-auto px-6 py-2 bg-violet-600 text-white font-semibold rounded-md shadow-sm hover:bg-violet-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-violet-500 disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center"
                        >
                            {isLoading ? (
                                <>
                                    <Loader2 className="animate-spin h-5 w-5 mr-2" />
                                    Executing...
                                </>
                            ) : (
                                <>
                                    <Send className="h-5 w-5 mr-2" />
                                    Execute Query
                                </>
                            )}
                        </button>
                    </div>
                </form>
            </div>

            <div className="bg-[#25252e] border border-gray-700 p-4 rounded-lg shadow-lg">
                <h3 className="text-md font-semibold text-gray-200 mb-3">Example Queries</h3>
                <div className="flex flex-wrap gap-2">
                    {exampleQueries.map((eg) => (
                        <button
                            key={eg.name}
                            onClick={() => setQuery(eg.query)}
                            disabled={isLoading}
                            className="px-3 py-1 text-xs bg-gray-700/50 text-gray-300 rounded-full hover:bg-gray-600/50 disabled:opacity-50"
                        >
                            {eg.name}
                        </button>
                    ))}
                </div>
            </div>

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
                <div className="bg-[#25252e] border border-gray-700 p-6 rounded-lg shadow text-center">
                    <Loader2 className="animate-spin h-8 w-8 text-violet-400 mx-auto mb-2" />
                    <p className="text-gray-600 dark:text-gray-400">Fetching results...</p>
                </div>
            )}

            {responseData !== null && !isLoading && (
                <div className="bg-[#25252e] border border-gray-700 rounded-lg shadow-lg">
                    <div className="p-4 border-b border-gray-700 flex justify-between items-center">
                        <h3 className="text-lg font-semibold text-white">Results</h3>
                        {viewFormat === 'json' && (
                            <button type="button" onClick={() => setShowRawJson(!showRawJson)} title={showRawJson ? 'Show Rich JSON View' : 'Show Raw JSON'} className="p-2 rounded-md hover:bg-gray-700 text-gray-400">
                                {showRawJson ? <Eye className="h-5 w-5" /> : <EyeOff className="h-5 w-5" />}
                            </button>
                        )}
                    </div>
                    <div className="p-4">
                        {viewFormat === 'json' ? (
                            showRawJson ? (
                                <pre className="bg-[#16151c] p-4 rounded-md overflow-auto text-sm text-gray-200 max-h-[600px]">
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
                            renderResultsTable(results)
                        )}

                        {pagination && (pagination.prev_cursor || pagination.next_cursor) && (
                            <div className="flex justify-between items-center pt-4 border-t border-gray-700">
                                <button
                                    onClick={() => handleSubmit(undefined, pagination.prev_cursor, 'prev')}
                                    disabled={!pagination.prev_cursor}
                                    className="px-3 py-1 rounded bg-gray-700 text-gray-200 disabled:opacity-50 disabled:cursor-not-allowed"
                                >
                                    Previous
                                </button>
                                <button
                                    onClick={() => handleSubmit(undefined, pagination.next_cursor, 'next')}
                                    disabled={!pagination.next_cursor}
                                    className="px-3 py-1 rounded bg-gray-700 text-gray-200 disabled:opacity-50 disabled:cursor-not-allowed"
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