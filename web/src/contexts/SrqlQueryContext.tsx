'use client';

import React, {
    createContext,
    useCallback,
    useContext,
    useEffect,
    useMemo,
    useState,
} from 'react';
import { DEFAULT_DEVICES_QUERY } from '../lib/srqlQueries';

type SrqlQueryOrigin = 'header' | 'view';

export interface SrqlQueryMeta {
    origin?: SrqlQueryOrigin;
    viewPath?: string | null;
}

interface SrqlQueryContextValue {
    query: string;
    origin: SrqlQueryOrigin;
    viewPath: string | null;
    setQuery: (nextQuery: string, meta?: SrqlQueryMeta) => void;
}

export interface SrqlQueryState {
    query: string;
    origin: SrqlQueryOrigin;
    viewPath: string | null;
}

const SrqlQueryContext = createContext<SrqlQueryContextValue | undefined>(undefined);

const normalizeSrqlQuery = (value: string | null | undefined): string => {
    if (typeof value !== 'string') {
        return DEFAULT_DEVICES_QUERY;
    }
    const trimmed = value.trim();
    return trimmed.length === 0 ? DEFAULT_DEVICES_QUERY : trimmed;
};

export const computeNextSrqlQueryState = (
    prev: SrqlQueryState,
    nextValue: string,
    meta: SrqlQueryMeta = {}
): SrqlQueryState => {
    const nextQuery = normalizeSrqlQuery(nextValue);
    const nextOrigin = meta.origin ?? prev.origin;
    const nextViewPath =
        meta.viewPath !== undefined ? meta.viewPath : prev.viewPath;

    if (
        prev.query === nextQuery &&
        prev.origin === nextOrigin &&
        prev.viewPath === nextViewPath
    ) {
        return prev;
    }

    return {
        query: nextQuery,
        origin: nextOrigin,
        viewPath: nextViewPath ?? null,
    };
};

export function SrqlQueryProvider({
    children,
    initialQuery,
}: {
    children: React.ReactNode;
    initialQuery?: string | null;
}) {
    const [state, setState] = useState<SrqlQueryState>({
        query: normalizeSrqlQuery(initialQuery ?? undefined),
        origin: 'header',
        viewPath: null,
    });

    useEffect(() => {
        if (typeof initialQuery === 'string' && initialQuery.trim().length > 0) {
            // Sync the latest search parameter into the shared state.
            // eslint-disable-next-line react-hooks/set-state-in-effect
            setState((prev) =>
                computeNextSrqlQueryState(prev, initialQuery, {
                    origin: 'header',
                    viewPath: null,
                })
            );
        }
    }, [initialQuery]);

    const setQuery = useCallback(
        (nextQuery: string, meta?: SrqlQueryMeta) => {
            setState((prev) => computeNextSrqlQueryState(prev, nextQuery, meta));
        },
        []
    );

    const value = useMemo(
        () => ({
            query: state.query,
            origin: state.origin,
            viewPath: state.viewPath,
            setQuery,
        }),
        [setQuery, state.origin, state.query, state.viewPath]
    );

    return (
        <SrqlQueryContext.Provider value={value}>
            {children}
        </SrqlQueryContext.Provider>
    );
}

export const useSrqlQuery = (): SrqlQueryContextValue => {
    const context = useContext(SrqlQueryContext);
    if (!context) {
        throw new Error('useSrqlQuery must be used within a SrqlQueryProvider');
    }
    return context;
};

export const DEFAULT_SRQL_QUERY = DEFAULT_DEVICES_QUERY;
