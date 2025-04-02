// src/types/rperf.ts
export interface RperfMetric {
    timestamp: string; // ISO string
    name: string;      // e.g., "rperf_tcp_bandwidth"
    target: string;    // e.g., target IP or hostname
    success: boolean;
    error?: string | null;
    bits_per_second: number;
    bytes_received: number;
    bytes_sent: number;
    duration: number;
    jitter_ms: number;
    loss_percent: number;
    packets_lost: number;
    packets_received: number;
    packets_sent: number;
}