// src/types/logs.ts

import { Pagination } from './devices';

export interface Log {
    _tp_time: string;
    timestamp: string;
    trace_id: string;
    span_id: string;
    severity_text: string;
    severity_number: number;
    body: string;
    service_name: string;
    service_version: string;
    service_instance: string;
    scope_name: string;
    scope_version: string;
    attributes: string;
    resource_attributes: string;
    raw_data: string;
}

export interface LogsApiResponse {
    results: Log[];
    pagination: Pagination;
    error?: string;
}

export type SortableLogKeys = 'timestamp' | 'service_name' | 'severity_text' | 'severity_number';

export type { Pagination };