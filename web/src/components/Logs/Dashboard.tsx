'use client';

import React, { useState, useEffect, useCallback, Fragment } from 'react';
import { useAuth } from '@/components/AuthProvider';
import { Log, Pagination, LogsApiResponse, SortableLogKeys } from '@/types/logs';
import {
    FileText,
    AlertCircle,
    AlertTriangle as AlertTriangleIcon,
    ChevronDown,
    ChevronRight,
    Search,
    Loader2,
    ArrowUp,
    ArrowDown,
    Activity,
    Info,
    AlertOctagon
} from 'lucide-react';
import ReactJson from '@microlink/react-json-view';
import { useDebounce } from 'use-debounce';
import { cachedQuery } from '@/lib/cached-query';

const StatCard = ({
    title,
    value,
    icon,
    isLoading
}: {
    title: string;
    value: string | number;
    icon: React.ReactNode;
    isLoading: boolean
}) => (
    <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 p-4 rounded-lg">
        <div className="flex items-center">
            <div className="p-2 bg-orange-100 dark:bg-gray-700/50 rounded-md mr-4 text-orange-600 dark:text-orange-400">
                {icon}
            </div>
            <div>
                <p className="text-sm text-gray-600 dark:text-gray-400">{title}</p>
                {isLoading ? (
                    <div className="h-7 w-20 bg-gray-200 dark:bg-gray-700 rounded-md animate-pulse mt-1"></div>
                ) : (
                    <p className="text-2xl font-bold text-gray-900 dark:text-white">{value}</p>
                )}
            </div>
        </div>
    </div>
);

const LogsDashboard = () => {
    const { token } = useAuth();
    const [logs, setLogs] = useState<Log[]>([]);
    const [pagination, setPagination] = useState<Pagination | null>(null);
    const [stats, setStats] = useState({
        total: 0,
        error: 0,
        warning: 0,
        info: 0
    });
    const [statsLoading, setStatsLoading] = useState(true);
    const [logsLoading, setLogsLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);
    const [searchTerm, setSearchTerm] = useState('');
    const [debouncedSearchTerm] = useDebounce(searchTerm, 300);
    const [filterSeverity, setFilterSeverity] = useState<'all' | 'ERROR' | 'WARN' | 'INFO' | 'DEBUG'>('all');
    const [filterService, setFilterService] = useState<string>('all');
    const [services, setServices] = useState<string[]>([]);
    const [sortBy, setSortBy] = useState<SortableLogKeys>('timestamp');
    const [sortOrder, setSortOrder] = useState<'asc' | 'desc'>('desc');
    const [expandedRow, setExpandedRow] = useState<string | null>(null);

    const postQuery = useCallback(async <T,>(
        query: string,
        cursor?: string,
        direction?: 'next' | 'prev'
    ): Promise<T> => {
        const body: Record<string, unknown> = {
            query,
            limit: 20
        };

        if (cursor) body.cursor = cursor;
        if (direction) body.direction = direction;

        const response = await fetch('/api/query', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                ...(token && { Authorization: `Bearer ${token}` })
            },
            body: JSON.stringify(body),
            cache: 'no-store',
        });

        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.error || 'Failed to execute query');
        }

        return response.json();
    }, [token]);

    const fetchStats = useCallback(async () => {
        setStatsLoading(true);

        try {
            // Use cached queries to prevent duplicates
            const [totalRes, errorRes, warnRes, infoRes] = await Promise.all([
                cachedQuery<{ results: [{ 'count()': number }] }>('COUNT LOGS', token || undefined, 30000),
                cachedQuery<{ results: [{ 'count()': number }] }>("COUNT LOGS WHERE severity_text = 'ERROR'", token || undefined, 30000),
                cachedQuery<{ results: [{ 'count()': number }] }>("COUNT LOGS WHERE severity_text = 'WARN'", token || undefined, 30000),
                cachedQuery<{ results: [{ 'count()': number }] }>("COUNT LOGS WHERE severity_text = 'INFO'", token || undefined, 30000),
            ]);

            setStats({
                total: totalRes.results[0]?.['count()'] || 0,
                error: errorRes.results[0]?.['count()'] || 0,
                warning: warnRes.results[0]?.['count()'] || 0,
                info: infoRes.results[0]?.['count()'] || 0,
            });
        } catch (e) {
            console.error("Failed to fetch log stats:", e);
        } finally {
            setStatsLoading(false);
        }
    }, [token]);

    const fetchServices = useCallback(async () => {
        try {
            // Fetch a sample of logs to extract unique service names
            const query = 'SHOW LOGS LIMIT 1000';
            const data = await postQuery<{ results: Log[] }>(query);
            const uniqueServices = new Set<string>();
            data.results.forEach(log => {
                if (log.service_name && log.service_name.trim() !== '') {
                    uniqueServices.add(log.service_name);
                }
            });
            const serviceNames = Array.from(uniqueServices).sort();
            setServices(serviceNames);
        } catch (e) {
            console.error("Failed to fetch services:", e);
        }
    }, [postQuery]);

    const fetchLogs = useCallback(async (cursor?: string, direction?: 'next' | 'prev') => {
        setLogsLoading(true);
        setError(null);

        try {
            let query = 'SHOW LOGS';
            const whereClauses: string[] = [];

            if (debouncedSearchTerm) {
                whereClauses.push(`(body LIKE '%${debouncedSearchTerm}%' OR service_name LIKE '%${debouncedSearchTerm}%')`);
            }

            if (filterSeverity !== 'all') {
                whereClauses.push(`severity_text = '${filterSeverity}'`);
            }

            if (filterService !== 'all') {
                whereClauses.push(`service_name = '${filterService}'`);
            }

            if (whereClauses.length > 0) {
                query += ` WHERE ${whereClauses.join(' AND ')}`;
            }

            query += ` ORDER BY ${sortBy} ${sortOrder.toUpperCase()}`;

            const data = await postQuery<LogsApiResponse>(query, cursor, direction);
            setLogs(data.results || []);
            setPagination(data.pagination || null);
        } catch (e) {
            setError(e instanceof Error ? e.message : "An unknown error occurred.");
            setLogs([]);
            setPagination(null);
        } finally {
            setLogsLoading(false);
        }
    }, [postQuery, debouncedSearchTerm, filterSeverity, filterService, sortBy, sortOrder]);

    useEffect(() => {
        // Fetch stats and services on mount
        fetchStats();
        fetchServices();
    }, [fetchStats, fetchServices]);

    useEffect(() => {
        // Fetch logs when dependencies change
        fetchLogs();
    }, [fetchLogs]);

    const handleSort = (key: SortableLogKeys) => {
        if (sortBy === key) {
            setSortOrder(sortOrder === 'asc' ? 'desc' : 'asc');
        } else {
            setSortBy(key);
            setSortOrder('desc');
        }
    };

    const getSeverityBadge = (severity: string) => {
        const upperSeverity = severity.toUpperCase();

        switch (upperSeverity) {
            case 'ERROR':
            case 'FATAL':
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

    const TableHeader = ({
        aKey,
        label
    }: {
        aKey: SortableLogKeys;
        label: string
    }) => (
        <th
            scope="col"
            className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider cursor-pointer"
            onClick={() => handleSort(aKey)}
        >
            <div className="flex items-center">
                {label}
                {sortBy === aKey && (
                    sortOrder === 'asc' ? (
                        <ArrowUp className="ml-1 h-3 w-3" />
                    ) : (
                        <ArrowDown className="ml-1 h-3 w-3" />
                    )
                )}
            </div>
        </th>
    );

    return (
        <div className="space-y-6">
            <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
                <StatCard
                    title="Total Logs"
                    value={stats.total.toLocaleString()}
                    icon={<FileText className="h-6 w-6 text-orange-600 dark:text-gray-300" />}
                    isLoading={statsLoading}
                />
                <StatCard
                    title="Errors"
                    value={stats.error.toLocaleString()}
                    icon={<AlertOctagon className="h-6 w-6 text-red-400" />}
                    isLoading={statsLoading}
                />
                <StatCard
                    title="Warnings"
                    value={stats.warning.toLocaleString()}
                    icon={<AlertTriangleIcon className="h-6 w-6 text-orange-400" />}
                    isLoading={statsLoading}
                />
                <StatCard
                    title="Info"
                    value={stats.info.toLocaleString()}
                    icon={<Info className="h-6 w-6 text-sky-400" />}
                    isLoading={statsLoading}
                />
            </div>

            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg shadow-lg">
                <div className="p-4 flex flex-col md:flex-row gap-4 justify-between items-center border-b border-gray-200 dark:border-gray-700">
                    <div className="relative w-full md:w-1/3">
                        <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 h-5 w-5 text-gray-400" />
                        <input
                            type="text"
                            placeholder="Search logs..."
                            value={searchTerm}
                            onChange={(e) => setSearchTerm(e.target.value)}
                            className="w-full pl-10 pr-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-green-500 focus:border-green-500"
                        />
                    </div>

                    <div className="flex items-center gap-4">
                        <div className="flex items-center gap-2">
                            <label htmlFor="severityFilter" className="text-sm text-gray-700 dark:text-gray-300">
                                Severity:
                            </label>
                            <select
                                id="severityFilter"
                                value={filterSeverity}
                                onChange={(e) => setFilterSeverity(e.target.value as any)}
                                className="border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white px-3 py-2 focus:ring-green-500 focus:border-green-500"
                            >
                                <option value="all">All</option>
                                <option value="ERROR">Error</option>
                                <option value="WARN">Warning</option>
                                <option value="INFO">Info</option>
                                <option value="DEBUG">Debug</option>
                            </select>
                        </div>

                        <div className="flex items-center gap-2">
                            <label htmlFor="serviceFilter" className="text-sm text-gray-700 dark:text-gray-300">
                                Service:
                            </label>
                            <select
                                id="serviceFilter"
                                value={filterService}
                                onChange={(e) => setFilterService(e.target.value)}
                                className="border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white px-3 py-2 focus:ring-green-500 focus:border-green-500"
                            >
                                <option value="all">All</option>
                                {services.map((service) => (
                                    <option key={service} value={service}>
                                        {service}
                                    </option>
                                ))}
                            </select>
                        </div>
                    </div>
                </div>

                <div className="overflow-x-auto">
                    <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                        <thead className="bg-gray-100 dark:bg-gray-800/50">
                        <tr>
                            <th scope="col" className="w-12"></th>
                            <TableHeader aKey="timestamp" label="Timestamp" />
                            <TableHeader aKey="severity_text" label="Severity" />
                            <TableHeader aKey="service_name" label="Service" />
                            <th
                                scope="col"
                                className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider"
                            >
                                Message
                            </th>
                            <th
                                scope="col"
                                className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider"
                            >
                                Trace ID
                            </th>
                        </tr>
                        </thead>

                        <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                        {logsLoading ? (
                            <tr>
                                <td colSpan={6} className="text-center p-8">
                                    <Loader2 className="h-8 w-8 text-gray-400 animate-spin mx-auto" />
                                </td>
                            </tr>
                        ) : error ? (
                            <tr>
                                <td colSpan={6} className="text-center p-8 text-red-500 dark:text-red-400">
                                    <AlertCircle className="mx-auto h-6 w-6 mb-2" />
                                    {error}
                                </td>
                            </tr>
                        ) : logs.length === 0 ? (
                            <tr>
                                <td colSpan={6} className="text-center p-8 text-gray-600 dark:text-gray-400">
                                    No logs found.
                                </td>
                            </tr>
                        ) : (
                            logs.map((log, index) => {
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
                                                {log.severity_text}
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
                                                                theme="pop"
                                                                collapsed={false}
                                                                displayDataTypes={false}
                                                                enableClipboard={true}
                                                                style={{
                                                                    padding: '1rem',
                                                                    borderRadius: '0.375rem',
                                                                    backgroundColor: '#1C1B22',
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
                            })
                        )}
                        </tbody>
                    </table>
                </div>

                {pagination && (pagination.prev_cursor || pagination.next_cursor) && (
                    <div className="p-4 flex items-center justify-between border-t border-gray-200 dark:border-gray-700">
                        <button
                            onClick={() => fetchLogs(pagination.prev_cursor, 'prev')}
                            disabled={!pagination.prev_cursor || logsLoading}
                            className="px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-white rounded-md disabled:opacity-50 disabled:cursor-not-allowed"
                        >
                            Previous
                        </button>
                        <button
                            onClick={() => fetchLogs(pagination.next_cursor, 'next')}
                            disabled={!pagination.next_cursor || logsLoading}
                            className="px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-white rounded-md disabled:opacity-50 disabled:cursor-not-allowed"
                        >
                            Next
                        </button>
                    </div>
                )}
            </div>
        </div>
    );
};

export default LogsDashboard;