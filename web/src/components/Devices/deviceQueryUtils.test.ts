import { describe, expect, it } from 'vitest';

import { selectDevicesQuery } from './deviceQueryUtils';

describe('selectDevicesQuery', () => {
    it('returns the fallback query when the incoming value is empty', () => {
        const fallback = 'in:devices time:last_7d limit:20';
        expect(selectDevicesQuery('', fallback)).toBe(fallback);
        expect(selectDevicesQuery('   ', fallback)).toBe(fallback);
    });

    it('returns the fallback query when the incoming value targets a different stream', () => {
        const fallback = 'in:devices time:last_7d limit:20';
        expect(selectDevicesQuery('in:events time:last_24h', fallback)).toBe(fallback);
    });

    it('reuses the incoming query when it already targets devices', () => {
        const fallback = 'in:devices time:last_7d limit:20';
        const incoming = '  in:devices  is_available:true  time:last_24h  ';
        expect(selectDevicesQuery(incoming, fallback)).toBe('in:devices is_available:true time:last_24h');
    });
});
