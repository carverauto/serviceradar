import { describe, expect, it } from 'vitest';

import { parseTraceCounts } from './traceCountsUtils';

describe('parseTraceCounts', () => {
  it('returns zero counts when no row is provided', () => {
    expect(parseTraceCounts()).toEqual({
      total: 0,
      successful: 0,
      errors: 0,
      slow: 0
    });
  });

  it('normalises numeric fields from the aggregate row', () => {
    const row = {
      total: 128,
      successful: 100,
      errors: 12,
      slow: 16
    };

    expect(parseTraceCounts(row)).toEqual({
      total: 128,
      successful: 100,
      errors: 12,
      slow: 16
    });
  });

  it('parses numeric strings and ignores invalid values', () => {
    const row = {
      total: '256',
      successful: '200',
      errors: 'not-a-number',
      slow: null
    };

    expect(parseTraceCounts(row)).toEqual({
      total: 256,
      successful: 200,
      errors: 0,
      slow: 0
    });
  });
});
