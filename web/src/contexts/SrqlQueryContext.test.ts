import { describe, expect, it } from 'vitest';
import {
    DEFAULT_SRQL_QUERY,
    SrqlQueryMeta,
    SrqlQueryState,
    computeNextSrqlQueryState,
} from './SrqlQueryContext';

describe('computeNextSrqlQueryState', () => {
    it('returns previous state when the query and origin do not change', () => {
        const prev: SrqlQueryState = {
            query: DEFAULT_SRQL_QUERY,
            origin: 'header',
            viewPath: null,
            viewId: null,
        };
        const next = computeNextSrqlQueryState(
            prev,
            DEFAULT_SRQL_QUERY,
            { origin: 'header' }
        );

        expect(next).toBe(prev);
    });

    it('updates the origin when the same query arrives from a new source', () => {
        const prev: SrqlQueryState = {
            query: 'in:devices discovery_sources:(sweep)',
            origin: 'view',
            viewPath: '/network',
            viewId: 'network:sweeps',
        };

        const nextMeta: SrqlQueryMeta = { origin: 'header', viewPath: null, viewId: null };
        const next = computeNextSrqlQueryState(
            prev,
            'in:devices discovery_sources:(sweep)',
            nextMeta
        );

        expect(next).toEqual({
            query: 'in:devices discovery_sources:(sweep)',
            origin: 'header',
            viewPath: null,
            viewId: null,
        });
    });

    it('normalizes empty values back to the default query', () => {
        const prev: SrqlQueryState = {
            query: 'in:devices discovery_sources:(sweep)',
            origin: 'view',
            viewPath: '/network',
            viewId: 'network:sweeps',
        };

        const next = computeNextSrqlQueryState(prev, '', {
            origin: 'header',
            viewPath: null,
            viewId: null,
        });

        expect(next).toEqual({
            query: DEFAULT_SRQL_QUERY,
            origin: 'header',
            viewPath: null,
            viewId: null,
        });
    });

    it('captures a new query string from a view source', () => {
        const prev: SrqlQueryState = {
            query: DEFAULT_SRQL_QUERY,
            origin: 'header',
            viewPath: null,
            viewId: null,
        };

        const next = computeNextSrqlQueryState(
            prev,
            'in:devices discovery_sources:(sweep) time:last_24h sort:last_seen:desc limit:100',
            { origin: 'view', viewPath: '/network', viewId: 'network:sweeps' }
        );

        expect(next).toEqual({
            query: 'in:devices discovery_sources:(sweep) time:last_24h sort:last_seen:desc limit:100',
            origin: 'view',
            viewPath: '/network',
            viewId: 'network:sweeps',
        });
    });

    it('preserves the existing viewPath when meta omits it', () => {
        const prev: SrqlQueryState = {
            query: 'in:devices time:last_24h',
            origin: 'view',
            viewPath: '/network',
            viewId: 'network:overview',
        };

        const next = computeNextSrqlQueryState(prev, 'in:devices time:last_7d', {
            origin: 'view',
        });

        expect(next).toEqual({
            query: 'in:devices time:last_7d',
            origin: 'view',
            viewPath: '/network',
            viewId: 'network:overview',
        });
    });

    it('updates the viewId when provided', () => {
        const prev: SrqlQueryState = {
            query: DEFAULT_SRQL_QUERY,
            origin: 'header',
            viewPath: null,
            viewId: null,
        };

        const next = computeNextSrqlQueryState(prev, DEFAULT_SRQL_QUERY, {
            origin: 'view',
            viewPath: '/network#discovery',
            viewId: 'network:discovery',
        });

        expect(next).toEqual({
            query: DEFAULT_SRQL_QUERY,
            origin: 'view',
            viewPath: '/network#discovery',
            viewId: 'network:discovery',
        });
    });
});
