import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest';

import { DataService } from './dataService';

const createResponse = (body: unknown): Response =>
  ({
    ok: true,
    json: async () => body
  }) as Response;

describe('DataService.getAnalyticsData', () => {
  const originalFetch = globalThis.fetch;
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchMock = vi.fn();
    globalThis.fetch = fetchMock as unknown as typeof fetch;
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
    vi.resetAllMocks();
  });

  it('aggregates batched analytics queries into dashboard data', async () => {
    const responses: unknown[] = [
      {
        logs: [
          {
            timestamp: '2025-01-01T00:00:00Z',
            severity: 'fatal',
            body: 'fatal failure',
            trace_id: 'trace-1',
            span_id: 'span-1'
          },
          {
            timestamp: '2025-01-01T00:02:00Z',
            severity: 'error',
            body: 'an error occurred',
            trace_id: 'trace-2',
            span_id: 'span-2'
          }
        ]
      },
      {
        counters: {
          updated_at: '2025-01-01T00:05:00Z',
          window_1h: { total: 5, fatal: 1, error: 4 },
          window_24h: {
            total: 90,
            fatal: 2,
            error: 13,
            warning: 17,
            info: 41,
            debug: 17,
            other: 0
          }
        }
      },
      { results: [{ total: 12 }] },
      { results: [{ total: 3 }] },
      { results: [{ total: 48 }] },
      { results: [{ total: 5 }] },
      { results: [{ total: 7 }] },
      { results: [{ total: 11 }] },
      { results: [{ total: 25 }] },
      { results: [{ id: 1 }, { id: 2 }, { id: 3 }] },
      { results: [{ total: 120 }] },
      { results: [{ total: 64, error_traces: 4, slow_traces: 9 }] },
      { results: [{ device_id: 'dev-1' }] },
      { results: [{ service_id: 'svc-1', available: false }] },
      {
        results: [
          {
            trace_id: 'trace-1',
            root_service_name: 'core',
            root_span_name: 'Root',
            duration_ms: 250,
            timestamp: '2025-01-01T00:00:00Z'
          }
        ]
      }
    ];

    fetchMock.mockImplementation(() => {
      const payload = responses.shift();
      if (!payload) {
        throw new Error('Unexpected fetch call');
      }
      return Promise.resolve(createResponse(payload));
    });

    const service = new DataService();
    const analytics = await service.getAnalyticsData();

    expect(fetchMock).toHaveBeenCalledTimes(15);
    expect(analytics.totalDevices).toBe(12);
    expect(analytics.offlineDevices).toBe(3);
    expect(analytics.onlineDevices).toBe(9);
    expect(analytics.totalEvents).toBe(48);
    expect(analytics.criticalEvents).toBe(5);
    expect(analytics.highEvents).toBe(7);
    expect(analytics.mediumEvents).toBe(11);
    expect(analytics.lowEvents).toBe(25);
    expect(analytics.totalLogs).toBe(90);
    expect(analytics.fatalLogs).toBe(2);
    expect(analytics.errorLogs).toBe(13);
    expect(analytics.warningLogs).toBe(17);
    expect(analytics.infoLogs).toBe(41);
    expect(analytics.debugLogs).toBe(17);
    expect(analytics.recentErrorLogs).toHaveLength(2);
    expect(analytics.criticalLogCounters?.window_24h?.fatal).toBe(2);
    expect(analytics.totalMetrics).toBe(120);
    expect(analytics.totalTraces).toBe(64);
    expect(analytics.errorTraces).toBe(4);
    expect(analytics.slowTraces).toBe(9);
    expect(analytics.recentSlowSpans).toHaveLength(0);

    // Allow the background slow trace fetch to update the cache.
    await Promise.resolve();

    const cached = await service.getAnalyticsData();
    expect(fetchMock).toHaveBeenCalledTimes(15);
    expect(cached.recentSlowSpans).toHaveLength(1);
    expect(cached.recentSlowSpans[0]?.trace_id).toBe('trace-1');
  });
});
