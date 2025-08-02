// src/types/traces.ts

import { Pagination } from './devices';

export interface TraceSpan {
    timestamp: string;
    trace_id: string;
    span_id: string;
    parent_span_id: string;
    name: string;
    kind: number;
    start_time_unix_nano: number;
    end_time_unix_nano: number;
    service_name: string;
    service_version: string;
    service_instance: string;
    scope_name: string;
    scope_version: string;
    status_code: number;
    status_message: string;
    attributes: string;
    resource_attributes: string;
    events: string;
    links: string;
    raw_data: string;
}

export interface TraceSummary {
    timestamp: string;
    trace_id: string;
    root_span_id: string;
    root_span_name: string;
    root_service_name: string;
    root_span_kind: number;
    start_time_unix_nano: number;
    end_time_unix_nano: number;
    duration_ms: number;
    status_code: number;
    status_message: string;
    service_set: string[];
    span_count: number;
    error_count: number;
}

export interface TraceSpansApiResponse {
    results: TraceSpan[];
    pagination: Pagination;
    error?: string;
}

export interface TraceSummariesApiResponse {
    results: TraceSummary[];
    pagination: Pagination;
    error?: string;
}

export type SortableTraceKeys = 'timestamp' | 'duration_ms' | 'span_count' | 'error_count' | 'root_service_name';

export interface TraceStats {
    total: number;
    successful: number;
    errors: number;
    avg_duration_ms: number;
    p95_duration_ms: number;
    services_count: number;
}

export type { Pagination };