import { describe, expect, it } from 'vitest';

import { extractServiceNamesFromResults } from './logServiceOptions';

describe('extractServiceNamesFromResults', () => {
    it('returns an empty array when rows are empty', () => {
        expect(extractServiceNamesFromResults([])).toEqual([]);
    });

    it('deduplicates service names and trims whitespace', () => {
        const rows = [
            { service_name: 'core' },
            { service_name: 'core ' },
            { serviceName: 'sync' },
            { name: 'agent' },
            { service_name: '' },
            { service_name: undefined },
            null,
            'core'
        ];

        expect(extractServiceNamesFromResults(rows)).toEqual(['agent', 'core', 'sync']);
    });

    it('falls back to alternate keys when service_name is missing', () => {
        const rows = [
            { name: 'poller' },
            { serviceName: 'tools' }
        ];

        expect(extractServiceNamesFromResults(rows)).toEqual(['poller', 'tools']);
    });

    it('extracts names from group_uniq_array results (array)', () => {
        const rows = [
            {
                services: ['core', 'sync', 'core']
            }
        ];

        expect(extractServiceNamesFromResults(rows)).toEqual(['core', 'sync']);
    });

    it('extracts names from group_uniq_array results (JSON string)', () => {
        const rows = [
            {
                services: '["poller","agent","poller"]'
            }
        ];

        expect(extractServiceNamesFromResults(rows)).toEqual(['agent', 'poller']);
    });
});
