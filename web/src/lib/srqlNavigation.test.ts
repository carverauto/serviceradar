import { describe, expect, it } from 'vitest';
import { shouldReuseViewForSearch } from './srqlNavigation';

describe('shouldReuseViewForSearch', () => {
    it('returns true when query originates from a view and matches the next submission', () => {
        const result = shouldReuseViewForSearch(
            {
                activeQuery: 'in:sweep_results time:last_7d sort:last_seen:desc limit:50',
                viewPath: '/network#sweeps',
                viewId: 'network:sweeps',
            },
            'in:sweep_results time:last_7d sort:last_seen:desc limit:50'
        );

        expect(result).toBe(true);
    });

    it('returns true for sweeps when only the limit changes', () => {
        const result = shouldReuseViewForSearch(
            {
                activeQuery: 'in:sweep_results time:last_7d sort:last_seen:desc limit:50',
                viewPath: '/network#sweeps',
                viewId: 'network:sweeps',
            },
            'in:sweep_results time:last_7d sort:last_seen:desc limit:100'
        );

        expect(result).toBe(true);
    });

    it('returns false when no view path is available', () => {
        const result = shouldReuseViewForSearch(
            {
                activeQuery: 'in:devices time:last_7d sort:last_seen:desc limit:20',
                viewPath: null,
                viewId: 'network:discovery',
            },
            'in:devices time:last_7d sort:last_seen:desc limit:20'
        );

        expect(result).toBe(false);
    });

    it('still reuses a view when the view path is available even if the origin was header', () => {
        const result = shouldReuseViewForSearch(
            {
                activeQuery: 'in:devices time:last_7d sort:last_seen:desc limit:20',
                viewPath: '/network#overview',
                viewId: 'network:overview',
            },
            'in:devices time:last_7d sort:last_seen:desc limit:20'
        );

        expect(result).toBe(true);
    });

    it('ignores redundant whitespace when comparing queries', () => {
        const result = shouldReuseViewForSearch(
            {
                activeQuery: 'in:devices   discovery_sources:*   time:last_7d   sort:last_seen:desc   limit:50',
                viewPath: '/network#discovery',
                viewId: 'network:discovery',
            },
            'in:devices discovery_sources:* time:last_7d sort:last_seen:desc limit:50'
        );

        expect(result).toBe(true);
    });

    it('falls back to equality when no matcher exists for the view', () => {
        const result = shouldReuseViewForSearch(
            {
                activeQuery: 'in:services time:last_24h',
                viewPath: '/network#applications',
                viewId: null,
            },
            'in:services time:last_24h'
        );

        expect(result).toBe(true);
    });

    it('routes any devices query back to the devices inventory view', () => {
        const result = shouldReuseViewForSearch(
            {
                activeQuery: 'in:devices time:last_24h sort:last_seen:desc limit:20',
                viewPath: '/devices',
                viewId: 'devices:inventory',
            },
            'in:devices is_available:true time:last_7d sort:last_seen:desc limit:100'
        );

        expect(result).toBe(true);
    });

    it('returns false when queries differ and no matcher exists', () => {
        const result = shouldReuseViewForSearch(
            {
                activeQuery: 'in:services time:last_24h',
                viewPath: '/network#applications',
                viewId: null,
            },
            'in:services time:last_7d'
        );

        expect(result).toBe(false);
    });
});
