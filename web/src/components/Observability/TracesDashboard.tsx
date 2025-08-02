'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useAuth } from '@/components/AuthProvider';
import { TraceSummary, TraceSummariesApiResponse, TraceStats, SortableTraceKeys } from '@/types/traces';
import { Pagination } from '@/types/devices';
import {
    Clock,
    Zap,
    AlertCircle,
    Activity,
    Users,
    Search,
    Loader2,
    ArrowUp,
    ArrowDown,
    ChevronDown,
    ChevronRight,
    Eye,
    ExternalLink
} from 'lucide-react';
import { useDebounce } from 'use-debounce';
import { cachedQuery } from '@/lib/cached-query';

const StatCard = ({
    title,
    value,
    icon,
    isLoading,
    onClick,
    color = 'orange'
}: {
    title: string;
    value: string | number;
    icon: React.ReactNode;
    isLoading: boolean;
    onClick?: () => void;
    color?: 'orange' | 'green' | 'red' | 'blue' | 'purple';
}) => {
    const colorClasses = {
        orange: 'bg-orange-100 dark:bg-gray-700/50 text-orange-600 dark:text-orange-400',
        green: 'bg-green-100 dark:bg-gray-700/50 text-green-600 dark:text-green-400',
        red: 'bg-red-100 dark:bg-gray-700/50 text-red-600 dark:text-red-400',
        blue: 'bg-blue-100 dark:bg-gray-700/50 text-blue-600 dark:text-blue-400',
        purple: 'bg-purple-100 dark:bg-gray-700/50 text-purple-600 dark:text-purple-400',
    };

    return (
        <div 
            className={`bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 p-4 rounded-lg transition-all ${
                onClick ? 'cursor-pointer hover:shadow-lg hover:border-orange-400 dark:hover:border-orange-600' : ''
            }`}
            onClick={onClick}
        >
            <div className="flex items-center">
                <div className={`p-2 rounded-md mr-4 ${colorClasses[color]}`}>
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
};

const formatNumber = (num: number): string => {
    if (num >= 1000000) {
        return (num / 1000000).toFixed(1).replace(/\.0$/, '') + 'M';
    }
    if (num >= 1000) {
        return (num / 1000).toFixed(1).replace(/\.0$/, '') + 'k';
    }
    return num.toString();
};

const formatDuration = (ms: number): string => {
    if (ms >= 1000) {
        return (ms / 1000).toFixed(2) + 's';
    }
    return Math.round(ms) + 'ms';
};

const TracesDashboard = () => {
    const { token } = useAuth();
    const [traces, setTraces] = useState<TraceSummary[]>([]);
    const [pagination, setPagination] = useState<Pagination | null>(null);
    const [stats, setStats] = useState<TraceStats>({
        total: 0,
        successful: 0,
        errors: 0,
        avg_duration_ms: 0,
        p95_duration_ms: 0,
        services_count: 0
    });
    const [statsLoading, setStatsLoading] = useState(true);
    const [tracesLoading, setTracesLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);
    const [searchTerm, setSearchTerm] = useState('');
    const [debouncedSearchTerm] = useDebounce(searchTerm, 300);
    const [filterService, setFilterService] = useState<string>('all');
    const [filterStatus, setFilterStatus] = useState<'all' | 'success' | 'error'>('all');
    const [services, setServices] = useState<string[]>([]);
    const [sortBy, setSortBy] = useState<SortableTraceKeys>('timestamp');
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
            const [totalRes, successRes, errorRes] = await Promise.all([
                cachedQuery<{ results: [{ 'count()': number }] }>('COUNT otel_trace_summaries', token || undefined, 30000),
                cachedQuery<{ results: [{ 'count()': number }] }>('COUNT otel_trace_summaries WHERE status = 1', token || undefined, 30000),
                cachedQuery<{ results: [{ 'count()': number }] }>('COUNT otel_trace_summaries WHERE status != 1 OR errors > 0', token || undefined, 30000),
            ]);

            setStats({
                total: totalRes.results[0]?.['count()'] || 0,
                successful: successRes.results[0]?.['count()'] || 0,
                errors: errorRes.results[0]?.['count()'] || 0,
                avg_duration_ms: 0, // Will calculate from current data
                p95_duration_ms: 0, // Will calculate from current data
                services_count: 0, // Will calculate from current data
            });
        } catch (e) {
            console.error("Failed to fetch trace stats:", e);
        } finally {
            setStatsLoading(false);
        }
    }, [token]);

    const fetchServices = useCallback(async () => {
        try {
            const query = 'SHOW DISTINCT(root_service_name) FROM otel_trace_summaries WHERE root_service_name IS NOT NULL LIMIT 100';
            const response = await postQuery<{ results: Array<{ root_service_name: string }> }>(query);
            const serviceNames = response.results.map(r => r.root_service_name).filter(Boolean);
            setServices(serviceNames);
        } catch (e) {
            console.error("Failed to fetch services:", e);
            setServices([]);
        }
    }, [postQuery]);

    const fetchTraces = useCallback(async (cursor?: string, direction?: 'next' | 'prev') => {
        setTracesLoading(true);
        setError(null);

        try {
            let query = 'SHOW otel_trace_summaries';
            const conditions: string[] = [];

            // Add search filter
            if (debouncedSearchTerm) {
                conditions.push(`(trace_id LIKE '%${debouncedSearchTerm}%' OR root_service_name LIKE '%${debouncedSearchTerm}%' OR root_span_name LIKE '%${debouncedSearchTerm}%')`);
            }

            // Add service filter
            if (filterService !== 'all') {
                conditions.push(`root_service_name = '${filterService}'`);
            }

            // Add status filter
            if (filterStatus === 'success') {
                conditions.push('status_code = 1 AND error_count = 0');
            } else if (filterStatus === 'error') {
                conditions.push('(status_code != 1 OR error_count > 0)');
            }

            if (conditions.length > 0) {
                query += ` WHERE ${conditions.join(' AND ')}`;
            }

            // Add ordering
            query += ` ORDER BY ${sortBy === 'timestamp' ? '_tp_time' : sortBy} ${sortOrder.toUpperCase()}`;

            const response = await postQuery<TraceSummariesApiResponse>(query, cursor, direction);
            setTraces(response.results);
            setPagination(response.pagination);
        } catch (e) {
            console.error("Failed to fetch traces:", e);
            setError(e instanceof Error ? e.message : 'Failed to fetch traces');
            setTraces([]);
            setPagination(null);
        } finally {
            setTracesLoading(false);
        }
    }, [postQuery, debouncedSearchTerm, filterService, filterStatus, sortBy, sortOrder]);

    useEffect(() => {
        fetchStats();
        fetchServices();
    }, [fetchStats, fetchServices]);

    useEffect(() => {
        fetchTraces();
    }, [fetchTraces]);

    const handleSort = (key: SortableTraceKeys) => {
        if (sortBy === key) {
            setSortOrder(sortOrder === 'asc' ? 'desc' : 'asc');
        } else {
            setSortBy(key);
            setSortOrder('desc');
        }
    };

    const getStatusBadge = (statusCode: number, errorCount: number) => {
        if (statusCode !== 1 || errorCount > 0) {
            return 'bg-red-100 dark:bg-red-600/50 text-red-800 dark:text-red-200 border border-red-300 dark:border-red-500/60';
        }
        return 'bg-green-100 dark:bg-green-600/50 text-green-800 dark:text-green-200 border border-green-300 dark:border-green-500/60';
    };

    const formatDate = (dateString: string) => {
        try {
            return new Date(dateString).toLocaleString();
        } catch {
            return 'Invalid Date';
        }
    };

    const TableHeader = ({
        aKey,
        label
    }: {
        aKey: SortableTraceKeys;
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
            {/* Stats Cards */}
            <div className="grid grid-cols-1 md:grid-cols-3 lg:grid-cols-6 gap-4">
                <StatCard
                    title="Total Traces"
                    value={formatNumber(stats.total)}
                    icon={<Activity className="h-6 w-6" />}
                    isLoading={statsLoading}
                    color="blue"
                />
                <StatCard
                    title="Successful"
                    value={formatNumber(stats.successful)}
                    icon={<Clock className="h-6 w-6" />}
                    isLoading={statsLoading}
                    color="green"
                    onClick={() => setFilterStatus('success')}
                />
                <StatCard
                    title="Errors"
                    value={formatNumber(stats.errors)}
                    icon={<AlertCircle className="h-6 w-6" />}
                    isLoading={statsLoading}
                    color="red"
                    onClick={() => setFilterStatus('error')}
                />
                <StatCard
                    title="Avg Duration"
                    value={formatDuration(stats.avg_duration_ms)}
                    icon={<Zap className="h-6 w-6" />}
                    isLoading={statsLoading}
                    color="purple"
                />
                <StatCard
                    title="P95 Duration"
                    value={formatDuration(stats.p95_duration_ms)}
                    icon={<Zap className="h-6 w-6" />}
                    isLoading={statsLoading}
                    color="orange"
                />
                <StatCard
                    title="Services"
                    value={formatNumber(stats.services_count)}
                    icon={<Users className="h-6 w-6" />}
                    isLoading={statsLoading}
                    color="blue"
                />
            </div>

            {/* Traces Table */}
            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg shadow-lg">
                <div className="p-4 flex flex-col md:flex-row gap-4 justify-between items-center border-b border-gray-200 dark:border-gray-700">
                    <div className="relative w-full md:w-1/3">
                        <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 h-5 w-5 text-gray-400" />
                        <input
                            type="text"
                            placeholder="Search traces..."
                            value={searchTerm}
                            onChange={(e) => setSearchTerm(e.target.value)}
                            className="w-full pl-10 pr-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-green-500 focus:border-green-500"
                        />
                    </div>

                    <div className="flex items-center gap-4">
                        <div className="flex items-center gap-2">
                            <label htmlFor="statusFilter" className="text-sm text-gray-700 dark:text-gray-300">
                                Status:
                            </label>
                            <select
                                id="statusFilter"
                                value={filterStatus}
                                onChange={(e) => setFilterStatus(e.target.value as 'all' | 'success' | 'error')}
                                className="border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white px-3 py-2 focus:ring-green-500 focus:border-green-500"
                            >
                                <option value="all">All</option>
                                <option value="success">Success</option>
                                <option value="error">Error</option>
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
                                <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                                    Trace ID
                                </th>
                                <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                                    Root Span
                                </th>
                                <TableHeader aKey="root_service_name" label="Service" />
                                <TableHeader aKey="duration_ms" label="Duration" />
                                <TableHeader aKey="span_count" label="Spans" />
                                <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                                    Status
                                </th>
                                <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                                    Actions
                                </th>
                            </tr>
                        </thead>

                        <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                            {tracesLoading ? (
                                <tr>
                                    <td colSpan={9} className="text-center p-8">
                                        <Loader2 className="h-8 w-8 text-gray-400 animate-spin mx-auto" />
                                    </td>
                                </tr>
                            ) : error ? (
                                <tr>
                                    <td colSpan={9} className="text-center p-8 text-red-500 dark:text-red-400">
                                        <AlertCircle className="mx-auto h-6 w-6 mb-2" />
                                        {error}
                                    </td>
                                </tr>
                            ) : traces.length === 0 ? (
                                <tr>
                                    <td colSpan={9} className="text-center p-8 text-gray-600 dark:text-gray-400">
                                        No traces found.
                                    </td>
                                </tr>
                            ) : (
                                traces.map((trace, index) => {
                                    const uniqueKey = `${trace.trace_id}-${index}`;
                                    return (
                                        <React.Fragment key={uniqueKey}>
                                            <tr className="hover:bg-gray-100 dark:hover:bg-gray-700/30">
                                                <td className="pl-4">
                                                    <button
                                                        onClick={() => setExpandedRow(expandedRow === uniqueKey ? null : uniqueKey)}
                                                        className="p-1 rounded-full hover:bg-gray-200 dark:hover:bg-gray-600 text-gray-600 dark:text-gray-400"
                                                    >
                                                        {expandedRow === uniqueKey ? (
                                                            <ChevronDown className="h-5 w-5" />
                                                        ) : (
                                                            <ChevronRight className="h-5 w-5" />
                                                        )}
                                                    </button>
                                                </td>
                                                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300">
                                                    {formatDate(trace.timestamp)}
                                                </td>
                                                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300 font-mono">
                                                    {trace.trace_id.substring(0, 12)}...
                                                </td>
                                                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300 max-w-xs truncate">
                                                    {trace.root_span_name || trace.root_span}
                                                </td>
                                                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300">
                                                    {trace.root_service_name || trace.service}
                                                </td>
                                                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300">
                                                    {formatDuration(trace.duration_ms)}
                                                </td>
                                                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300">
                                                    {trace.span_count}
                                                </td>
                                                <td className="px-6 py-4 whitespace-nowrap">
                                                    <span className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${getStatusBadge(trace.status_code, trace.error_count)}`}>
                                                        {trace.status_code === 1 && trace.error_count === 0 ? 'Success' : 'Error'}
                                                    </span>
                                                </td>
                                                <td className="px-6 py-4 whitespace-nowrap text-sm font-medium">
                                                    <button className="text-indigo-600 hover:text-indigo-900 dark:text-indigo-400 dark:hover:text-indigo-300 mr-3">
                                                        <Eye className="h-4 w-4" />
                                                    </button>
                                                </td>
                                            </tr>

                                            {expandedRow === uniqueKey && (
                                                <tr className="bg-gray-100 dark:bg-gray-800/50">
                                                    <td colSpan={9} className="p-4">
                                                        <div className="space-y-4">
                                                            <div>
                                                                <h4 className="text-md font-semibold text-gray-900 dark:text-white mb-2">
                                                                    Trace Details
                                                                </h4>
                                                                <div className="grid grid-cols-3 gap-4 text-sm">
                                                                    <div>
                                                                        <p className="text-gray-600 dark:text-gray-400">Full Trace ID:</p>
                                                                        <p className="font-mono text-gray-900 dark:text-white text-xs break-all">{trace.trace_id}</p>
                                                                    </div>
                                                                    <div>
                                                                        <p className="text-gray-600 dark:text-gray-400">Services:</p>
                                                                        <p className="text-gray-900 dark:text-white">
                                                                            {trace.service_set?.join(', ') || trace.root_service_name || trace.service}
                                                                        </p>
                                                                    </div>
                                                                    <div>
                                                                        <p className="text-gray-600 dark:text-gray-400">Error Count:</p>
                                                                        <p className="text-gray-900 dark:text-white">{trace.error_count}</p>
                                                                    </div>
                                                                </div>
                                                            </div>
                                                        </div>
                                                    </td>
                                                </tr>
                                            )}
                                        </React.Fragment>
                                    );
                                })
                            )}
                        </tbody>
                    </table>
                </div>

                {pagination && (pagination.prev_cursor || pagination.next_cursor) && (
                    <div className="p-4 flex items-center justify-between border-t border-gray-200 dark:border-gray-700">
                        <button
                            onClick={() => fetchTraces(pagination.prev_cursor, 'prev')}
                            disabled={!pagination.prev_cursor || tracesLoading}
                            className="px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-white rounded-md disabled:opacity-50 disabled:cursor-not-allowed"
                        >
                            Previous
                        </button>
                        <button
                            onClick={() => fetchTraces(pagination.next_cursor, 'next')}
                            disabled={!pagination.next_cursor || tracesLoading}
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

export default TracesDashboard;