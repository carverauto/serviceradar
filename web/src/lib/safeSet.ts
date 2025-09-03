import set from 'lodash.set';

// Centralized guards against prototype pollution when performing deep property sets.
const dangerousKeys = ['__proto__', 'constructor', 'prototype'] as const;

export const isSafeKey = (key: string) => !dangerousKeys.includes(key as any);

// Tokenize a dot-path into segments. Our code only uses dot notation, but this
// leaves room to expand later. Bracket handling can be added if needed.
function pathToSegments(path: string | Array<string | number>): Array<string | number> {
  if (Array.isArray(path)) return path;
  // Split on dots; keep numbers as numbers to support array indices if passed in.
  return path.split('.').map((seg) => (seg.match(/^\d+$/) ? Number(seg) : seg));
}

// Safely set a value at a deep path on an object, rejecting dangerous keys.
export function safeSet<T extends object>(obj: T, path: string | Array<string | number>, value: unknown): void {
  const segments = pathToSegments(path);

  for (const seg of segments) {
    if (typeof seg === 'string' && !isSafeKey(seg)) {
      // Refuse to set a dangerous property name at any depth.
      // eslint-disable-next-line no-console
      console.error(`Attempted to set dangerous property: ${seg}`);
      return;
    }
  }

  // Delegate to lodash.set after validation to build intermediate objects safely.
  set(obj as any, segments as any, value);
}

export default safeSet;

