'use client';

import React, { useState, useCallback, useEffect } from 'react';
import { useAuth } from '@/components/AuthProvider';
import { 
    Search, 
    Activity, 
    Clock, 
    BarChart3, 
    ExternalLink,
    Copy,
    CheckCircle
} from 'lucide-react';
import { Log } from '@/types/logs';
import { TraceSummary, TraceSpan } from '@/types/traces';
import { OtelMetric } from '@/types/otel-metrics';

interface ExtendedTraceSpan extends TraceSpan {
    parsed_attributes?: unknown;
    parsed_events?: unknown;
    parsed_resource_attributes?: unknown;
}

interface CorrelationResult {
    trace_id: string;
    logs: Log[];
    trace_summary: TraceSummary | null;
    spans: ExtendedTraceSpan[];
    metrics: OtelMetric[];
}

// Helper function to safely parse JSON fields that might be strings
const parseJSONField = (field: string | object | null): unknown => {
    if (!field) return null;
    if (typeof field === 'object') return field;
    if (typeof field === 'string') {
        try {
            return JSON.parse(field);
        } catch {
            return null;
        }
    }
    return null;
};

// Helper functions to safely convert values to strings
const safeString = (value: unknown): string => {
    if (value === null || value === undefined) return '';
    return String(value);
};

// Helper function to render span attributes safely
const renderSpanAttributes = (attributes: unknown): React.ReactNode => {
    if (!attributes || typeof attributes !== 'object' || attributes === null) return null;
    
    const attrObj = attributes as Record<string, unknown>;
    if (Object.keys(attrObj).length === 0) return null;
    
    return (
        <div className="mb-4">
            <p className="text-gray-600 dark:text-gray-400 text-xs mb-2">Span Attributes:</p>
            <div className="bg-gray-50 dark:bg-gray-700 p-3 rounded border max-h-32 overflow-y-auto">
                <div className="grid grid-cols-1 gap-1 text-xs">
                    {Object.entries(attrObj).map(([key, value]) => (
                        <div key={key} className="flex justify-between">
                            <span className="text-gray-600 dark:text-gray-400 font-mono">{key}:</span>
                            <span className="text-gray-900 dark:text-white font-mono ml-2 break-all">
                                {value === null ? 'null' : value === undefined ? 'undefined' : typeof value === 'object' ? JSON.stringify(value) : String(value ?? '')}
                            </span>
                        </div>
                    ))}
                </div>
            </div>
        </div>
    );
};

// Helper function to render span events safely
const renderSpanEvents = (events: unknown): React.ReactNode => {
    if (!events || !Array.isArray(events) || events.length === 0) return null;
    
    return (
        <div className="mb-4">
            <p className="text-gray-600 dark:text-gray-400 text-xs mb-2">Span Events:</p>
            <div className="space-y-2">
                {events.map((event: Record<string, unknown>, eventIndex: number) => {
                    const eventName = String(event.name || 'Unknown Event');
                    const eventTime = event.timestamp && typeof event.timestamp === 'number' 
                        ? new Date(event.timestamp / 1e6).toLocaleTimeString() 
                        : 'Unknown Time';
                    
                    const hasAttributes = event.attributes 
                        && typeof event.attributes === 'object' 
                        && event.attributes !== null 
                        && Object.keys(event.attributes as Record<string, unknown>).length > 0;
                    
                    return (
                        <div key={eventIndex} className="bg-gray-50 dark:bg-gray-700 p-2 rounded border">
                            <div className="flex justify-between items-center mb-1">
                                <span className="text-sm font-medium text-gray-900 dark:text-white">
                                    {eventName}
                                </span>
                                <span className="text-xs text-gray-500 dark:text-gray-400">
                                    {eventTime}
                                </span>
                            </div>
                            {(() => {
                                if (!hasAttributes) return null;
                                return (
                                    <div className="text-xs text-gray-600 dark:text-gray-400">
                                        {Object.entries(event.attributes as Record<string, unknown>).map(([key, value]) => (
                                            <div key={key} className="flex">
                                                <span className="font-mono">{key}: </span>
                                                <span className="font-mono ml-1">
                                                    {value === null ? 'null' : value === undefined ? 'undefined' : typeof value === 'object' ? JSON.stringify(value) : String(value)}
                                                </span>
                                            </div>
                                        ))}
                                    </div>
                                );
                            })()}
                        </div>
                    );
                })}
            </div>
        </div>
    );
};

// Component to render span details
function SpanDetails({ span }: { span: ExtendedTraceSpan }): React.ReactElement {
    const spanId = safeString(span.span_id) || '';
    const parentSpanId = safeString(span.parent_span_id) || 'None (Root)';
    const serviceName = safeString(span.service_name) || 'Unknown';
    const spanKind = safeString(span.kind) || 'Unknown';
    const statusMessage = safeString(span.status_message);

    return (
        <div className="border-t border-gray-200 dark:border-gray-600 p-3 bg-white dark:bg-gray-800">
            <h5 className="text-sm font-semibold text-gray-900 dark:text-white mb-3">
                Span Details
            </h5>
            
            <div className="grid grid-cols-1 md:grid-cols-2 gap-3 text-xs mb-4">
                <div>
                    <p className="text-gray-600 dark:text-gray-400">Span ID:</p>
                    <p className="font-mono text-gray-900 dark:text-white break-all">{spanId}</p>
                </div>
                <div>
                    <p className="text-gray-600 dark:text-gray-400">Parent Span ID:</p>
                    <p className="font-mono text-gray-900 dark:text-white break-all">{parentSpanId}</p>
                </div>
                <div>
                    <p className="text-gray-600 dark:text-gray-400">Service:</p>
                    <p className="text-gray-900 dark:text-white">{serviceName}</p>
                </div>
                <div>
                    <p className="text-gray-600 dark:text-gray-400">Span Kind:</p>
                    <p className="text-gray-900 dark:text-white">{spanKind}</p>
                </div>
            </div>
            
            {renderSpanAttributes(span.parsed_attributes)}

            {renderSpanEvents(span.parsed_events)}

            {statusMessage && (
                <div className="mb-4">
                    <p className="text-gray-600 dark:text-gray-400 text-xs">Status Message:</p>
                    <p className="text-gray-900 dark:text-white text-sm bg-gray-50 dark:bg-gray-700 p-2 rounded border">
                        {statusMessage}
                    </p>
                </div>
            )}
        </div>
    );
}

const CorrelationDashboard = ({ initialTraceId }: { initialTraceId?: string }) => {
    const { token } = useAuth();
    const [traceId, setTraceId] = useState(initialTraceId || '');
    const [loading, setLoading] = useState(false);
    const [result, setResult] = useState<CorrelationResult | null>(null);
    const [error, setError] = useState<string | null>(null);
    const [copiedTraceId, setCopiedTraceId] = useState(false);
    const [expandedSpan, setExpandedSpan] = useState<number | null>(null);

    const postQuery = useCallback(async <T,>(query: string): Promise<T> => {
        const response = await fetch('/api/query', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                ...(token && { Authorization: `Bearer ${token}` })
            },
            body: JSON.stringify({ query, limit: 100 }),
            cache: 'no-store',
        });

        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.error || 'Failed to execute query');
        }

        return response.json();
    }, [token]);

    const searchByTraceId = useCallback(async () => {
        if (!traceId.trim()) {
            setError('Please enter a trace ID');
            return;
        }

        setLoading(true);
        setError(null);

        try {
            // Execute all correlation queries in parallel with proper error handling
            const [logsRes, traceSummaryRes, spansRes, metricsRes] = await Promise.all([
                postQuery<{ results: Log[] }>(`in:logs trace_id:${traceId} time:last_24h sort:timestamp:asc limit:200`).catch(() => ({ results: [] })),
                postQuery<{ results: TraceSummary[] }>(`in:otel_trace_summaries trace_id:${traceId} time:last_24h limit:5`).catch(() => ({ results: [] })),
                postQuery<{ results: TraceSpan[] }>(`in:otel_traces trace_id:${traceId} time:last_24h sort:start_time_unix_nano:asc limit:500`).catch(() => ({ results: [] })),
                postQuery<{ results: OtelMetric[] }>(`in:otel_metrics trace_id:${traceId} time:last_24h sort:timestamp:asc limit:200`).catch(() => ({ results: [] }))
            ]);

            // Parse span data to handle JSON strings for attributes and events
            const parsedSpans = (spansRes.results || []).map(span => ({
                ...span,
                attributes: span.attributes, // Keep as string to match TraceSpan interface
                events: span.events, // Keep as string to match TraceSpan interface
                resource_attributes: span.resource_attributes, // Keep as string to match TraceSpan interface
                parsed_attributes: parseJSONField(span.attributes),
                parsed_events: parseJSONField(span.events),
                parsed_resource_attributes: parseJSONField(span.resource_attributes)
            }));

            setResult({
                trace_id: traceId,
                logs: logsRes.results || [],
                trace_summary: traceSummaryRes.results?.[0] || null,
                spans: parsedSpans,
                metrics: metricsRes.results || []
            });
        } catch (e) {
            setError(e instanceof Error ? e.message : "An unknown error occurred.");
            setResult(null);
        } finally {
            setLoading(false);
        }
    }, [traceId, postQuery]);

    const copyTraceId = useCallback(async () => {
        if (result?.trace_id) {
            await navigator.clipboard.writeText(result.trace_id);
            setCopiedTraceId(true);
            setTimeout(() => setCopiedTraceId(false), 2000);
        }
    }, [result?.trace_id]);

    // Automatically search if initialTraceId is provided
    useEffect(() => {
        if (initialTraceId && initialTraceId.trim()) {
            searchByTraceId();
        }
    }, [initialTraceId, searchByTraceId]);

    const formatDate = (dateString: string) => {
        try {
            return new Date(dateString).toLocaleString();
        } catch {
            return 'Invalid Date';
        }
    };

    const formatDuration = (ms: number): string => {
        if (ms >= 1000) {
            return (ms / 1000).toFixed(2) + 's';
        }
        return Math.round(ms) + 'ms';
    };

    const getSeverityBadge = (severity: string) => {
        const upperSeverity = severity?.toUpperCase() || '';
        switch (upperSeverity) {
            case 'ERROR':
            case 'FATAL':
            case 'CRITICAL':
                return 'bg-red-100 dark:bg-red-600/50 text-red-800 dark:text-red-200 border border-red-300 dark:border-red-500/60';
            case 'WARN':
            case 'WARNING':
                return 'bg-orange-100 dark:bg-orange-500/50 text-orange-800 dark:text-orange-200 border border-orange-300 dark:border-orange-400/60';
            case 'INFO':
                return 'bg-sky-100 dark:bg-sky-600/50 text-sky-800 dark:text-sky-200 border border-sky-300 dark:border-sky-500/60';
            default:
                return 'bg-gray-100 dark:bg-gray-600/50 text-gray-800 dark:text-gray-200 border border-gray-300 dark:border-gray-500/60';
        }
    };

    return (
        <div className="space-y-6">
            {/* Search Section */}
            <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg shadow-lg p-6">
                <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Trace Correlation</h2>
                <p className="text-gray-600 dark:text-gray-400 mb-4">
                    Enter a trace ID to see all related logs, traces, and metrics across your system.
                </p>
                
                <div className="flex gap-4">
                    <div className="relative flex-1">
                        <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 h-5 w-5 text-gray-400" />
                        <input
                            type="text"
                            placeholder="Enter trace ID (e.g., 1234567890abcdef)"
                            value={traceId}
                            onChange={(e) => setTraceId(e.target.value)}
                            onKeyPress={(e) => e.key === 'Enter' && searchByTraceId()}
                            className="w-full pl-10 pr-4 py-3 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-orange-500 focus:border-orange-500"
                        />
                    </div>
                    <button
                        onClick={searchByTraceId}
                        disabled={loading}
                        className="px-6 py-3 bg-orange-600 hover:bg-orange-700 disabled:bg-gray-400 text-white rounded-lg font-medium transition-colors"
                    >
                        {loading ? 'Searching...' : 'Search'}
                    </button>
                </div>
                
                {error && (
                    <div className="mt-4 p-3 bg-red-100 dark:bg-red-900/30 border border-red-300 dark:border-red-700 rounded-lg text-red-700 dark:text-red-300">
                        {error}
                    </div>
                )}
            </div>

            {/* Results Section */}
            {result && (
                <div className="space-y-6">
                    {/* Trace Summary */}
                    <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg shadow-lg p-6">
                        <div className="flex items-center justify-between mb-4">
                            <h3 className="text-lg font-semibold text-gray-900 dark:text-white">Trace Summary</h3>
                            <button
                                onClick={copyTraceId}
                                className="flex items-center gap-2 px-3 py-1 text-sm bg-gray-100 dark:bg-gray-700 hover:bg-gray-200 dark:hover:bg-gray-600 rounded-md transition-colors"
                            >
                                {copiedTraceId ? (
                                    <>
                                        <CheckCircle className="h-4 w-4 text-green-500" />
                                        Copied!
                                    </>
                                ) : (
                                    <>
                                        <Copy className="h-4 w-4" />
                                        Copy Trace ID
                                    </>
                                )}
                            </button>
                        </div>
                        
                        {result.trace_summary ? (
                            <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
                                <div className="p-4 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
                                    <div className="flex items-center gap-2 mb-2">
                                        <Clock className="h-5 w-5 text-blue-500" />
                                        <span className="font-medium">Duration</span>
                                    </div>
                                    <p className="text-2xl font-bold text-gray-900 dark:text-white">
                                        {formatDuration(result.trace_summary.duration_ms)}
                                    </p>
                                </div>
                                <div className="p-4 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
                                    <div className="flex items-center gap-2 mb-2">
                                        <Activity className="h-5 w-5 text-green-500" />
                                        <span className="font-medium">Spans</span>
                                    </div>
                                    <p className="text-2xl font-bold text-gray-900 dark:text-white">
                                        {result.trace_summary.span_count}
                                    </p>
                                </div>
                                <div className="p-4 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
                                    <div className="flex items-center gap-2 mb-2">
                                        <BarChart3 className="h-5 w-5 text-purple-500" />
                                        <span className="font-medium">Services</span>
                                    </div>
                                    <p className="text-2xl font-bold text-gray-900 dark:text-white">
                                        {result.trace_summary.service_set?.length || 1}
                                    </p>
                                </div>
                                <div className="p-4 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
                                    <div className="flex items-center gap-2 mb-2">
                                        <ExternalLink className="h-5 w-5 text-orange-500" />
                                        <span className="font-medium">Status</span>
                                    </div>
                                    <span className={`px-2 py-1 text-sm font-semibold rounded-full ${
                                        result.trace_summary.status_code === 1 && result.trace_summary.error_count === 0
                                            ? 'bg-green-100 text-green-800 dark:bg-green-600/50 dark:text-green-200'
                                            : 'bg-red-100 text-red-800 dark:bg-red-600/50 dark:text-red-200'
                                    }`}>
                                        {result.trace_summary.status_code === 1 && result.trace_summary.error_count === 0 ? 'Success' : 'Error'}
                                    </span>
                                </div>
                            </div>
                        ) : (
                            <p className="text-gray-600 dark:text-gray-400">No trace summary found for this trace ID.</p>
                        )}
                    </div>

                    {/* Stats Cards */}
                    <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                        <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg shadow p-4">
                            <div className="flex items-center justify-between">
                                <div>
                                    <h4 className="text-sm font-medium text-gray-600 dark:text-gray-400">Logs Found</h4>
                                    <p className="text-2xl font-bold text-gray-900 dark:text-white">{result.logs.length}</p>
                                </div>
                                <Activity className="h-8 w-8 text-blue-500" />
                            </div>
                        </div>
                        <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg shadow p-4">
                            <div className="flex items-center justify-between">
                                <div>
                                    <h4 className="text-sm font-medium text-gray-600 dark:text-gray-400">Spans Found</h4>
                                    <p className="text-2xl font-bold text-gray-900 dark:text-white">{result.spans.length}</p>
                                </div>
                                <Clock className="h-8 w-8 text-green-500" />
                            </div>
                        </div>
                        <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg shadow p-4">
                            <div className="flex items-center justify-between">
                                <div>
                                    <h4 className="text-sm font-medium text-gray-600 dark:text-gray-400">Metrics Found</h4>
                                    <p className="text-2xl font-bold text-gray-900 dark:text-white">{result.metrics.length}</p>
                                </div>
                                <BarChart3 className="h-8 w-8 text-purple-500" />
                            </div>
                        </div>
                    </div>

                    {/* Detailed Results */}
                    <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
                        {/* Logs */}
                        <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg shadow-lg">
                            <div className="p-4 border-b border-gray-200 dark:border-gray-700">
                                <h4 className="font-semibold text-gray-900 dark:text-white flex items-center gap-2">
                                    <Activity className="h-5 w-5 text-blue-500" />
                                    Logs ({result.logs.length})
                                </h4>
                            </div>
                            <div className="p-4 max-h-96 overflow-y-auto">
                                {result.logs.length === 0 ? (
                                    <p className="text-gray-600 dark:text-gray-400 text-sm">No logs found for this trace.</p>
                                ) : (
                                    <div className="space-y-3">
                                        {result.logs.map((log, index) => (
                                            <div key={index} className="p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
                                                <div className="flex items-center justify-between mb-2">
                                                    <span className={`px-2 py-1 text-xs font-semibold rounded-full ${getSeverityBadge(log.severity_text || '')}`}>
                                                        {log.severity_text || 'Unknown'}
                                                    </span>
                                                    <span className="text-xs text-gray-500 dark:text-gray-400">
                                                        {formatDate(log.timestamp)}
                                                    </span>
                                                </div>
                                                <p className="text-sm text-gray-900 dark:text-white">{log.service_name || 'Unknown Service'}</p>
                                                <p className="text-xs text-gray-600 dark:text-gray-400 mt-1 line-clamp-2">
                                                    {log.body}
                                                </p>
                                            </div>
                                        ))}
                                    </div>
                                )}
                            </div>
                        </div>

                        {/* Spans */}
                        <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg shadow-lg">
                            <div className="p-4 border-b border-gray-200 dark:border-gray-700">
                                <h4 className="font-semibold text-gray-900 dark:text-white flex items-center gap-2">
                                    <Clock className="h-5 w-5 text-green-500" />
                                    Spans ({result.spans.length})
                                </h4>
                            </div>
                            <div className="p-4 max-h-96 overflow-y-auto">
                                {result.spans.length === 0 ? (
                                    <p className="text-gray-600 dark:text-gray-400 text-sm">No spans found for this trace.</p>
                                ) : (
                                    <div className="space-y-3">
                                        {result.spans.map((span: ExtendedTraceSpan, index: number) => (
                                            <div key={index} className="bg-gray-50 dark:bg-gray-700/50 rounded-lg">
                                                <div className="p-3">
                                                    <div className="flex items-center justify-between mb-2">
                                                        <span className="text-sm font-medium text-gray-900 dark:text-white truncate">
                                                            {safeString(span.name) || 'Unknown Span'}
                                                        </span>
                                                        <span className="text-xs text-gray-500 dark:text-gray-400">
                                                            {formatDuration((Number(span.end_time_unix_nano || 0) - Number(span.start_time_unix_nano || 0)) / 1e6)}
                                                        </span>
                                                    </div>
                                                    <p className="text-xs text-gray-600 dark:text-gray-400">{safeString(span.service_name) || 'Unknown Service'}</p>
                                                    <div className="flex items-center gap-2 mt-1">
                                                        <button
                                                            onClick={() => setExpandedSpan(expandedSpan === index ? null : index)}
                                                            className={`px-2 py-1 text-xs font-semibold rounded-full transition-all hover:shadow-md hover:scale-105 cursor-pointer ${
                                                                Number(span.status_code) === 1 
                                                                    ? 'bg-green-100 text-green-800 dark:bg-green-600/50 dark:text-green-200 hover:bg-green-200 dark:hover:bg-green-600/70'
                                                                    : 'bg-red-100 text-red-800 dark:bg-red-600/50 dark:text-red-200 hover:bg-red-200 dark:hover:bg-red-600/70'
                                                            }`}
                                                            title="Click to see detailed status analysis"
                                                        >
                                                            {Number(span.status_code) === 1 ? 'OK' : 'Error'}
                                                        </button>
                                                        <span className="text-xs text-gray-500 dark:text-gray-400">
                                                            span_id: {(safeString(span.span_id) || '').substring(0, 8)}...
                                                        </span>
                                                    </div>
                                                </div>
                                                
                                                {/* Expanded Span Details */}
                                                {expandedSpan === index && <SpanDetails span={span} />}
                                            </div>
                                        ))}
                                    </div>
                                )}
                            </div>
                        </div>

                        {/* Metrics */}
                        <div className="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-700 rounded-lg shadow-lg">
                            <div className="p-4 border-b border-gray-200 dark:border-gray-700">
                                <h4 className="font-semibold text-gray-900 dark:text-white flex items-center gap-2">
                                    <BarChart3 className="h-5 w-5 text-purple-500" />
                                    Metrics ({result.metrics.length})
                                </h4>
                            </div>
                            <div className="p-4 max-h-96 overflow-y-auto">
                                {result.metrics.length === 0 ? (
                                    <p className="text-gray-600 dark:text-gray-400 text-sm">No metrics found for this trace.</p>
                                ) : (
                                    <div className="space-y-3">
                                        {result.metrics.map((metric, index) => (
                                            <div key={index} className="p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
                                                <div className="flex items-center justify-between mb-2">
                                                    <span className="text-sm font-medium text-gray-900 dark:text-white truncate">
                                                        {metric.span_name}
                                                    </span>
                                                    <span className="text-xs text-gray-500 dark:text-gray-400">
                                                        {formatDuration(metric.duration_ms)}
                                                    </span>
                                                </div>
                                                <p className="text-xs text-gray-600 dark:text-gray-400">{metric.service_name || 'Unknown Service'}</p>
                                                {metric.http_route && (
                                                    <p className="text-xs text-gray-600 dark:text-gray-400 mt-1">
                                                        {metric.http_method || 'GET'} {metric.http_route || 'Unknown Route'}
                                                    </p>
                                                )}
                                                <div className="flex items-center gap-2 mt-1">
                                                    <span className={`px-2 py-1 text-xs font-semibold rounded-full ${
                                                        metric.is_slow
                                                            ? 'bg-red-100 text-red-800 dark:bg-red-600/50 dark:text-red-200'
                                                            : 'bg-green-100 text-green-800 dark:bg-green-600/50 dark:text-green-200'
                                                    }`}>
                                                        {metric.is_slow ? 'Slow' : 'Fast'}
                                                    </span>
                                                    {metric.http_status_code && (
                                                        <span className="text-xs text-gray-600 dark:text-gray-400">
                                                            {metric.http_status_code}
                                                        </span>
                                                    )}
                                                </div>
                                            </div>
                                        ))}
                                    </div>
                                )}
                            </div>
                        </div>
                    </div>
                </div>
            )}
        </div>
    );
};

export default CorrelationDashboard;
