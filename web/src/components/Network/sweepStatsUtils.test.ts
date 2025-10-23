import { describe, expect, it } from 'vitest';

import { coerceSweepCount } from './sweepStatsUtils';

describe('coerceSweepCount', () => {
    it('returns the original number when finite', () => {
        expect(coerceSweepCount(42)).toBe(42);
        expect(coerceSweepCount(0)).toBe(0);
    });

    it('parses numeric strings and trims whitespace', () => {
        expect(coerceSweepCount('123')).toBe(123);
        expect(coerceSweepCount('  98765  ')).toBe(98765);
    });

    it('rejects non-numeric input', () => {
        expect(coerceSweepCount('abc')).toBeNull();
        expect(coerceSweepCount(NaN)).toBeNull();
        expect(coerceSweepCount(Infinity)).toBeNull();
        expect(coerceSweepCount(undefined)).toBeNull();
        expect(coerceSweepCount(null)).toBeNull();
    });
});
