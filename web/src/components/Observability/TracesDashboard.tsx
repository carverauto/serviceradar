'use client';

import React, { useState, useEffect, useCallback, useRef, useMemo, Fragment } from 'react';
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
    Check,
    Radio,
    Wifi,
    WifiOff,
    Play,
    Pause,
    ChevronLeft,
    ChevronRight as ChevronRightIcon,
    ChevronsDown
} from 'lucide-react';
import { useDebounce } from 'use-debounce';
import { cachedQuery } from '@/lib/cached-query';
import { createStreamingClient, StreamingClient } from '@/lib/streaming-client';

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
    const [sortOrder, setSortOrder] = useState<'asc' | 'desc'>('asc'); // Default to chronological order for streaming
    const [expandedRow, setExpandedRow] = useState<string | null>(null);
    
    // Streaming state
    const [streamingEnabled, setStreamingEnabled] = useState(false);
    const [streamingConnected, setStreamingConnected] = useState(false);
    const [streamingAvailable, setStreamingAvailable] = useState(true);
    const [streamingPaused, setStreamingPaused] = useState(false);
    const streamingClient = useRef<StreamingClient | null>(null);
    const [streamingTraces, setStreamingTraces] = useState<TraceSummary[]>([]);
    
    // Client-side pagination for streaming traces
    const [streamingCurrentPage, setStreamingCurrentPage] = useState(1);
    const streamingTracesPerPage = 20;
    const maxStreamingHistory = 1000; // Keep ~4 cycles worth (250 traces per cycle × 4 = 1000)
    
    // Track if user is viewing the latest traces (for auto-advance behavior)
    const [autoFollowLatest, setAutoFollowLatest] = useState(true);

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
                cachedQuery<{ results: [{ 'count()': number }] }>('COUNT otel_trace_summaries_final', token || undefined, 30000),
                cachedQuery<{ results: [{ 'count()': number }] }>('COUNT otel_trace_summaries_final WHERE status_code = 1', token || undefined, 30000),
                cachedQuery<{ results: [{ 'count()': number }] }>('COUNT otel_trace_summaries_final WHERE status_code != 1 OR error_count > 0', token || undefined, 30000),
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
            const query = 'SHOW DISTINCT(root_service_name) FROM otel_trace_summaries_final WHERE root_service_name IS NOT NULL LIMIT 100';
            const response = await postQuery<{ results: Array<{ root_service_name: string }> }>(query);
            const serviceNames = response.results?.map(r => r.root_service_name).filter(Boolean) || [];
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
            let query = 'SHOW otel_trace_summaries_final';
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
            setTraces(response.results || []);
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

    const buildStreamingQuery = useCallback(() => {
        let query = 'SHOW otel_trace_summaries_final';
        const conditions: string[] = [];

        if (debouncedSearchTerm) {
            conditions.push(`(trace_id LIKE '%${debouncedSearchTerm}%' OR root_service_name LIKE '%${debouncedSearchTerm}%' OR root_span_name LIKE '%${debouncedSearchTerm}%')`);
        }

        if (filterService !== 'all') {
            conditions.push(`root_service_name = '${filterService}'`);
        }

        if (filterStatus === 'success') {
            conditions.push('status_code = 1 AND error_count = 0');
        } else if (filterStatus === 'error') {
            conditions.push('(status_code != 1 OR error_count > 0)');
        }

        if (conditions.length > 0) {
            query += ` WHERE ${conditions.join(' AND ')}`;
        }

        query += ` ORDER BY ${sortBy === 'timestamp' ? '_tp_time' : sortBy} ${sortOrder.toUpperCase()}`;
        
        // Debug: Log the streaming query being used
        console.log('📡 Streaming query:', query);
        console.log('📡 Active filters - Status:', filterStatus, 'Service:', filterService, 'Search:', debouncedSearchTerm);
        
        return query;
    }, [debouncedSearchTerm, filterService, filterStatus, sortBy, sortOrder]);

    const startStreaming = useCallback(() => {
        // Prevent multiple simultaneous connection attempts
        if (streamingClient.current && streamingClient.current.isConnected()) {
            console.log('📡 Streaming already connected, skipping duplicate start request');
            return;
        }

        if (streamingClient.current) {
            console.log('📡 Disconnecting existing streaming client before starting new one');
            streamingClient.current.disconnect();
        }

        const query = buildStreamingQuery();
        console.log('📡 Creating new streaming client for query:', query);
        
        streamingClient.current = createStreamingClient({
            onData: (data) => {
                // The data comes as a map[string]interface{} from the backend
                // We need to ensure it has the required fields for the TraceSummary type
                const trace: TraceSummary = {
                    timestamp: (data.timestamp as string) || (data._tp_time as string) || '',
                    trace_id: (data.trace_id as string) || '',
                    root_span_id: (data.root_span_id as string) || '',
                    root_span_name: (data.root_span_name as string) || '',
                    root_service_name: (data.root_service_name as string) || '',
                    root_span_kind: (data.root_span_kind as number) || 0,
                    start_time_unix_nano: (data.start_time_unix_nano as number) || 0,
                    end_time_unix_nano: (data.end_time_unix_nano as number) || 0,
                    duration_ms: (data.duration_ms as number) || 0,
                    status_code: (data.status_code as number) || 0,
                    status_message: (data.status_message as string) || '',
                    service_set: (data.service_set as string[]) || [],
                    span_count: (data.span_count as number) || 0,
                    error_count: (data.error_count as number) || 0
                };
                
                // Only add trace if streaming is not paused
                if (!streamingPaused) {
                    setStreamingTraces(prev => {
                        // Append new trace to the end (CloudWatch style)
                        const newTraces = [...prev, trace];
                        // Debug: Log the count every 50 messages (every ~1/5 cycle)
                        if (newTraces.length % 50 === 0) {
                            console.log(`📊 Streaming traces count: ${newTraces.length} (${Math.floor(newTraces.length / 250)} cycles)`);
                        }
                        // Keep up to maxStreamingHistory traces, remove oldest when exceeded
                        return newTraces.length > maxStreamingHistory ? newTraces.slice(-maxStreamingHistory) : newTraces;
                    });
                }
                // If paused, just ignore the trace (could add to a buffer if needed later)
                // Clear any previous errors when receiving data successfully
                setError(null);
            },
            onError: (error) => {
                console.error('Streaming error:', error);
                
                // Only show critical errors that affect functionality, not connection issues
                if (error.includes('authentication failed') || error.includes('not supported') || 
                    error.includes('not available') || error.includes('server rejected')) {
                    setError(`Streaming error: ${error}`);
                }
                
                // Check if error indicates streaming is not available
                if (error.includes('not yet available') || error.includes('not available')) {
                    setStreamingAvailable(false);
                    setStreamingEnabled(false);
                }
            },
            onComplete: () => {
                console.log('Streaming completed');
            },
            onConnection: (connected) => {
                setStreamingConnected(connected);
                // Clear errors when successfully connected
                if (connected) {
                    setError(null);
                }
            }
        });

        streamingClient.current.connect(query);
    }, [buildStreamingQuery, streamingPaused]);

    const stopStreaming = useCallback(() => {
        if (streamingClient.current) {
            streamingClient.current.disconnect();
            streamingClient.current = null;
        }
        setStreamingConnected(false);
        setStreamingTraces([]);
        setStreamingCurrentPage(1);
        setStreamingPaused(false);
        setAutoFollowLatest(true);
    }, []);

    const pauseStreaming = useCallback(() => {
        setStreamingPaused(true);
    }, []);

    const resumeStreaming = useCallback(() => {
        setStreamingPaused(false);
    }, []);

    const toggleStreaming = useCallback(() => {
        console.log('📡 toggleStreaming called, current state:', streamingEnabled);
        if (streamingEnabled) {
            console.log('📡 Stopping streaming...');
            stopStreaming();
            setStreamingEnabled(false);
        } else {
            console.log('📡 Enabling streaming (useEffect will handle the actual start)...');
            // Clear regular traces when switching to streaming mode
            // This prevents showing old paginated data
            setTraces([]);
            setPagination(null);
            setStreamingCurrentPage(1); // Reset to first page
            setAutoFollowLatest(true); // Enable auto-follow for new stream
            setStreamingEnabled(true);
            // Don't call startStreaming() here - let the useEffect handle it to avoid double calls
        }
    }, [streamingEnabled, stopStreaming]);

    useEffect(() => {
        // Cleanup on unmount
        return () => {
            if (streamingClient.current) {
                streamingClient.current.disconnect();
            }
        };
    }, []);

    useEffect(() => {
        // Start/restart streaming when filters change or streaming is enabled
        console.log('📡 useEffect: streamingEnabled changed to:', streamingEnabled);
        if (streamingEnabled) {
            console.log('📡 useEffect: Starting streaming...');
            startStreaming();
        }
    }, [streamingEnabled, startStreaming]);

    useEffect(() => {
        fetchStats();
        fetchServices();
    }, [fetchStats, fetchServices]);

    useEffect(() => {
        // Fetch traces when dependencies change (only if streaming is disabled)
        if (!streamingEnabled) {
            fetchTraces();
        }
        // Don't fetch regular traces when streaming is enabled
        // We only want to show streaming data
    }, [fetchTraces, streamingEnabled]);

    // Combine and sort traces from both sources when streaming is enabled
    const allTraces = useMemo(() => {
        if (!streamingEnabled) {
            return traces;
        }

        // When streaming is enabled, show only streaming traces
        // Sort streaming traces by timestamp
        const sortedTraces = [...streamingTraces].sort((a, b) => {
            const dateA = new Date(a.timestamp).getTime();
            const dateB = new Date(b.timestamp).getTime();
            return sortOrder === 'desc' ? dateB - dateA : dateA - dateB;
        });

        return sortedTraces;
    }, [streamingEnabled, streamingTraces, traces, sortOrder]);

    // Calculate streaming pagination info
    const streamingTotalPages = Math.ceil(allTraces.length / streamingTracesPerPage);
    const streamingHasNextPage = streamingCurrentPage < streamingTotalPages;
    const streamingHasPrevPage = streamingCurrentPage > 1;
    const isOnLatestPage = streamingCurrentPage === streamingTotalPages;

    // Paginated streaming traces
    const paginatedStreamingTraces = useMemo(() => {
        if (!streamingEnabled) return [];
        
        const startIndex = (streamingCurrentPage - 1) * streamingTracesPerPage;
        const endIndex = startIndex + streamingTracesPerPage;
        return allTraces.slice(startIndex, endIndex);
    }, [streamingEnabled, allTraces, streamingCurrentPage, streamingTracesPerPage]);

    // Auto-advance to latest page when new traces arrive (only if user was already on latest)
    useEffect(() => {
        if (streamingEnabled && autoFollowLatest && streamingTotalPages > 0) {
            const newLatestPage = streamingTotalPages;
            if (streamingCurrentPage !== newLatestPage) {
                setStreamingCurrentPage(newLatestPage);
            }
        }
    }, [streamingEnabled, streamingTotalPages, autoFollowLatest, streamingCurrentPage]);

    // Update auto-follow when user manually navigates
    const handlePageChange = useCallback((newPage: number) => {
        setStreamingCurrentPage(newPage);
        // Enable auto-follow only if user navigates to the latest page
        setAutoFollowLatest(newPage === streamingTotalPages);
    }, [streamingTotalPages]);

    const goToLatestPage = useCallback(() => {
        setStreamingCurrentPage(streamingTotalPages);
        setAutoFollowLatest(true);
    }, [streamingTotalPages]);

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

                            <div className="flex items-center gap-2">
                                <label htmlFor="streamingToggle" className="text-xs text-gray-700 dark:text-gray-300 whitespace-nowrap">
                                    Streaming:
                                </label>
                                <div className="flex items-center gap-1">
                                    <button
                                        id="streamingToggle"
                                        onClick={streamingAvailable ? toggleStreaming : undefined}
                                        disabled={!streamingAvailable}
                                        className={`flex items-center gap-1 px-3 py-1 rounded-lg text-xs font-medium transition-colors ${
                                            !streamingAvailable 
                                                ? 'bg-gray-50 dark:bg-gray-800 text-gray-400 dark:text-gray-500 border border-gray-200 dark:border-gray-700 cursor-not-allowed'
                                                : streamingEnabled
                                                ? 'bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-300 border border-green-300 dark:border-green-700'
                                                : 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 border border-gray-300 dark:border-gray-600 hover:bg-gray-200 dark:hover:bg-gray-600'
                                        }`}
                                        title={
                                            !streamingAvailable 
                                                ? 'Streaming not available on this server version'
                                                : streamingEnabled 
                                                ? 'Disable streaming' 
                                                : 'Enable real-time streaming'
                                        }
                                    >
                                        {streamingEnabled ? (
                                            <>
                                                {streamingConnected ? (
                                                    <Wifi className="h-3 w-3" />
                                                ) : (
                                                    <WifiOff className="h-3 w-3" />
                                                )}
                                                Live
                                            </>
                                        ) : (
                                            <>
                                                <Radio className="h-3 w-3" />
                                                Enable
                                            </>
                                        )}
                                    </button>
                                    
                                    {streamingEnabled && streamingConnected && (
                                        <button
                                            onClick={streamingPaused ? resumeStreaming : pauseStreaming}
                                            className={`flex items-center gap-1 px-2 py-1 rounded text-xs font-medium transition-colors ${
                                                streamingPaused
                                                    ? 'bg-blue-100 dark:bg-blue-900/30 text-blue-700 dark:text-blue-300 border border-blue-300 dark:border-blue-700 hover:bg-blue-200 dark:hover:bg-blue-800/40'
                                                    : 'bg-orange-100 dark:bg-orange-900/30 text-orange-700 dark:text-orange-300 border border-orange-300 dark:border-orange-700 hover:bg-orange-200 dark:hover:bg-orange-800/40'
                                            }`}
                                            title={streamingPaused ? 'Resume streaming' : 'Pause streaming'}
                                        >
                                            {streamingPaused ? (
                                                <Play className="h-3 w-3" />
                                            ) : (
                                                <Pause className="h-3 w-3" />
                                            )}
                                        </button>
                                    )}
                                </div>
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
                            {(streamingEnabled && !streamingConnected && streamingTraces.length === 0) ? (
                                <tr>
                                    <td colSpan={7} className="text-center p-8">
                                        <div className="flex items-center justify-center gap-2">
                                            <Loader2 className="h-8 w-8 text-orange-400 animate-spin" />
                                            <span className="text-gray-600 dark:text-gray-400">Connecting to stream...</span>
                                        </div>
                                    </td>
                                </tr>
                            ) : tracesLoading && !streamingEnabled ? (
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
                            ) : (streamingEnabled ? paginatedStreamingTraces : allTraces).length === 0 ? (
                                <tr>
                                    <td colSpan={7} className="text-center p-8 text-gray-600 dark:text-gray-400">
                                        {streamingEnabled ? 'No streaming data yet...' : 'No traces found.'}
                                    </td>
                                </tr>
                            ) : (
                                (streamingEnabled ? paginatedStreamingTraces : allTraces).map((trace, index) => {
                                    const uniqueKey = `${trace.trace_id}-${trace.timestamp}-${index}`;
                                    const expandKey = `${trace.trace_id}-${trace.timestamp}-${index}`;
                                    return (
                                        <Fragment key={uniqueKey}>
                                            <tr className="hover:bg-gray-100 dark:hover:bg-gray-700/30">
                                                <td className="pl-2">
                                                    <button
                                                        onClick={() => setExpandedRow(expandedRow === expandKey ? null : expandKey)}
                                                        className="p-1 rounded-full hover:bg-gray-200 dark:hover:bg-gray-600 text-gray-600 dark:text-gray-400"
                                                    >
                                                        {expandedRow === expandKey ? (
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
                                                    <button
                                                        onClick={(e) => {
                                                            e.stopPropagation();
                                                            setExpandedRow(expandedRow === expandKey ? null : expandKey);
                                                        }}
                                                        className={`px-1.5 py-0.5 inline-flex text-xs leading-4 font-semibold rounded-full transition-all hover:shadow-md hover:scale-105 cursor-pointer ${getStatusBadge(trace.status_code, trace.error_count)}`}
                                                        title="Click to see detailed status analysis"
                                                    >
                                                        {trace.status_code === 1 && trace.error_count === 0 ? 'OK' : 'ERR'}
                                                    </button>
                                                </td>
                                            </tr>

                                            {expandedRow === expandKey && (
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
                                                                    <div>
                                                                        <p className="text-gray-600 dark:text-gray-400">Status Code:</p>
                                                                        <p className="text-gray-900 dark:text-white">{trace.status_code}</p>
                                                                    </div>
                                                                    <div>
                                                                        <p className="text-gray-600 dark:text-gray-400">Duration:</p>
                                                                        <p className="text-gray-900 dark:text-white">{formatDuration(trace.duration_ms)}</p>
                                                                    </div>
                                                                </div>
                                                            </div>
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

                {!streamingEnabled && pagination && (pagination.prev_cursor || pagination.next_cursor) && (
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

                {streamingEnabled && (
                    <div className="p-4 border-t border-gray-200 dark:border-gray-700">
                        <div className="flex items-center justify-between">
                            <div className="flex items-center gap-2">
                                {streamingConnected ? (
                                    <div className="flex items-center gap-2 text-green-600 dark:text-green-400">
                                        <Wifi className="h-4 w-4" />
                                        <span className="text-sm">
                                            {streamingPaused 
                                                ? 'Stream paused' 
                                                : autoFollowLatest 
                                                    ? 'Streaming live data' 
                                                    : 'Streaming (viewing history)'
                                            }
                                        </span>
                                    </div>
                                ) : (
                                    <div className="flex items-center gap-2 text-orange-600 dark:text-orange-400">
                                        <WifiOff className="h-4 w-4" />
                                        <span className="text-sm">Connecting...</span>
                                    </div>
                                )}
                            </div>
                            <div className="flex items-center gap-4">
                                {/* Streaming pagination */}
                                {streamingTotalPages > 1 && (
                                    <div className="flex items-center gap-2">
                                        <button
                                            onClick={() => handlePageChange(Math.max(1, streamingCurrentPage - 1))}
                                            disabled={!streamingHasPrevPage}
                                            className="p-1 rounded text-gray-600 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-700 disabled:opacity-50 disabled:cursor-not-allowed"
                                            title="Previous page"
                                        >
                                            <ChevronLeft className="h-4 w-4" />
                                        </button>
                                        <span className="text-xs text-gray-500 dark:text-gray-400">
                                            Page {streamingCurrentPage} of {streamingTotalPages}
                                        </span>
                                        <button
                                            onClick={() => handlePageChange(Math.min(streamingTotalPages, streamingCurrentPage + 1))}
                                            disabled={!streamingHasNextPage}
                                            className="p-1 rounded text-gray-600 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-700 disabled:opacity-50 disabled:cursor-not-allowed"
                                            title="Next page"
                                        >
                                            <ChevronRightIcon className="h-4 w-4" />
                                        </button>
                                        {/* Go to latest button - only show when not on latest page */}
                                        {!isOnLatestPage && (
                                            <button
                                                onClick={goToLatestPage}
                                                className="ml-2 p-1 rounded text-blue-600 dark:text-blue-400 hover:bg-blue-100 dark:hover:bg-blue-900/30 transition-colors"
                                                title="Go to latest traces"
                                            >
                                                <ChevronsDown className="h-4 w-4" />
                                            </button>
                                        )}
                                    </div>
                                )}
                                <div className="text-sm text-gray-500 dark:text-gray-400">
                                    {streamingTraces.length} trace{streamingTraces.length !== 1 ? 's' : ''} received
                                </div>
                            </div>
                        </div>
                    </div>
                )}
            </div>
        </div>
    );
};

export default TracesDashboard;