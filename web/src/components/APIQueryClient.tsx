// src/components/ApiQueryClient.tsx
'use client';

import React, { useState, useCallback, useEffect } from 'react';
import { Loader2, Send, AlertTriangle, Eye, EyeOff } from 'lucide-react';
import { useAuth } from '@/components/AuthProvider';
import ReactJson from "@microlink/react-json-view";


type ViewFormat = 'json' | 'table';

const ApiQueryClient: React.FC = () => {
    const [query, setQuery] = useState<string>('');
    const [results, setResults] = useState<unknown>(null);
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


    const handleSubmit = useCallback(async (e?: React.FormEvent<HTMLFormElement>) => {
        if (e) e.preventDefault();
        if (!query.trim()) {
            setError("Query cannot be empty.");
            return;
        }

        setIsLoading(true);
        setError(null);
        setResults(null);

        try {
            const headers: HeadersInit = {
                'Content-Type': 'application/json',
            };
            if (token) {
                headers['Authorization'] = `Bearer ${token}`;
            }

            const response = await fetch('/api/query', {
                method: 'POST',
                headers,
                body: JSON.stringify({ query }),
            });

            const data = await response.json();

            if (!response.ok) {
                throw new Error(data.error || `Request failed with status ${response.status}`);
            }
            setResults(data);
        } catch (err) {
            console.error('Query submission error:', err);
            setError(err instanceof Error ? err.message : 'An unknown error occurred.');
            setResults(null);
        } finally {
            setIsLoading(false);
        }
    }, [query, token]);

    const renderResultsTable = (data: unknown) => {
        if (data === null || typeof data === 'undefined') return <p className="text-gray-500 dark:text-gray-400">No data to display.</p>;

        // If data is a primitive type (not an array or object), display it directly.
        if (typeof data !== 'object' && !Array.isArray(data)) {
            return (
                <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                    <thead className="bg-gray-50 dark:bg-gray-700">
                    <tr><th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">Value</th></tr>
                    </thead>
                    <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                    <tr><td className="px-6 py-4 whitespace-pre-wrap break-all text-sm text-gray-900 dark:text-gray-100">{String(data)}</td></tr>
                    </tbody>
                </table>
            );
        }

        let dataArray: unknown[];
        if (Array.isArray(data)) {
            dataArray = data;
        } else if (typeof data === 'object' && data !== null) { // data is a non-null object
            dataArray = [data];
        } else { // Should not be reached if primitive check above is exhaustive
            return <p className="text-gray-500 dark:text-gray-400">Cannot render this data type as table.</p>;
        }


        if (dataArray.length === 0) {
            return <p className="text-gray-500 dark:text-gray-400">Query returned no results or an empty structure.</p>;
        }

        if (dataArray.every(item => typeof item !== 'object' || item === null)) {
            return (
                <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                    <thead className="bg-gray-50 dark:bg-gray-700">
                    <tr><th className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">Value</th></tr>
                    </thead>
                    <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                    {dataArray.map((item, index) => (
                        <tr key={index}><td className="px-6 py-4 whitespace-pre-wrap break-all text-sm text-gray-900 dark:text-gray-100">{String(item)}</td></tr>
                    ))}
                    </tbody>
                </table>
            );
        }

        const firstItem = dataArray[0];
        if (typeof firstItem !== 'object' || firstItem === null) {
            return <p className="text-gray-500 dark:text-gray-400">Table view expects an array of objects or a single object. Data structure is mixed or starts with a non-object. Try JSON view.</p>;
        }
        const headers = Object.keys(firstItem);

        return (
            <div className="overflow-x-auto">
                <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                    <thead className="bg-gray-50 dark:bg-gray-700">
                    <tr>
                        {headers.map((header) => (
                            <th key={header} scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider">
                                {header}
                            </th>
                        ))}
                    </tr>
                    </thead>
                    <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                    {dataArray.map((row, rowIndex) => (
                        <tr key={rowIndex} className="hover:bg-gray-50 dark:hover:bg-gray-700/50">
                            {headers.map((header) => {
                                const cellValue = (typeof row === 'object' && row !== null) ? (row as Record<string,unknown>)[header] : undefined;
                                return (
                                    <td key={`${rowIndex}-${header}`} className="px-6 py-4 whitespace-pre-wrap break-all text-sm text-gray-900 dark:text-gray-100">
                                        {typeof cellValue === 'object' ? JSON.stringify(cellValue) : String(cellValue ?? '')}
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
        { name: "All Services", query: "SELECT * FROM services" },
        { name: "Offline Services", query: "SELECT name, type, status FROM services WHERE available = false" },
        { name: "Pollers Health", query: "SELECT poller_id, is_healthy, last_update FROM pollers" },
        { name: "Specific Poller", query: "SELECT * FROM pollers WHERE poller_id = 'poller-01'" },
    ];


    return (
        <div className="space-y-6">
            <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
                <h2 className="text-xl font-semibold text-gray-900 dark:text-white mb-4">API Query Tool</h2>
                <form onSubmit={handleSubmit} className="space-y-4">
                    <div>
                        <label htmlFor="query" className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                            Enter your query:
                        </label>
                        <textarea
                            id="query"
                            name="query"
                            rows={5}
                            className="w-full p-3 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm focus:ring-blue-500 focus:border-blue-500 bg-gray-50 dark:bg-gray-700 text-gray-900 dark:text-gray-100 placeholder-gray-400 dark:placeholder-gray-500"
                            placeholder="e.g., SELECT * FROM services WHERE status = 'critical'"
                            value={query}
                            onChange={(e) => setQuery(e.target.value)}
                        />
                    </div>

                    <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
                        <div className="flex items-center space-x-2">
                            <label htmlFor="viewFormat" className="text-sm font-medium text-gray-700 dark:text-gray-300">
                                View as:
                            </label>
                            <select
                                id="viewFormat"
                                value={viewFormat}
                                onChange={(e) => setViewFormat(e.target.value as ViewFormat)}
                                className="px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm bg-white dark:bg-gray-700 text-gray-900 dark:text-gray-100 focus:ring-blue-500 focus:border-blue-500"
                            >
                                <option value="json">JSON</option>
                                <option value="table">Table</option>
                            </select>
                            {viewFormat === 'json' && Boolean(results) && ( /* Changed here */
                                <button
                                    type="button"
                                    onClick={() => setShowRawJson(!showRawJson)}
                                    title={showRawJson ? "Show Rich JSON View" : "Show Raw JSON"}
                                    className="p-2 border border-gray-300 dark:border-gray-600 rounded-md shadow-sm bg-white dark:bg-gray-700 text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-600"
                                >
                                    {showRawJson ? <Eye className="h-5 w-5" /> : <EyeOff className="h-5 w-5" />}
                                </button>
                            )}
                        </div>
                        <button
                            type="submit"
                            disabled={isLoading}
                            className="w-full sm:w-auto px-6 py-2.5 bg-blue-600 text-white font-medium rounded-md shadow-sm hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500 disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center"
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
                <div className="mt-4">
                    <p className="text-sm text-gray-600 dark:text-gray-400 mb-1">Example Queries:</p>
                    <div className="flex flex-wrap gap-2">
                        {exampleQueries.map(eg => (
                            <button
                                key={eg.name}
                                onClick={() => { setQuery(eg.query); handleSubmit(); }}
                                disabled={isLoading}
                                className="px-3 py-1 text-xs bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 rounded-full hover:bg-gray-200 dark:hover:bg-gray-600 disabled:opacity-50"
                            >
                                {eg.name}
                            </button>
                        ))}
                    </div>
                </div>
            </div>

            {error && (
                <div className="bg-red-50 dark:bg-red-900/20 p-4 rounded-lg shadow flex items-start">
                    <AlertTriangle className="h-5 w-5 text-red-500 mr-3 flex-shrink-0" />
                    <div>
                        <h3 className="text-md font-semibold text-red-700 dark:text-red-400">Error</h3>
                        <p className="text-sm text-red-600 dark:text-red-300 mt-1 whitespace-pre-wrap">{error}</p>
                    </div>
                </div>
            )}

            {isLoading && !results && (
                <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow text-center">
                    <Loader2 className="animate-spin h-8 w-8 text-blue-600 dark:text-blue-400 mx-auto mb-2" />
                    <p className="text-gray-600 dark:text-gray-400">Fetching results...</p>
                </div>
            )}

            {results !== null && !isLoading && (
                <div className="bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
                    <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Results</h3>
                    {viewFormat === 'json' ? (
                        showRawJson ? (
                            <pre className="bg-gray-50 dark:bg-gray-900 p-4 rounded-md overflow-auto text-sm text-gray-800 dark:text-gray-200 max-h-[600px]">
                                {JSON.stringify(results, null, 2)}
                            </pre>
                        ) : (
                            typeof results !== 'undefined' ? (
                                <ReactJson
                                    src={typeof results === 'object' && results !== null ? results : { value: results }}
                                    theme={jsonViewTheme}
                                    collapsed={false}
                                    displayDataTypes={false}
                                    enableClipboard={true}
                                    style={{ padding: '1rem', borderRadius: '0.375rem', maxHeight: '600px', overflowY: 'auto' }}
                                />
                            ) : <p className="text-gray-500 dark:text-gray-400">No data to display in JSON format.</p>
                        )
                    ) : (
                        renderResultsTable(results)
                    )}
                </div>
            )}
        </div>
    );
};

export default ApiQueryClient;