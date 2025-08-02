'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useAuth } from '@/components/AuthProvider';
import { OtelMetric, OtelMetricsApiResponse, MetricsStats, SortableMetricKeys } from '@/types/otel-metrics';
import { Pagination } from '@/types/devices';
import {
    Zap,
    Clock,
    AlertTriangle,
    BarChart3,
    TrendingUp,
    Search,
    Loader2,
    ArrowUp,
    ArrowDown,
    Activity
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

const formatPercentage = (value: number): string => {
    return (value * 100).toFixed(1) + '%';
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
            const [totalRes, slowRes] = await Promise.all([
                cachedQuery<{ results: [{ 'count()': number }] }>('COUNT otel_metrics', token || undefined, 30000),
                cachedQuery<{ results: [{ 'count()': number }] }>('COUNT otel_metrics WHERE is_slow = true', token || undefined, 30000),
            ]);

            setStats({
                total: totalRes.results[0]?.['count()'] || 0,
                slow_spans: slowRes.results[0]?.['count()'] || 0,
                avg_duration_ms: 0, // Will calculate from current data
                p95_duration_ms: 0, // Will calculate from current data
                error_rate: 0, // Will calculate from current data
                top_services: [] // Will populate separately
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
            const serviceNames = response.results.map(r => r.service_name).filter(Boolean);
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
            setMetrics(response.results);
            setPagination(response.pagination);
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

    const getSlowBadge = (isSlow: boolean) => {
        if (isSlow) {
            return 'bg-red-100 dark:bg-red-600/50 text-red-800 dark:text-red-200 border border-red-300 dark:border-red-500/60';
        }
        return 'bg-green-100 dark:bg-green-600/50 text-green-800 dark:text-green-200 border border-green-300 dark:border-green-500/60';
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
        aKey: SortableMetricKeys;
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
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-5 gap-4">
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
                    title="P95 Duration"
                    value={formatDuration(stats.p95_duration_ms)}
                    icon={<Zap className="h-6 w-6" />}
                    isLoading={statsLoading}
                    color="orange"
                />
                <StatCard
                    title="Error Rate"
                    value={formatPercentage(stats.error_rate)}
                    icon={<TrendingUp className="h-6 w-6" />}
                    isLoading={statsLoading}
                    color="red"
                />
            </div>

            {/* Top Services */}
            {stats.top_services.length > 0 && (
                <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg shadow-lg p-4">
                    <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Top Services by Volume</h3>
                    <div className="grid grid-cols-1 md:grid-cols-5 gap-4">
                        {stats.top_services.map((service, index) => (
                            <div key={service.service_name} className="p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
                                <div className="flex items-center justify-between mb-2">
                                    <span className="text-sm font-medium text-gray-900 dark:text-white truncate">
                                        {service.service_name}
                                    </span>
                                    <span className="text-xs text-gray-500 dark:text-gray-400">#{index + 1}</span>
                                </div>
                                <div className="text-xs text-gray-600 dark:text-gray-400">
                                    <div>{formatNumber(service.count)} spans</div>
                                    <div>{formatDuration(service.avg_duration_ms)} avg</div>
                                </div>
                            </div>
                        ))}
                    </div>
                </div>
            )}

            {/* Metrics Table */}
            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg shadow-lg">
                <div className="p-4 flex flex-col md:flex-row gap-4 justify-between items-center border-b border-gray-200 dark:border-gray-700">
                    <div className="relative w-full md:w-1/3">
                        <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 h-5 w-5 text-gray-400" />
                        <input
                            type="text"
                            placeholder="Search metrics..."
                            value={searchTerm}
                            onChange={(e) => setSearchTerm(e.target.value)}
                            className="w-full pl-10 pr-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-green-500 focus:border-green-500"
                        />
                    </div>

                    <div className="flex items-center gap-4">
                        <div className="flex items-center gap-2">
                            <label htmlFor="slowFilter" className="text-sm text-gray-700 dark:text-gray-300">
                                Performance:
                            </label>
                            <select
                                id="slowFilter"
                                value={filterSlow}
                                onChange={(e) => setFilterSlow(e.target.value as 'all' | 'slow' | 'fast')}
                                className="border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white px-3 py-2 focus:ring-green-500 focus:border-green-500"
                            >
                                <option value="all">All</option>
                                <option value="slow">Slow</option>
                                <option value="fast">Fast</option>
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
                                <TableHeader aKey="timestamp" label="Timestamp" />
                                <TableHeader aKey="service_name" label="Service" />
                                <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                                    Span Name
                                </th>
                                <TableHeader aKey="duration_ms" label="Duration" />
                                <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                                    HTTP Route
                                </th>
                                <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                                    Method
                                </th>
                                <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                                    Status
                                </th>
                                <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
                                    Performance
                                </th>
                                <th scope="col" className="px-6 py-3 text-left text-xs font-medium text-gray-700 dark:text-gray-300 uppercase tracking-wider">
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
                                            <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300">
                                                {formatDate(metric.timestamp)}
                                            </td>
                                            <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300">
                                                {metric.service_name || metric.service}
                                            </td>
                                            <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300 max-w-xs truncate">
                                                {metric.span_name}
                                            </td>
                                            <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300">
                                                {formatDuration(metric.duration_ms)}
                                            </td>
                                            <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300 max-w-xs truncate">
                                                {metric.http_route || metric.route || '-'}
                                            </td>
                                            <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300">
                                                {metric.http_method || metric.method || '-'}
                                            </td>
                                            <td className="px-6 py-4 whitespace-nowrap">
                                                <span className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${getStatusBadge(metric.http_status_code || metric.status)}`}>
                                                    {metric.http_status_code || metric.status || '-'}
                                                </span>
                                            </td>
                                            <td className="px-6 py-4 whitespace-nowrap">
                                                <span className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${getSlowBadge(metric.is_slow)}`}>
                                                    {metric.is_slow ? 'Slow' : 'Fast'}
                                                </span>
                                            </td>
                                            <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300 font-mono">
                                                {metric.trace_id ? metric.trace_id.substring(0, 8) + '...' : '-'}
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