// src/types/otel-metrics.ts

import { Pagination } from './devices';

export interface OtelMetric {
    timestamp: string;
    _tp_time?: string;
    trace_id: string;
    span_id: string;
    service_name: string;
    span_name: string;
    span_kind: string;
    duration_ms: number;
    duration_seconds: number;
    metric_type: string;
    http_method: string;
    http_route: string;
    http_status_code: string;
    grpc_service: string;
    grpc_method: string;
    grpc_status_code: string;
    is_slow: boolean;
    component: string;
    level: string;
    raw_data: string;
}

export interface OtelMetricsApiResponse {
    results: OtelMetric[];
    pagination: Pagination;
    error?: string;
}

export type SortableMetricKeys = 'timestamp' | 'duration_ms' | 'service_name';

export interface MetricsStats {
    total: number;
    slow_spans: number;
    avg_duration_ms: number;
    p95_duration_ms: number;
    error_rate: number;
    top_services: Array<{
        service_name: string;
        count: number;
        avg_duration_ms: number;
    }>;
}

export type { Pagination };
