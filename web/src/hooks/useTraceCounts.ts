/**
 * Shared hook for fetching trace count aggregates so analytics dashboard
 * widgets and the observability experience stay consistent.
 */

'use client';

import { useAuth } from '@/components/AuthProvider';
import { cachedQuery } from '@/lib/cached-query';
import { useCallback, useEffect, useMemo, useState } from 'react';

const TRACE_TOTAL_QUERY =
    'in:otel_trace_summaries stats:"count() as total" sort:total:desc time:last_24h';
const TRACE_SUCCESS_QUERY =
    'in:otel_trace_summaries status_code:1 stats:"count() as total" sort:total:desc time:last_24h';
const TRACE_ERROR_QUERY =
    'in:otel_trace_summaries status_code!=1 stats:"count() as total" sort:total:desc time:last_24h';
const TRACE_SLOW_QUERY =
    'in:otel_trace_summaries duration_ms>100 stats:"count() as total" sort:total:desc time:last_24h';

export interface TraceCounts {
    total: number;
    successful: number;
    errors: number;
    slow: number;
}

interface UseTraceCountsOptions {
    refreshInterval?: number;
    ttl?: number;
}

const DEFAULT_REFRESH_INTERVAL = 30000; // 30 seconds

export const useTraceCounts = (
    { refreshInterval = DEFAULT_REFRESH_INTERVAL, ttl }: UseTraceCountsOptions = {}
) => {
    const { token } = useAuth();
    const [counts, setCounts] = useState<TraceCounts>({
        total: 0,
        successful: 0,
        errors: 0,
        slow: 0,
    });
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
            const [totalRes, successRes, errorRes, slowRes] = await Promise.all([
                cachedQuery<{ results: Array<{ total?: number }> }>(
                    TRACE_TOTAL_QUERY,
                    authToken,
                    queryTtl
                ),
                cachedQuery<{ results: Array<{ total?: number }> }>(
                    TRACE_SUCCESS_QUERY,
                    authToken,
                    queryTtl
                ),
                cachedQuery<{ results: Array<{ total?: number }> }>(
                    TRACE_ERROR_QUERY,
                    authToken,
                    queryTtl
                ),
                cachedQuery<{ results: Array<{ total?: number }> }>(
                    TRACE_SLOW_QUERY,
                    authToken,
                    queryTtl
                ),
            ]);

            setCounts({
                total: totalRes.results?.[0]?.total ?? 0,
                successful: successRes.results?.[0]?.total ?? 0,
                errors: errorRes.results?.[0]?.total ?? 0,
                slow: slowRes.results?.[0]?.total ?? 0,
            });
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

