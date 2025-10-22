export interface TraceCounts {
  total: number;
  successful: number;
  errors: number;
  slow: number;
}

export interface TraceAggregateRow {
  total?: number | string | null;
  successful?: number | string | null;
  errors?: number | string | null;
  slow?: number | string | null;
}

export const DEFAULT_COUNTS: TraceCounts = {
  total: 0,
  successful: 0,
  errors: 0,
  slow: 0
};

const toNumber = (value: unknown): number => {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === 'string') {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }
  return 0;
};

export const parseTraceCounts = (row?: TraceAggregateRow | null): TraceCounts => ({
  total: toNumber(row?.total),
  successful: toNumber(row?.successful),
  errors: toNumber(row?.errors),
  slow: toNumber(row?.slow)
});
