export interface MessagePreviewOptions {
  maxLength?: number;
  fallback?: string;
}

const stringifyObject = (value: Record<string, unknown>): string => {
  try {
    const json = JSON.stringify(value);
    return json === '{}' ? value.toString() : json;
  } catch {
    return value.toString();
  }
};

export const normalizeMessage = (raw: unknown): string => {
  if (raw == null) {
    return '';
  }
  if (typeof raw === 'string') {
    return raw;
  }
  if (typeof raw === 'number' || typeof raw === 'boolean') {
    return String(raw);
  }
  if (typeof raw === 'bigint' || typeof raw === 'symbol') {
    return raw.toString();
  }
  if (raw instanceof Error) {
    return raw.message || raw.toString();
  }
  if (typeof raw === 'object') {
    return stringifyObject(raw as Record<string, unknown>);
  }
  return '';
};

export const formatMessagePreview = (
  raw: unknown,
  options: MessagePreviewOptions = {}
): string => {
  const { maxLength = 50, fallback = '' } = options;
  const normalized = normalizeMessage(raw).trim();
  if (!normalized) {
    return fallback;
  }
  if (normalized.length <= maxLength) {
    return normalized;
  }
  return `${normalized.slice(0, maxLength)}...`;
};
