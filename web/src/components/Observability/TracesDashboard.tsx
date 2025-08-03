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
    Copy,
    Check
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
            className={`bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 p-2 rounded-lg transition-all ${
                onClick ? 'cursor-pointer hover:shadow-lg hover:border-orange-400 dark:hover:border-orange-600' : ''
            }`}
            onClick={onClick}
        >
            <div className="flex items-center space-x-2">
                <div className={`p-1.5 rounded-md ${colorClasses[color]}`}>
                    {React.cloneElement(icon as React.ReactElement<{ className?: string }>, { className: "h-4 w-4" })}
                </div>
                <div className="flex-1 min-w-0">
                    <p className="text-sm text-gray-600 dark:text-gray-400 leading-tight truncate">{title}</p>
                    {isLoading ? (
                        <div className="h-5 w-16 bg-gray-200 dark:bg-gray-700 rounded-md animate-pulse"></div>
                    ) : (
                        <p className="text-lg font-bold text-gray-900 dark:text-white leading-tight">{value}</p>
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

const TraceIdCell = ({ traceId }: { traceId: string }) => {
    const [copied, setCopied] = useState(false);
    
    const copyToClipboard = async (e: React.MouseEvent) => {
        e.stopPropagation();
        try {
            await navigator.clipboard.writeText(traceId);
            setCopied(true);
            setTimeout(() => setCopied(false), 2000);
        } catch (err) {
            console.error('Failed to copy:', err);
        }
    };

    return (
        <div className="group relative">
            <button
                onClick={copyToClipboard}
                className="flex items-center gap-1 text-xs font-mono text-gray-700 dark:text-gray-300 hover:text-blue-600 dark:hover:text-blue-400 transition-colors"
                title={`Click to copy: ${traceId}`}
            >
                <span className="lg:hidden">{traceId.substring(0, 6)}...</span>
                <span className="hidden lg:inline">{traceId.substring(0, 8)}...</span>
                {copied ? (
                    <Check className="h-3 w-3 text-green-500" />
                ) : (
                    <Copy className="h-3 w-3 opacity-0 group-hover:opacity-100 transition-opacity" />
                )}
            </button>
            
            {/* Tooltip with full trace ID */}
            <div className="absolute bottom-full left-1/2 transform -translate-x-1/2 mb-2 px-2 py-1 bg-gray-900 dark:bg-gray-100 text-white dark:text-gray-900 text-xs rounded opacity-0 group-hover:opacity-100 transition-opacity pointer-events-none z-10 whitespace-nowrap">
                {traceId}
                <div className="absolute top-full left-1/2 transform -translate-x-1/2 border-4 border-transparent border-t-gray-900 dark:border-t-gray-100"></div>
            </div>
        </div>
    );
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
            
            // Update stats with calculated values from the fetched data
            if (response.results && response.results.length > 0) {
                const durations = response.results.map(trace => trace.duration_ms || 0).sort((a, b) => a - b);
                const totalDuration = durations.reduce((sum, duration) => sum + duration, 0);
                const avgDuration = totalDuration / durations.length;
                
                // Calculate P95 (95th percentile)
                const p95Index = Math.floor(durations.length * 0.95);
                const p95Duration = durations[p95Index] || 0;
                
                // Get unique services
                const uniqueServices = new Set(response.results.map(trace => 
                    trace.root_service_name
                ).filter(Boolean));
                
                setStats(prevStats => ({
                    ...prevStats,
                    avg_duration_ms: avgDuration,
                    p95_duration_ms: p95Duration,
                    services_count: uniqueServices.size
                }));
            }
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



    const TableHeader = ({
        aKey,
        label
    }: {
        aKey: SortableTraceKeys;
        label: string
    }) => (
        <th
            scope="col"
            className="px-3 py-2 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider cursor-pointer"
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
            <div className="grid grid-cols-2 md:grid-cols-6 gap-3">
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
                <div className="p-3 border-b border-gray-200 dark:border-gray-700">
                    <div className="flex flex-col gap-3">
                        <div className="relative">
                            <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 h-4 w-4 text-gray-400" />
                            <input
                                type="text"
                                placeholder="Search traces..."
                                value={searchTerm}
                                onChange={(e) => setSearchTerm(e.target.value)}
                                className="w-full pl-9 pr-4 py-2 text-sm border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-green-500 focus:border-green-500"
                            />
                        </div>

                        <div className="flex flex-col sm:flex-row gap-3">
                            <div className="flex items-center gap-2">
                                <label htmlFor="statusFilter" className="text-xs text-gray-700 dark:text-gray-300 whitespace-nowrap">
                                    Status:
                                </label>
                                <select
                                    id="statusFilter"
                                    value={filterStatus}
                                    onChange={(e) => setFilterStatus(e.target.value as 'all' | 'success' | 'error')}
                                    className="text-sm border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white px-2 py-1 focus:ring-green-500 focus:border-green-500"
                                >
                                    <option value="all">All</option>
                                    <option value="success">Success</option>
                                    <option value="error">Error</option>
                                </select>
                            </div>

                            <div className="flex items-center gap-2">
                                <label htmlFor="serviceFilter" className="text-xs text-gray-700 dark:text-gray-300 whitespace-nowrap">
                                    Service:
                                </label>
                                <select
                                    id="serviceFilter"
                                    value={filterService}
                                    onChange={(e) => setFilterService(e.target.value)}
                                    className="text-sm border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white px-2 py-1 focus:ring-green-500 focus:border-green-500"
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
                </div>

                <div className="overflow-x-auto">
                    <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                        <thead className="bg-gray-100 dark:bg-gray-800/50">
                            <tr>
                                <th scope="col" className="w-8"></th>
                                <TableHeader aKey="timestamp" label="Time" />
                                <th scope="col" className="px-3 py-2 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider hidden lg:table-cell">
                                    Trace ID
                                </th>
                                <th scope="col" className="px-3 py-2 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                                    Span/Service
                                </th>
                                <TableHeader aKey="duration_ms" label="Duration" />
                                <TableHeader aKey="span_count" label="Spans" />
                                <th scope="col" className="px-3 py-2 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                                    Status
                                </th>
                            </tr>
                        </thead>

                        <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                            {tracesLoading ? (
                                <tr>
                                    <td colSpan={7} className="text-center p-8">
                                        <Loader2 className="h-8 w-8 text-gray-400 animate-spin mx-auto" />
                                    </td>
                                </tr>
                            ) : error ? (
                                <tr>
                                    <td colSpan={7} className="text-center p-8 text-red-500 dark:text-red-400">
                                        <AlertCircle className="mx-auto h-6 w-6 mb-2" />
                                        {error}
                                    </td>
                                </tr>
                            ) : traces.length === 0 ? (
                                <tr>
                                    <td colSpan={7} className="text-center p-8 text-gray-600 dark:text-gray-400">
                                        No traces found.
                                    </td>
                                </tr>
                            ) : (
                                traces.map((trace, index) => {
                                    const uniqueKey = `${trace.trace_id}-${index}`;
                                    return (
                                        <React.Fragment key={uniqueKey}>
                                            <tr className="hover:bg-gray-100 dark:hover:bg-gray-700/30">
                                                <td className="pl-2">
                                                    <button
                                                        onClick={() => setExpandedRow(expandedRow === uniqueKey ? null : uniqueKey)}
                                                        className="p-1 rounded-full hover:bg-gray-200 dark:hover:bg-gray-600 text-gray-600 dark:text-gray-400"
                                                    >
                                                        {expandedRow === uniqueKey ? (
                                                            <ChevronDown className="h-4 w-4" />
                                                        ) : (
                                                            <ChevronRight className="h-4 w-4" />
                                                        )}
                                                    </button>
                                                </td>
                                                <td className="px-3 py-2 whitespace-nowrap text-xs text-gray-700 dark:text-gray-300">
                                                    <div className="font-medium">
                                                        {new Date(trace.timestamp).toLocaleDateString()}
                                                    </div>
                                                    <div className="text-gray-500 dark:text-gray-400">
                                                        {new Date(trace.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                                                    </div>
                                                </td>
                                                <td className="px-3 py-2 whitespace-nowrap hidden lg:table-cell">
                                                    <TraceIdCell traceId={trace.trace_id} />
                                                </td>
                                                <td className="px-3 py-2 text-xs text-gray-700 dark:text-gray-300">
                                                    <div className="font-medium truncate max-w-xs">
                                                        {trace.root_span_name || 'Unknown'}
                                                    </div>
                                                    <div className="text-gray-500 dark:text-gray-400 truncate">
                                                        {trace.root_service_name || 'Unknown Service'}
                                                    </div>
                                                </td>
                                                <td className="px-3 py-2 whitespace-nowrap text-xs text-gray-700 dark:text-gray-300">
                                                    <div className="font-medium">
                                                        {formatDuration(trace.duration_ms)}
                                                    </div>
                                                </td>
                                                <td className="px-3 py-2 whitespace-nowrap text-xs text-gray-700 dark:text-gray-300">
                                                    <div className="font-medium">
                                                        {trace.span_count}
                                                    </div>
                                                </td>
                                                <td className="px-3 py-2 whitespace-nowrap">
                                                    <span className={`px-1.5 py-0.5 inline-flex text-xs leading-4 font-semibold rounded-full ${getStatusBadge(trace.status_code, trace.error_count)}`}>
                                                        {trace.status_code === 1 && trace.error_count === 0 ? 'OK' : 'ERR'}
                                                    </span>
                                                </td>
                                            </tr>

                                            {expandedRow === uniqueKey && (
                                                <tr className="bg-gray-100 dark:bg-gray-800/50">
                                                    <td colSpan={7} className="p-3">
                                                        <div className="space-y-3">
                                                            <div>
                                                                <h4 className="text-sm font-semibold text-gray-900 dark:text-white mb-2">
                                                                    Trace Details
                                                                </h4>
                                                                <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3 text-xs">
                                                                    <div>
                                                                        <p className="text-gray-600 dark:text-gray-400">Full Trace ID:</p>
                                                                        <p className="font-mono text-gray-900 dark:text-white text-xs break-all">{trace.trace_id}</p>
                                                                    </div>
                                                                    <div>
                                                                        <p className="text-gray-600 dark:text-gray-400">Services:</p>
                                                                        <p className="text-gray-900 dark:text-white">
                                                                            {trace.service_set?.join(', ') || trace.root_service_name || 'Unknown Service'}
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