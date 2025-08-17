'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useAuth } from '@/components/AuthProvider';
import { OtelMetric, OtelMetricsApiResponse, MetricsStats, SortableMetricKeys } from '@/types/otel-metrics';
import { Pagination } from '@/types/devices';
import {
    Clock,
    AlertTriangle,
    BarChart3,
    TrendingUp,
    Search,
    Loader2,
    ArrowUp,
    ArrowDown,
    Activity,
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

const formatDuration = (ms: number): string => {
    if (ms >= 1000) {
        return (ms / 1000).toFixed(2) + 's';
    }
    return Math.round(ms) + 'ms';
};

const formatPercentage = (value: number): string => {
    return (value * 100).toFixed(1) + '%';
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
                <span className="lg:hidden">{traceId?.substring(0, 6)}...</span>
                <span className="hidden lg:inline">{traceId?.substring(0, 8)}...</span>
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

const MetricsDashboard = () => {
    const { token } = useAuth();
    const [metrics, setMetrics] = useState<OtelMetric[]>([]);
    const [pagination, setPagination] = useState<Pagination | null>(null);
    const [stats, setStats] = useState<MetricsStats>({
        total: 0,
        slow_spans: 0,
        avg_duration_ms: 0,
        p95_duration_ms: 0,
        error_rate: 0,
        top_services: []
    });
    const [statsLoading, setStatsLoading] = useState(true);
    const [metricsLoading, setMetricsLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);
    const [searchTerm, setSearchTerm] = useState('');
    const [debouncedSearchTerm] = useDebounce(searchTerm, 300);
    const [filterService, setFilterService] = useState<string>('all');
    const [filterSlow, setFilterSlow] = useState<'all' | 'slow' | 'fast'>('all');
    const [services, setServices] = useState<string[]>([]);
    const [sortBy, setSortBy] = useState<SortableMetricKeys>('timestamp');
    const [sortOrder, setSortOrder] = useState<'asc' | 'desc'>('desc');

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
            const [totalRes, slowRes, errorRateRes] = await Promise.all([
                cachedQuery<{ results: [{ 'count()': number }] }>('COUNT otel_metrics', token || undefined, 30000),
                cachedQuery<{ results: [{ 'count()': number }] }>('COUNT otel_metrics WHERE is_slow = true', token || undefined, 30000),
                cachedQuery<{ results: [{ 'count()': number }] }>("COUNT otel_metrics WHERE http_status_code = '500' OR http_status_code = '400' OR http_status_code = '404' OR http_status_code = '503'", token || undefined, 30000),
            ]);

            const total = (totalRes.results && totalRes.results[0])?.['count()'] || 0;
            const errors = (errorRateRes.results && errorRateRes.results[0])?.['count()'] || 0;
            
            // Average duration will be calculated after fetching metrics data
            
            setStats({
                total: total,
                slow_spans: (slowRes.results && slowRes.results[0])?.['count()'] || 0,
                avg_duration_ms: 0,
                p95_duration_ms: 0, // P95 calculation would need a more complex query
                error_rate: total > 0 ? errors / total : 0,
                top_services: [] // Removed this section
            });
        } catch (e) {
            console.error("Failed to fetch metrics stats:", e);
        } finally {
            setStatsLoading(false);
        }
    }, [token]);

    const fetchServices = useCallback(async () => {
        try {
            const query = 'SHOW DISTINCT(service_name) FROM otel_metrics WHERE service_name IS NOT NULL LIMIT 100';
            const response = await postQuery<{ results: Array<{ service_name: string }> }>(query);
            const serviceNames = (response.results || []).map(r => r.service_name).filter(Boolean);
            setServices(serviceNames);
        } catch (e) {
            console.error("Failed to fetch services:", e);
            setServices([]);
        }
    }, [postQuery]);

    const fetchMetrics = useCallback(async (cursor?: string, direction?: 'next' | 'prev') => {
        setMetricsLoading(true);
        setError(null);

        try {
            let query = 'SHOW otel_metrics';
            const conditions: string[] = [];

            // Add search filter
            if (debouncedSearchTerm) {
                conditions.push(`(trace_id LIKE '%${debouncedSearchTerm}%' OR service_name LIKE '%${debouncedSearchTerm}%' OR span_name LIKE '%${debouncedSearchTerm}%')`);
            }

            // Add service filter
            if (filterService !== 'all') {
                conditions.push(`service_name = '${filterService}'`);
            }

            // Add performance filter
            if (filterSlow === 'slow') {
                conditions.push('is_slow = true');
            } else if (filterSlow === 'fast') {
                conditions.push('is_slow = false');
            }

            if (conditions.length > 0) {
                query += ` WHERE ${conditions.join(' AND ')}`;
            }

            // Add ordering
            query += ` ORDER BY ${sortBy === 'timestamp' ? '_tp_time' : sortBy} ${sortOrder.toUpperCase()}`;

            const response = await postQuery<OtelMetricsApiResponse>(query, cursor, direction);
            setMetrics(response.results || []);
            setPagination(response.pagination || null);
            
            // Update stats with calculated averages from the fetched data
            if (response.results && response.results.length > 0) {
                const totalDuration = response.results.reduce((sum, metric) => sum + (metric.duration_ms || 0), 0);
                const avgDuration = totalDuration / response.results.length;
                
                setStats(prevStats => ({
                    ...prevStats,
                    avg_duration_ms: avgDuration
                }));
            }
        } catch (e) {
            console.error("Failed to fetch metrics:", e);
            setError(e instanceof Error ? e.message : 'Failed to fetch metrics');
            setMetrics([]);
            setPagination(null);
        } finally {
            setMetricsLoading(false);
        }
    }, [postQuery, debouncedSearchTerm, filterService, filterSlow, sortBy, sortOrder]);

    useEffect(() => {
        fetchStats();
        fetchServices();
    }, [fetchStats, fetchServices]);

    useEffect(() => {
        fetchMetrics();
    }, [fetchMetrics]);

    const handleSort = (key: SortableMetricKeys) => {
        if (sortBy === key) {
            setSortOrder(sortOrder === 'asc' ? 'desc' : 'asc');
        } else {
            setSortBy(key);
            setSortOrder('desc');
        }
    };



    const getStatusBadge = (statusCode: string) => {
        const code = parseInt(statusCode);
        if (code >= 400) {
            return 'bg-red-100 dark:bg-red-600/50 text-red-800 dark:text-red-200 border border-red-300 dark:border-red-500/60';
        } else if (code >= 300) {
            return 'bg-yellow-100 dark:bg-yellow-600/50 text-yellow-800 dark:text-yellow-200 border border-yellow-300 dark:border-yellow-500/60';
        }
        return 'bg-green-100 dark:bg-green-600/50 text-green-800 dark:text-green-200 border border-green-300 dark:border-green-500/60';
    };



    const TableHeader = ({
        aKey,
        label
    }: {
        aKey: SortableMetricKeys;
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
            <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
                <StatCard
                    title="Total Metrics"
                    value={formatNumber(stats.total)}
                    icon={<BarChart3 className="h-6 w-6" />}
                    isLoading={statsLoading}
                    color="blue"
                />
                <StatCard
                    title="Slow Spans"
                    value={formatNumber(stats.slow_spans)}
                    icon={<AlertTriangle className="h-6 w-6" />}
                    isLoading={statsLoading}
                    color="red"
                    onClick={() => setFilterSlow('slow')}
                />
                <StatCard
                    title="Avg Duration"
                    value={formatDuration(stats.avg_duration_ms)}
                    icon={<Clock className="h-6 w-6" />}
                    isLoading={statsLoading}
                    color="purple"
                />
                <StatCard
                    title="Error Rate"
                    value={formatPercentage(stats.error_rate)}
                    icon={<TrendingUp className="h-6 w-6" />}
                    isLoading={statsLoading}
                    color="red"
                />
            </div>



            {/* Metrics Table */}
            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg shadow-lg">
                <div className="p-3 border-b border-gray-200 dark:border-gray-700">
                    <div className="flex flex-col gap-3">
                        <div className="relative">
                            <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 h-4 w-4 text-gray-400" />
                            <input
                                type="text"
                                placeholder="Search metrics..."
                                value={searchTerm}
                                onChange={(e) => setSearchTerm(e.target.value)}
                                className="w-full pl-9 pr-4 py-2 text-sm border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-green-500 focus:border-green-500"
                            />
                        </div>

                        <div className="flex flex-col sm:flex-row gap-3">
                            <div className="flex items-center gap-2">
                                <label htmlFor="slowFilter" className="text-xs text-gray-700 dark:text-gray-300 whitespace-nowrap">
                                    Performance:
                                </label>
                                <select
                                    id="slowFilter"
                                    value={filterSlow}
                                    onChange={(e) => setFilterSlow(e.target.value as 'all' | 'slow' | 'fast')}
                                    className="text-sm border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white px-2 py-1 focus:ring-green-500 focus:border-green-500"
                                >
                                    <option value="all">All</option>
                                    <option value="slow">Slow</option>
                                    <option value="fast">Fast</option>
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
                                <TableHeader aKey="timestamp" label="Time" />
                                <th scope="col" className="px-3 py-2 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                                    Service/Span
                                </th>
                                <TableHeader aKey="duration_ms" label="Duration" />
                                <th scope="col" className="px-3 py-2 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider hidden lg:table-cell">
                                    Route/Method
                                </th>
                                <th scope="col" className="px-3 py-2 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                                    Status
                                </th>
                                <th scope="col" className="px-3 py-2 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                                    Trace ID
                                </th>
                            </tr>
                        </thead>

                        <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
                            {metricsLoading ? (
                                <tr>
                                    <td colSpan={9} className="text-center p-8">
                                        <Loader2 className="h-8 w-8 text-gray-400 animate-spin mx-auto" />
                                    </td>
                                </tr>
                            ) : error ? (
                                <tr>
                                    <td colSpan={9} className="text-center p-8 text-red-500 dark:text-red-400">
                                        <Activity className="mx-auto h-6 w-6 mb-2" />
                                        {error}
                                    </td>
                                </tr>
                            ) : metrics.length === 0 ? (
                                <tr>
                                    <td colSpan={9} className="text-center p-8 text-gray-600 dark:text-gray-400">
                                        No metrics found.
                                    </td>
                                </tr>
                            ) : (
                                metrics.map((metric, index) => {
                                    const uniqueKey = `${metric.trace_id}-${metric.span_id}-${index}`;
                                    return (
                                        <tr key={uniqueKey} className="hover:bg-gray-100 dark:hover:bg-gray-700/30">
                                            <td className="px-3 py-2 whitespace-nowrap text-xs text-gray-700 dark:text-gray-300">
                                                <div className="font-medium">
                                                    {new Date(metric.timestamp).toLocaleDateString()}
                                                </div>
                                                <div className="text-gray-500 dark:text-gray-400">
                                                    {new Date(metric.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                                                </div>
                                            </td>
                                            <td className="px-3 py-2 text-xs text-gray-700 dark:text-gray-300">
                                                <div className="font-medium truncate max-w-xs">
                                                    {metric.service_name || 'Unknown'}
                                                </div>
                                                <div className="text-gray-500 dark:text-gray-400 truncate">
                                                    {metric.span_name || 'Unknown Span'}
                                                </div>
                                            </td>
                                            <td className="px-3 py-2 whitespace-nowrap text-xs text-gray-700 dark:text-gray-300">
                                                <div className="font-medium">
                                                    {formatDuration(metric.duration_ms)}
                                                </div>
                                                <div className={`text-xs ${metric.is_slow ? 'text-red-500' : 'text-green-500'}`}>
                                                    {metric.is_slow ? 'Slow' : 'Fast'}
                                                </div>
                                            </td>
                                            <td className="px-3 py-2 text-xs text-gray-700 dark:text-gray-300 hidden lg:table-cell">
                                                <div className="truncate max-w-xs">
                                                    {metric.http_route || '-'}
                                                </div>
                                                <div className="text-gray-500 dark:text-gray-400">
                                                    {metric.http_method || '-'}
                                                </div>
                                            </td>
                                            <td className="px-3 py-2 whitespace-nowrap">
                                                <span className={`px-1.5 py-0.5 inline-flex text-xs leading-4 font-semibold rounded-full ${getStatusBadge(metric.http_status_code)}`}>
                                                    {metric.http_status_code || '-'}
                                                </span>
                                            </td>
                                            <td className="px-3 py-2 whitespace-nowrap">
                                                {metric.trace_id ? (
                                                    <TraceIdCell traceId={metric.trace_id} />
                                                ) : (
                                                    <span className="text-xs text-gray-400">-</span>
                                                )}
                                            </td>
                                        </tr>
                                    );
                                })
                            )}
                        </tbody>
                    </table>
                </div>

                {pagination && (pagination.prev_cursor || pagination.next_cursor) && (
                    <div className="p-4 flex items-center justify-between border-t border-gray-200 dark:border-gray-700">
                        <button
                            onClick={() => fetchMetrics(pagination.prev_cursor, 'prev')}
                            disabled={!pagination.prev_cursor || metricsLoading}
                            className="px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-white rounded-md disabled:opacity-50 disabled:cursor-not-allowed"
                        >
                            Previous
                        </button>
                        <button
                            onClick={() => fetchMetrics(pagination.next_cursor, 'next')}
                            disabled={!pagination.next_cursor || metricsLoading}
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

export default MetricsDashboard;