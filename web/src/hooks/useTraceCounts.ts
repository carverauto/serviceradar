/**
 * Shared hook for fetching trace count aggregates so analytics dashboard
 * widgets and the observability experience stay consistent.
 */

'use client';

import { useAuth } from '@/components/AuthProvider';
import { cachedQuery } from '@/lib/cached-query';
import { useCallback, useEffect, useMemo, useState } from 'react';

import {
    DEFAULT_COUNTS,
    parseTraceCounts,
    TraceAggregateRow,
    TraceCounts
} from './traceCountsUtils';

export type { TraceCounts } from './traceCountsUtils';

const TRACE_AGGREGATE_QUERY =
    'in:otel_trace_summaries time:last_24h stats:"count() as total, sum(if(status_code = 1, 1, 0)) as successful, sum(if(status_code != 1, 1, 0)) as errors, sum(if(duration_ms > 100, 1, 0)) as slow"';

interface UseTraceCountsOptions {
    refreshInterval?: number;
    ttl?: number;
}

const DEFAULT_REFRESH_INTERVAL = 30000; // 30 seconds

export const useTraceCounts = (
    { refreshInterval = DEFAULT_REFRESH_INTERVAL, ttl }: UseTraceCountsOptions = {}
) => {
    const { token } = useAuth();
    const [counts, setCounts] = useState<TraceCounts>(DEFAULT_COUNTS);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);
    const [hasFetched, setHasFetched] = useState(false);

    const authToken = token || undefined;
    const queryTtl = ttl ?? DEFAULT_REFRESH_INTERVAL;

    const executeQueries = useCallback(async () => {
        if (!hasFetched) {
            setLoading(true);
        }

        try {
            const response = await cachedQuery<{ results?: TraceAggregateRow[] }>(
                TRACE_AGGREGATE_QUERY,
                authToken,
                queryTtl
            );
            const nextCounts = parseTraceCounts(response.results?.[0]);
            setCounts(nextCounts);
            setError(null);
        } catch (err) {
            const message =
                err instanceof Error ? err.message : 'Failed to fetch trace counts';
            setError(message);
            console.error('[useTraceCounts] Unable to fetch trace aggregates:', err);
        } finally {
            setHasFetched(true);
            setLoading(false);
        }
    }, [authToken, hasFetched, queryTtl]);

    useEffect(() => {
        executeQueries();
    }, [executeQueries]);

    useEffect(() => {
        if (!refreshInterval) {
            return;
        }

        const intervalId = setInterval(executeQueries, refreshInterval);
        return () => clearInterval(intervalId);
    }, [executeQueries, refreshInterval]);

    return useMemo(
        () => ({
            counts,
            loading,
            error,
            refresh: executeQueries,
        }),
        [counts, error, executeQueries, loading]
    );
};
