// src/types/events.ts

import { Pagination } from './devices';

export interface Event {
    _tp_time: string;
    datacontenttype: string;
    event_timestamp: string;
    host: string;
    id: string;
    level: number;
    raw_data: string; // This is a JSON string
    remote_addr: string;
    severity: string;
    short_message: string;
    source: string;
    specversion: string;
    subject: string;
    type: string;
    version: string;
}

export interface EventsApiResponse {
    results: Event[];
    pagination: Pagination;
    error?: string;
}

export { Pagination };
