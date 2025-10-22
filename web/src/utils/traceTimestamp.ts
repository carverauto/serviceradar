import type { TraceSummary } from '../types/traces';

export interface TimestampSource {
    timestamp?: string;
    _tp_time?: string;
    start_time_unix_nano?: number | null;
}

const TIMEZONE_REGEX = /(Z|[+-]\d{2}:?\d{2})$/i;

/**
 * Normalizes a timestamp string into an ISO-8601 representation that can be parsed by
 * JavaScript's Date constructor. Handles values returned from Proton such as
 * "2025-10-16 05:30:59.123456789" by truncating the fractional component to milliseconds
 * and defaulting to UTC when no timezone info is present.
 */
export const normalizeTimestampString = (timestamp?: string): string | null => {
    if (!timestamp) {
        return null;
    }

    let sanitized = timestamp.trim();
    if (!sanitized) {
        return null;
    }

    if (!sanitized.includes('T') && sanitized.includes(' ')) {
        const [datePart, timePart] = sanitized.split(' ');
        if (!timePart) {
            return null;
        }
        sanitized = `${datePart}T${timePart}`;
    }

    const misplacedTimezoneMatch = sanitized.match(/(Z|[+-]\d{2}:?\d{2})\.(\d+)$/i);
    if (misplacedTimezoneMatch) {
        const [, tz, fraction] = misplacedTimezoneMatch;
        sanitized = sanitized.replace(/(Z|[+-]\d{2}:?\d{2})\.(\d+)$/i, `.${fraction}${tz}`);
    }

    const timezoneMatch = sanitized.match(TIMEZONE_REGEX);
    const timezone = timezoneMatch ? timezoneMatch[1] : '';
    let withoutTimezone = timezone ? sanitized.slice(0, -timezone.length) : sanitized;

    const fractionMatch = withoutTimezone.match(/\.(\d+)$/);
    if (fractionMatch) {
        const fraction = fractionMatch[1];
        const truncated = fraction.slice(0, 3).padEnd(3, '0');
        withoutTimezone = `${withoutTimezone.slice(0, -(fraction.length + 1))}.${truncated}`;
    }

    const finalTimezone = timezone || 'Z';
    return `${withoutTimezone}${finalTimezone}`;
};

/**
 * Attempts to resolve a timestamp (in milliseconds since epoch) from the provided trace data.
 * Prefers a parseable timestamp string and falls back to the start_time_unix_nano field when
 * necessary.
 */
export const resolveTraceTimestampMs = ({ timestamp, _tp_time, start_time_unix_nano }: TimestampSource): number | null => {
    const tryParse = (candidate?: string | null): number | null => {
        const normalized = normalizeTimestampString(candidate ?? undefined);
        if (!normalized) {
            return null;
        }

        const parsed = Date.parse(normalized);
        return Number.isNaN(parsed) ? null : parsed;
    };

    const fromPrimary = tryParse(timestamp);
    if (fromPrimary !== null) {
        return fromPrimary;
    }

    const fromFallback = tryParse(_tp_time);
    if (fromFallback !== null) {
        return fromFallback;
    }

    if (typeof start_time_unix_nano === 'number' && start_time_unix_nano > 0) {
        return Math.floor(start_time_unix_nano / 1_000_000);
    }

    return null;
};

/**
 * Produces a normalized copy of the provided trace summary with a timestamp value that
 * always parses via Date. The original object is left untouched.
 */
export const normalizeTraceSummaryTimestamp = (trace: TraceSummary): TraceSummary => {
    const resolvedMs = resolveTraceTimestampMs(trace);
    if (resolvedMs === null) {
        return trace;
    }

    return {
        ...trace,
        timestamp: new Date(resolvedMs).toISOString(),
    };
};

export const parseNormalizedTimestamp = (timestamp?: string | null): Date | null => {
    const normalized = normalizeTimestampString(timestamp ?? undefined);
    if (!normalized) {
        return null;
    }

    const parsed = Date.parse(normalized);
    return Number.isNaN(parsed) ? null : new Date(parsed);
};

export const resolveTimestampMs = (timestamp?: string | null): number | null => {
    const normalized = normalizeTimestampString(timestamp ?? undefined);
    if (!normalized) {
        return null;
    }

    const parsed = Date.parse(normalized);
    return Number.isNaN(parsed) ? null : parsed;
};

export const formatTimestampForDisplay = (
    timestamp?: string | null,
    locale?: string | string[],
    options?: Intl.DateTimeFormatOptions,
    fallback = 'Invalid Date',
): string => {
    const date = parseNormalizedTimestamp(timestamp);
    if (!date) {
        return fallback;
    }

    try {
        return date.toLocaleString(locale, options);
    } catch {
        return date.toISOString();
    }
};
