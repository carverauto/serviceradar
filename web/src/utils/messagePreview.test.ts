import { describe, expect, it } from 'vitest';

import { formatMessagePreview } from './messagePreview';

describe('formatMessagePreview', () => {
  it('returns the fallback for nullish input', () => {
    expect(formatMessagePreview(undefined, { fallback: 'N/A' })).toBe('N/A');
    expect(formatMessagePreview(null, { fallback: 'Missing' })).toBe('Missing');
  });

  it('truncates long strings', () => {
    const preview = formatMessagePreview('abcdef', { maxLength: 3 });
    expect(preview).toBe('abc...');
  });

  it('stringifies objects and trims whitespace', () => {
    const preview = formatMessagePreview({ foo: 'bar' });
    expect(preview).toContain('"foo":"bar"');
  });
});
