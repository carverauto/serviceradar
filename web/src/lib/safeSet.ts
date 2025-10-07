import set from 'lodash.set';

// Centralized guards against prototype pollution when performing deep property sets.
const dangerousKeys = ['__proto__', 'constructor', 'prototype'] as const;

type DangerousKey = typeof dangerousKeys[number];

export const isSafeKey = (key: string): boolean => {
  return !dangerousKeys.includes(key as DangerousKey);
};

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
      console.error(`Attempted to set dangerous property: ${seg}`);
      return;
    }
  }

  // Delegate to lodash.set after validation to build intermediate objects safely.
  // Using type assertion here is safe because lodash.set handles the typing internally
  set(obj as Record<string, unknown>, segments as (string | number)[], value);
}

export default safeSet;

