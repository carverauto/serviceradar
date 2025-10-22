import { describe, expect, it } from 'vitest';
import {
    normalizeTimestampString,
    resolveTraceTimestampMs,
    normalizeTraceSummaryTimestamp,
    parseNormalizedTimestamp,
    resolveTimestampMs,
    formatTimestampForDisplay,
} from './traceTimestamp';
import type { TraceSummary } from '../types/traces';

const makeTrace = (overrides: Partial<TraceSummary>): TraceSummary => ({
    timestamp: '',
    trace_id: 'trace-id',
    root_span_id: 'root-span',
    root_span_name: 'RootSpan',
    root_service_name: 'serviceradar-core',
    root_span_kind: 0,
    start_time_unix_nano: 0,
    end_time_unix_nano: 0,
    duration_ms: 0,
    status_code: 1,
    status_message: '',
    service_set: [],
    span_count: 0,
    error_count: 0,
    ...overrides,
});

describe('normalizeTimestampString', () => {
    it('converts Proton DateTime64 with nanoseconds into ISO format', () => {
        const result = normalizeTimestampString('2025-10-16 05:30:59.123456789');
        expect(result).toBe('2025-10-16T05:30:59.123Z');
        expect(Date.parse(result!)).not.toBeNaN();
    });

    it('handles timezone placed before fractional seconds', () => {
        const result = normalizeTimestampString('2025-10-16T05:30:59Z.987654321');
        expect(result).toBe('2025-10-16T05:30:59.987Z');
        expect(Date.parse(result!)).not.toBeNaN();
    });

    it('preserves explicit timezone offsets', () => {
        const result = normalizeTimestampString('2025-10-16T05:30:59.987654+02:00');
        expect(result).toBe('2025-10-16T05:30:59.987+02:00');
        expect(Date.parse(result!)).not.toBeNaN();
    });

    it('normalizes values without fractional seconds or timezone', () => {
        const result = normalizeTimestampString('2025-10-16 05:30:59');
        expect(result).toBe('2025-10-16T05:30:59Z');
        expect(Date.parse(result!)).not.toBeNaN();
    });

    it('returns null for empty or whitespace strings', () => {
        expect(normalizeTimestampString('')).toBeNull();
        expect(normalizeTimestampString('   ')).toBeNull();
    });
});

describe('parseNormalizedTimestamp', () => {
    it('parses timestamps with misplaced timezone fraction', () => {
        const parsed = parseNormalizedTimestamp('2025-10-21T03:30:33Z.519');
        expect(parsed).not.toBeNull();
        expect(parsed?.toISOString()).toBe('2025-10-21T03:30:33.519Z');
    });

    it('returns null for empty values', () => {
        expect(parseNormalizedTimestamp(undefined)).toBeNull();
        expect(parseNormalizedTimestamp('')).toBeNull();
    });
});

describe('resolveTraceTimestampMs', () => {
    it('parses timestamp strings when available', () => {
        const ms = resolveTraceTimestampMs({
            timestamp: '2025-10-16 05:30:59.123456789',
            start_time_unix_nano: 0,
        });
        expect(ms).toBe(Date.UTC(2025, 9, 16, 5, 30, 59, 123));
    });

    it('falls back to start_time_unix_nano when timestamp is invalid', () => {
        const startNano = 1734350400123456700; // Represents ~2024-12-16T12:00:00.123Z with millisecond precision
        const ms = resolveTraceTimestampMs({
            timestamp: 'not-a-date',
            start_time_unix_nano: startNano,
        });
        expect(ms).toBe(Math.floor(startNano / 1_000_000));
    });

    it('uses _tp_time when timestamp is missing', () => {
        const ms = resolveTraceTimestampMs({
            timestamp: undefined,
            _tp_time: '2025-10-16 05:30:59.456789123',
        });
        expect(ms).toBe(Date.UTC(2025, 9, 16, 5, 30, 59, 456));
    });

    it('returns null when both sources are unavailable', () => {
        const ms = resolveTraceTimestampMs({
            timestamp: undefined,
            start_time_unix_nano: 0,
        });
        expect(ms).toBeNull();
    });

    it('handles objects without start_time_unix_nano', () => {
        const ms = resolveTraceTimestampMs({
            timestamp: '2025-10-16 05:30:59.123',
        });
        expect(ms).toBe(Date.UTC(2025, 9, 16, 5, 30, 59, 123));
    });
});

describe('normalizeTraceSummaryTimestamp', () => {
    it('produces an ISO timestamp derived from Proton-formatted data', () => {
        const trace = makeTrace({
            timestamp: '2025-10-16 05:30:59.123456789',
            start_time_unix_nano: 0,
        });

        const normalized = normalizeTraceSummaryTimestamp(trace);
        expect(normalized.timestamp).toBe('2025-10-16T05:30:59.123Z');
        expect(Date.parse(normalized.timestamp)).not.toBeNaN();
    });

    it('uses start_time_unix_nano when timestamp string is unusable', () => {
        const startNano = 1734350400123456700; // Represents ~2024-12-16T12:00:00.123Z with millisecond precision
        const trace = makeTrace({
            timestamp: 'Invalid Date',
            start_time_unix_nano: startNano,
        });

        const normalized = normalizeTraceSummaryTimestamp(trace);
        const expectedIso = new Date(Math.floor(startNano / 1_000_000)).toISOString();
        expect(normalized.timestamp).toBe(expectedIso);
    });
});

describe('resolveTimestampMs', () => {
    it('returns epoch milliseconds for normalized timestamps', () => {
        const result = resolveTimestampMs('2025-10-16 05:30:59.123456');
        expect(result).toBe(Date.UTC(2025, 9, 16, 5, 30, 59, 123));
    });

    it('returns null for invalid values', () => {
        expect(resolveTimestampMs('not-a-date')).toBeNull();
    });
});

describe('formatTimestampForDisplay', () => {
    it('formats valid timestamps using locale settings', () => {
        const formatted = formatTimestampForDisplay('2025-10-16T05:30:59Z.750');
        expect(formatted).not.toBe('Invalid Date');
    });

    it('returns fallback for invalid timestamps', () => {
        const formatted = formatTimestampForDisplay('', undefined, undefined, 'N/A');
        expect(formatted).toBe('N/A');
    });
});
