/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * You may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { GenericServiceDetails } from '@/types/types';
import { RperfMetric } from '@/types/rperf';

export interface ServiceLatencyBucket {
  name: string;
  responseTimeMs: number;
}

export interface CriticalLogSummary {
  timestamp: string;
  severity: string;
  severity_text?: string;
  service_name?: string;
  body?: string;
  trace_id?: string;
  span_id?: string;
}

export interface SeverityWindowCounts {
  total?: number;
  fatal?: number;
  error?: number;
  warning?: number;
  info?: number;
  debug?: number;
  other?: number;
}

export interface CriticalLogCounters {
  updated_at?: string;
  window_1h?: SeverityWindowCounts;
  window_24h?: SeverityWindowCounts;
}

export interface AnalyticsData {
  // Device stats
  totalDevices: number;
  offlineDevices: number;
  onlineDevices: number;
  deviceStatsDiagnostics: DeviceStatsDiagnostics;

  // Event stats
  totalEvents: number;
  criticalEvents: number;
  highEvents: number;
  mediumEvents: number;
  lowEvents: number;
  recentCriticalEvents: unknown[];

  // Log stats
  totalLogs: number;
  fatalLogs: number;
  errorLogs: number;
  warningLogs: number;
  infoLogs: number;
  debugLogs: number;
  recentErrorLogs: CriticalLogSummary[];
  criticalLogCounters: CriticalLogCounters | null;

  // Observability stats
  totalMetrics: number;
  totalTraces: number;
  slowTraces: number;
  errorTraces: number;
  recentSlowSpans: RecentSlowSpan[];

  // Device data for widgets
  devicesLatest: unknown[];
  servicesLatest: unknown[];
  failingServiceCount: number;
  highLatencyServiceCount: number;
  serviceLatencyBuckets: ServiceLatencyBucket[];
}

interface DevicePartitionStats {
  partition_id: string;
  device_count: number;
  active_count: number;
  available_count: number;
}

interface DeviceStatsSnapshot {
  timestamp: string;
  total_devices: number;
  available_devices: number;
  unavailable_devices: number;
  active_devices: number;
  devices_with_icmp: number;
  devices_with_snmp: number;
  devices_with_sysmon: number;
  partitions: DevicePartitionStats[];
}

interface DeviceCounterSnapshotSummary {
  timestamp?: string;
  total_devices?: number;
  available_devices?: number;
  unavailable_devices?: number;
  active_devices?: number;
}

interface DeviceStatsHeaderSummary {
  timestamp?: string;
  ageMs?: number;
  rawRecords?: number;
  processedRecords?: number;
  skippedNilRecords?: number;
  skippedTombstonedRecords?: number;
  skippedServiceComponents?: number;
  skippedNonCanonicalRecords?: number;
}

interface DeviceStatsDiagnostics {
  summary: DeviceStatsHeaderSummary | null;
  recordedAt: string;
  warnings: string[];
  details: string[];
}

interface DeviceStatsFetchResult {
  snapshot: DeviceStatsSnapshot | null;
  headers: DeviceStatsHeaderSummary | null;
  errorMessage?: string;
}

interface DeviceCounterSample {
  recordedAt: string;
  apiSnapshot: DeviceCounterSnapshotSummary | null;
  statsFresh: boolean;
  error?: string;
  apiHeaders?: DeviceStatsHeaderSummary | null;
}

interface DeviceCounterDebugWindow extends Window {
  __SERVICERADAR_DEVICE_COUNTER_DEBUG__?: DeviceCounterSample[];
}

export interface RecentSlowSpan {
  trace_id: string;
  service_name: string;
  span_name: string;
  duration_ms: number;
  timestamp: string | number | null;
}

export interface SysmonDiskSummary {
  mountPoint: string;
  usagePercent?: number;
  usedBytes?: number;
  totalBytes?: number;
  lastTimestamp?: string;
}

export interface SysmonAgentSummary {
  pollerId?: string;
  agentId?: string;
  hostId?: string;
  deviceId?: string;
  partition?: string;
  avgCpuUsage?: number;
  memoryUsagePercent?: number;
  usedMemoryBytes?: number;
  totalMemoryBytes?: number;
  lastTimestamp?: string;
  disks: SysmonDiskSummary[];
}

export interface RperfData {
  pollerId: string;
  rperfMetrics: RperfMetric[];
}

type DataKey = 'analytics' | 'sysmon' | 'rperf';

interface DataStore {
  analytics: AnalyticsData;
  sysmon: SysmonAgentSummary[];
  rperf: RperfData[];
}

interface CacheEntry<T> {
  data: T;
  timestamp: number;
  promise?: Promise<T>;
}

interface SrqlResponse<T = unknown> {
  results?: T[];
}

interface SlowTraceResult {
  trace_id?: string;
  root_service_name?: string;
  service_name?: string;
  root_span_name?: string;
  duration_ms?: number;
  timestamp?: string;
  start_time_unix_nano?: string | number;
}

interface CpuAverageRow {
  device_id?: string;
  avg_cpu_usage?: number | string;
}

interface CpuSampleRow {
  device_id?: string;
  poller_id?: string;
  partition?: string;
  agent_id?: string;
  host_id?: string;
  usage_percent?: number | string;
  timestamp?: string;
}

interface MemorySampleRow {
  device_id?: string;
  poller_id?: string;
  partition?: string;
  agent_id?: string;
  host_id?: string;
  usage_percent?: number | string;
  used_bytes?: number | string;
  total_bytes?: number | string;
  timestamp?: string;
}

interface DiskSampleRow {
  device_id?: string;
  poller_id?: string;
  partition?: string;
  agent_id?: string;
  host_id?: string;
  mount_point?: string;
  usage_percent?: number | string;
  used_bytes?: number | string;
  total_bytes?: number | string;
  timestamp?: string;
}

interface SrqlRperfRow {
  poller_id?: string;
  agent_id?: string;
  metric_name?: string;
  metric_type?: string;
  timestamp?: string;
  metadata?: string;
  message?: string;
  target_device_ip?: string | null;
}

interface RperfMetadataPayload {
  timestamp?: string;
  name?: string;
  bits_per_second?: number;
  bytes_received?: number;
  bytes_sent?: number;
  duration?: number;
  jitter_ms?: number;
  loss_percent?: number;
  packets_lost?: number;
  packets_received?: number;
  packets_sent?: number;
  success?: boolean;
  target?: string;
  response_time?: number;
  error?: string | null;
  agent_id?: string;
  service_name?: string;
  service_type?: string;
  version?: string;
}

export class DataService {
  private readonly cache = new Map<DataKey, CacheEntry<DataStore[DataKey]>>();
  private readonly subscribers = new Map<DataKey, Set<() => void>>();
  private readonly CACHE_DURATION = 30_000; // 30 seconds
  private readonly LATENCY_THRESHOLD_NS = 100 * 1_000_000; // 100ms
  private readonly STATS_STALE_THRESHOLD_MS = 60_000; // 60 seconds

  async getAnalyticsData(token?: string): Promise<AnalyticsData> {
    return this.fetchAndCache(
      'analytics',
      () => this.fetchAllAnalyticsData(token),
      () => this.getEmptyAnalyticsData()
    );
  }

  async refreshAnalytics(token?: string): Promise<AnalyticsData> {
    this.cache.delete('analytics');
    return this.getAnalyticsData(token);
  }

  isAnalyticsCacheValid(): boolean {
    return this.isCacheValid('analytics');
  }

  subscribeAnalytics(callback: () => void): () => void {
    return this.subscribe('analytics', callback);
  }

  async getSysmonData(token?: string): Promise<SysmonAgentSummary[]> {
    return this.fetchAndCache('sysmon', () => this.fetchSysmonSummaries(token), () => []);
  }

  async refreshSysmon(token?: string): Promise<SysmonAgentSummary[]> {
    this.cache.delete('sysmon');
    return this.getSysmonData(token);
  }

  isSysmonCacheValid(): boolean {
    return this.isCacheValid('sysmon');
  }

  subscribeSysmon(callback: () => void): () => void {
    return this.subscribe('sysmon', callback);
  }

  async getRperfData(token?: string): Promise<RperfData[]> {
    return this.fetchAndCache('rperf', () => this.fetchRperfData(token), () => []);
  }

  async refreshRperf(token?: string): Promise<RperfData[]> {
    this.cache.delete('rperf');
    return this.getRperfData(token);
  }

  isRperfCacheValid(): boolean {
    return this.isCacheValid('rperf');
  }

  subscribeRperf(callback: () => void): () => void {
    return this.subscribe('rperf', callback);
  }

  private async fetchAndCache<K extends DataKey>(
    key: K,
    fetcher: () => Promise<DataStore[K]>,
    initial: () => DataStore[K]
  ): Promise<DataStore[K]> {
    const now = Date.now();
    const existing = this.cache.get(key) as CacheEntry<DataStore[K]> | undefined;

    if (existing && now - existing.timestamp < this.CACHE_DURATION) {
      return existing.data;
    }

    if (existing?.promise) {
      return existing.promise;
    }

    const promise = fetcher();

    if (existing) {
      existing.promise = promise;
    } else {
      this.cache.set(key, { data: initial(), timestamp: 0, promise });
    }

    try {
      const data = await promise;
      this.cache.set(key, { data, timestamp: Date.now() });
      this.notifySubscribers(key);
      return data;
    } catch (error) {
      const entry = this.cache.get(key);
      if (entry) {
        entry.promise = undefined;
      }
      throw error;
    }
  }

  private subscribe(key: DataKey, callback: () => void): () => void {
    let listeners = this.subscribers.get(key);
    if (!listeners) {
      listeners = new Set();
      this.subscribers.set(key, listeners);
    }
    listeners.add(callback);

    return () => {
      const current = this.subscribers.get(key);
      if (!current) {
        return;
      }
      current.delete(callback);
      if (current.size === 0) {
        this.subscribers.delete(key);
      }
    };
  }

  private notifySubscribers(key: DataKey): void {
    const listeners = this.subscribers.get(key);
    if (!listeners || listeners.size === 0) {
      return;
    }
    listeners.forEach((listener) => {
      try {
        listener();
      } catch (err) {
        console.error('DataService subscriber callback failed', err);
      }
    });
  }

  private isCacheValid(key: DataKey): boolean {
    const entry = this.cache.get(key);
    if (!entry) {
      return false;
    }
    return Date.now() - entry.timestamp < this.CACHE_DURATION;
  }

  private buildHeaders(token?: string): Record<string, string> {
    return {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {})
    };
  }

  private async requestSrql<T = unknown>(
    query: string,
    token?: string,
    limit?: number
  ): Promise<SrqlResponse<T>> {
    const body: Record<string, unknown> = { query };
    if (typeof limit === 'number') {
      body.limit = limit;
    }

    const response = await fetch('/api/query', {
      method: 'POST',
      headers: this.buildHeaders(token),
      body: JSON.stringify(body)
    });

    if (!response.ok) {
      let errorMessage = `SRQL query failed (${response.status})`;
      try {
        const errorPayload = (await response.json()) as { error?: string };
        if (typeof errorPayload?.error === 'string' && errorPayload.error.trim()) {
          errorMessage = errorPayload.error;
        }
      } catch {
        // Ignore JSON parse issues for error payloads.
      }
      throw new Error(errorMessage);
    }

    try {
      return (await response.json()) as SrqlResponse<T>;
    } catch (err) {
      console.warn('Failed to parse SRQL response JSON', err);
      return { results: [] };
    }
  }

  private async requestJson<T>(path: string, token?: string): Promise<T> {
    const response = await fetch(path, {
      method: 'GET',
      headers: this.buildHeaders(token),
      cache: 'no-store'
    });

    if (!response.ok) {
      let errorDetails = response.statusText;
      try {
        errorDetails = await response.text();
      } catch {
        // Ignore text parsing issues.
      }
      throw new Error(`Request failed (${response.status}): ${errorDetails}`);
    }

    try {
      return (await response.json()) as T;
    } catch (err) {
      console.warn(`Failed to parse JSON response from ${path}`, err);
      return {} as T;
    }
  }

  private async fetchDeviceStatsSnapshot(
    token?: string
  ): Promise<DeviceStatsFetchResult> {
    const response = await fetch('/api/stats', {
      method: 'GET',
      headers: this.buildHeaders(token),
      cache: 'no-store'
    });

    const headers = this.extractDeviceStatsHeaders(response.headers);

    if (!response.ok) {
      let errorDetails = response.statusText;
      try {
        errorDetails = await response.text();
      } catch {
        // Ignore failures when reading response body.
      }
      const message = `request_failed:${response.status}:${errorDetails}`;
      return {
        snapshot: null,
        headers,
        errorMessage: message
      };
    }

    try {
      const snapshot = (await response.json()) as DeviceStatsSnapshot;
      return { snapshot, headers };
    } catch (err) {
      console.warn('Failed to parse JSON response from /api/stats', err);
      return {
        snapshot: null,
        headers,
        errorMessage: 'invalid_json'
      };
    }
  }

  private extractDeviceStatsHeaders(headers: Headers): DeviceStatsHeaderSummary | null {
    if (!headers) {
      return null;
    }

    const parseIntHeader = (name: string): number | undefined => {
      const value = headers.get(name);
      if (!value) {
        return undefined;
      }
      const parsed = Number.parseInt(value, 10);
      return Number.isFinite(parsed) ? parsed : undefined;
    };

    const summary: DeviceStatsHeaderSummary = {};
    const timestamp = headers.get('X-Serviceradar-Stats-Timestamp');
    if (timestamp && timestamp.trim()) {
      summary.timestamp = timestamp;
    }

    summary.ageMs = parseIntHeader('X-Serviceradar-Stats-Age-Ms');
    summary.rawRecords = parseIntHeader('X-Serviceradar-Stats-Raw-Records');
    summary.processedRecords = parseIntHeader('X-Serviceradar-Stats-Processed-Records');
    summary.skippedNilRecords = parseIntHeader('X-Serviceradar-Stats-Skipped-Nil');
    summary.skippedTombstonedRecords = parseIntHeader('X-Serviceradar-Stats-Skipped-Tombstoned');
    summary.skippedServiceComponents = parseIntHeader('X-Serviceradar-Stats-Skipped-Service-Components');
    summary.skippedNonCanonicalRecords = parseIntHeader(
      'X-Serviceradar-Stats-Skipped-Non-Canonical',
    );

    if (
      summary.timestamp === undefined &&
      summary.ageMs === undefined &&
      summary.rawRecords === undefined &&
      summary.processedRecords === undefined &&
      summary.skippedNilRecords === undefined &&
      summary.skippedTombstonedRecords === undefined &&
      summary.skippedServiceComponents === undefined &&
      summary.skippedNonCanonicalRecords === undefined
    ) {
      return null;
    }

    return summary;
  }

  private async executeSrqlQuery<T>(query: string, token?: string): Promise<T[]> {
    const response = await this.requestSrql<T>(query, token);
    if (!Array.isArray(response.results)) {
      return [];
    }
    return response.results as T[];
  }

  private async fetchCriticalLogsDigest(
    token?: string
  ): Promise<{ logs: CriticalLogSummary[]; counters: CriticalLogCounters | null }> {
    try {
      const [logsRes, countersRes] = await Promise.all([
        this.requestJson<{ logs?: CriticalLogSummary[] }>('/api/logs/critical?limit=50', token),
        this.requestJson<{ counters?: CriticalLogCounters | null }>(
          '/api/logs/critical/counters',
          token
        )
      ]);

      const rawLogs = Array.isArray(logsRes?.logs) ? logsRes.logs : [];
      const logs = rawLogs.map((log) => ({
        ...log,
        severity_text: log.severity_text ?? log.severity
      }));
      const counters = countersRes?.counters ?? null;

      return { logs, counters };
    } catch (error) {
      console.warn('Failed to fetch critical logs digest', error);
      return { logs: [], counters: null };
    }
  }

  private async fetchAllAnalyticsData(token?: string): Promise<AnalyticsData> {
    const now = Date.now();
    const last24HoursIso = new Date(now - 24 * 60 * 60 * 1000).toISOString();
    const last7DaysIso = new Date(now - 7 * 24 * 60 * 60 * 1000).toISOString();

    const slowTraceListQuery = 'in:otel_trace_summaries time:last_24h sort:duration_ms:desc limit:25';
    const queryConfigs: Array<{ query: string; limit?: number }> = [
      { query: `in:events time:[${last24HoursIso},] stats:"count() as total" sort:total:desc` },
      {
        query: `in:events severity:Critical time:[${last24HoursIso},] stats:"count() as total" sort:total:desc`
      },
      {
        query: `in:events severity:High time:[${last24HoursIso},] stats:"count() as total" sort:total:desc`
      },
      {
        query: `in:events severity:Medium time:[${last24HoursIso},] stats:"count() as total" sort:total:desc`
      },
      {
        query: `in:events severity:Low time:[${last24HoursIso},] stats:"count() as total" sort:total:desc`
      },
      {
        query: `in:events severity:(Critical,High) time:[${last24HoursIso},] sort:event_timestamp:desc limit:50`,
        limit: 50
      },
      { query: 'in:otel_metrics stats:"count() as total" sort:total:desc time:last_24h' },
      {
        query:
          'in:otel_trace_summaries time:last_24h stats:"count() as total, sum(if(status_code != 1, 1, 0)) as error_traces, sum(if(duration_ms > 100, 1, 0)) as slow_traces"'
      },
      { query: `in:devices time:[${last7DaysIso},] sort:last_seen:desc limit:120`, limit: 120 },
      { query: 'in:services sort:timestamp:desc limit:150', limit: 150 }
    ];

    const statsPromise = this.fetchDeviceStatsSnapshot(token).catch((error) => {
      console.warn('Failed to fetch device stats snapshot', error);
      return {
        snapshot: null,
        headers: null,
        errorMessage: error instanceof Error ? error.message : 'fetch_failed'
      } satisfies DeviceStatsFetchResult;
    });

    const criticalLogsPromise = this.fetchCriticalLogsDigest(token);

    const results = await Promise.all(
      queryConfigs.map(({ query, limit }) =>
        this.requestSrql(query, token, typeof limit === 'number' ? limit : query.includes('time:') ? 100 : 1000)
          .catch((error) => {
            console.warn(`Query failed: ${query}`, error);
            return { results: [] } as SrqlResponse;
          })
      )
    );

    const [
      totalEventsRes,
      criticalEventsRes,
      highEventsRes,
      mediumEventsRes,
      lowEventsRes,
      recentCriticalEventsRes,
      totalMetricsRes,
      traceAggregatesRes,
      devicesLatestRes,
      servicesLatestRes
    ] = results;

    const statsResult = await statsPromise;
    const stats = statsResult?.snapshot ?? null;
    const statsHeaders = statsResult?.headers ?? null;
    const statsErrorMessage = statsResult?.errorMessage ?? null;
    const statsFresh = this.isStatsSnapshotFresh(stats);
    let statsIsStale = false;
    let statsSampleRecorded = false;

    if (!stats) {
      const reason = statsErrorMessage ?? 'missing_device_stats_snapshot';
      this.recordDeviceCounterSample({
        recordedAt: new Date().toISOString(),
        apiSnapshot: null,
        statsFresh: false,
        error: reason,
        apiHeaders: statsHeaders
      });
      throw new Error(`Analytics requires device stats snapshot (${reason})`);
    }

    if (!statsFresh) {
      const reason = `stale_device_stats_snapshot:${stats.timestamp ?? 'unknown'}`;
      this.recordDeviceCounterSample({
        recordedAt: new Date().toISOString(),
        apiSnapshot: this.summarizeDeviceStats(stats),
        statsFresh: false,
        error: reason,
        apiHeaders: statsHeaders
      });
      statsIsStale = true;
      statsSampleRecorded = true;
    }

    const totalDevices = stats.total_devices;
    const availableDevices =
      stats.available_devices ??
      Math.max(totalDevices - (stats.unavailable_devices ?? 0), 0);
    const unavailableDevices =
      stats.unavailable_devices ??
      Math.max(totalDevices - availableDevices, 0);

    const statsDiagnostics = this.buildDeviceStatsDiagnostics(statsHeaders, stats);
    if (statsIsStale) {
      if (!statsDiagnostics.warnings.includes('stale_snapshot')) {
        statsDiagnostics.warnings.push('stale_snapshot');
      }
      const ageSeconds =
        typeof statsHeaders?.ageMs === 'number'
          ? Math.max(Math.floor(statsHeaders.ageMs / 1000), 0)
          : null;
      const ageHint =
        ageSeconds !== null
          ? `Snapshot age ${ageSeconds}s exceeds freshness threshold.`
          : 'Snapshot age exceeds freshness threshold.';
      statsDiagnostics.details.push(
        `${ageHint} Displaying cached device totals until the next refresh completes.`
      );
    }

    if (!statsSampleRecorded) {
      this.recordDeviceCounterSample({
        recordedAt: new Date().toISOString(),
        apiSnapshot: this.summarizeDeviceStats(stats),
        statsFresh: !statsIsStale,
        error: !statsIsStale && totalDevices === 0 ? 'fresh_snapshot_zero_totals' : undefined,
        apiHeaders: statsHeaders
      });
    }

    const onlineDevices = availableDevices;
    const offlineDevices = unavailableDevices;

    const { logs: criticalLogs, counters: criticalCounters } = await criticalLogsPromise;
    const window24h = criticalCounters?.window_24h ?? {};
    const totalLogs = window24h.total ?? 0;
    const fatalLogs = window24h.fatal ?? 0;
    const errorLogs = window24h.error ?? 0;
    const warningLogs = window24h.warning ?? 0;
    const infoLogs = window24h.info ?? 0;
    const debugLogs = window24h.debug ?? 0;

    const servicesLatest = Array.isArray(servicesLatestRes?.results) ? servicesLatestRes.results : [];
    const {
      failingCount,
      highLatencyCount,
      latencyBuckets
    } = this.computeServiceStats(servicesLatest);

    const totalEvents = this.extractTotal(totalEventsRes);
    const criticalEvents = this.extractTotal(criticalEventsRes);
    const highEvents = this.extractTotal(highEventsRes);
    const mediumEvents = this.extractTotal(mediumEventsRes);
    const lowEvents = this.extractTotal(lowEventsRes);
    const totalMetrics = this.extractTotal(totalMetricsRes);
    const totalTraces = this.extractField(traceAggregatesRes, 'total');
    const slowTraces = this.extractField(traceAggregatesRes, 'slow_traces');
    const errorTraces = this.extractField(traceAggregatesRes, 'error_traces');

    const previousSlowSpans =
      ((this.cache.get('analytics')?.data as AnalyticsData | undefined)?.recentSlowSpans) ?? [];

    const data: AnalyticsData = {
      totalDevices,
      offlineDevices,
      onlineDevices,
      deviceStatsDiagnostics: statsDiagnostics,
      totalEvents,
      criticalEvents,
      highEvents,
      mediumEvents,
      lowEvents,
      recentCriticalEvents: this.sliceResults(recentCriticalEventsRes, 5),
      totalLogs,
      fatalLogs,
      errorLogs,
      warningLogs,
      infoLogs,
      debugLogs,
      recentErrorLogs: criticalLogs,
      criticalLogCounters: criticalCounters ?? null,
      totalMetrics,
      totalTraces,
      slowTraces,
      errorTraces,
      recentSlowSpans: previousSlowSpans,
      devicesLatest: Array.isArray(devicesLatestRes?.results) ? devicesLatestRes.results : [],
      servicesLatest,
      failingServiceCount: failingCount,
      highLatencyServiceCount: highLatencyCount,
      serviceLatencyBuckets: latencyBuckets
    };

    void this.requestSrql<SlowTraceResult>(slowTraceListQuery, token, 25)
      .then((slowTraceListRes) => {
        const slowSpans = this.sliceResults<SlowTraceResult>(slowTraceListRes, 5).map(
          (trace): RecentSlowSpan => ({
            trace_id: trace.trace_id ?? 'unknown_trace',
            service_name: trace.root_service_name || trace.service_name || 'Unknown Service',
            span_name: trace.root_span_name || 'Root Span',
            duration_ms: trace.duration_ms || 0,
            timestamp: trace.timestamp || trace.start_time_unix_nano || null
          })
        );

        const entry = this.cache.get('analytics');
        if (!entry) {
          return;
        }

        const currentData = entry.data as AnalyticsData;
        const merged: AnalyticsData = {
          ...currentData,
          recentSlowSpans: slowSpans
        };

        this.cache.set('analytics', { data: merged, timestamp: Date.now() });
        this.notifySubscribers('analytics');
      })
      .catch((error) => {
        console.warn(`Query failed: ${slowTraceListQuery}`, error);
      });

    return data;
  }

  private getEmptyAnalyticsData(): AnalyticsData {
    return {
      totalDevices: 0,
      offlineDevices: 0,
      onlineDevices: 0,
      deviceStatsDiagnostics: {
        summary: null,
        recordedAt: new Date(0).toISOString(),
        warnings: [],
        details: []
      },
      totalEvents: 0,
      criticalEvents: 0,
      highEvents: 0,
      mediumEvents: 0,
      lowEvents: 0,
      recentCriticalEvents: [],
      totalLogs: 0,
      fatalLogs: 0,
      errorLogs: 0,
      warningLogs: 0,
      infoLogs: 0,
      debugLogs: 0,
      recentErrorLogs: [],
      criticalLogCounters: null,
      totalMetrics: 0,
      totalTraces: 0,
      slowTraces: 0,
      errorTraces: 0,
      recentSlowSpans: [],
      devicesLatest: [],
      servicesLatest: [],
      failingServiceCount: 0,
      highLatencyServiceCount: 0,
      serviceLatencyBuckets: []
    };
  }

  private isStatsSnapshotFresh(
    stats?: DeviceStatsSnapshot | null
  ): boolean {
    if (!stats || !stats.timestamp) {
      return false;
    }

    const parsed = Date.parse(stats.timestamp);
    if (!Number.isFinite(parsed)) {
      return false;
    }

    return Date.now() - parsed <= this.STATS_STALE_THRESHOLD_MS;
  }

  private summarizeDeviceStats(
    stats?: DeviceStatsSnapshot | null
  ): DeviceCounterSnapshotSummary | null {
    if (!stats) {
      return null;
    }

    return {
      timestamp: stats.timestamp,
      total_devices: stats.total_devices,
      available_devices: stats.available_devices,
      unavailable_devices: stats.unavailable_devices,
      active_devices: stats.active_devices
    };
  }

  private recordDeviceCounterSample(sample: DeviceCounterSample): void {
    const source = sample.error ? 'device_stats_error' : 'device_stats';
    const payload = {
      source,
      recordedAt: sample.recordedAt,
      statsFresh: sample.statsFresh,
      error: sample.error ?? null,
      api: sample.apiSnapshot,
      apiHeaders: sample.apiHeaders ?? null
    };

    if (sample.error) {
      console.warn('[Analytics] Device counter sample (error)', payload);
    } else {
      console.info('[Analytics] Device counter sample', payload);
    }

    if (typeof window === 'undefined') {
      return;
    }

    const debugWindow = window as unknown as DeviceCounterDebugWindow;
    const history = debugWindow.__SERVICERADAR_DEVICE_COUNTER_DEBUG__ ?? [];
    const nextHistory = history.concat(sample).slice(-25);
    debugWindow.__SERVICERADAR_DEVICE_COUNTER_DEBUG__ = nextHistory;
  }

  private buildDeviceStatsDiagnostics(
    headers: DeviceStatsHeaderSummary | null,
    stats: DeviceStatsSnapshot | null
  ): DeviceStatsDiagnostics {
    const recordedAt = new Date().toISOString();

    if (!headers) {
      return {
        summary: null,
        recordedAt,
        warnings: ['missing_headers'],
        details: ['Device stats response did not include diagnostic headers.']
      };
    }

    const warnings: string[] = [];
    const details: string[] = [];

    const raw = headers.rawRecords ?? 0;
    const processed = headers.processedRecords ?? 0;
    const skippedNonCanonical = headers.skippedNonCanonicalRecords ?? 0;
    const skippedComponents = headers.skippedServiceComponents ?? 0;
    const skippedTombstoned = headers.skippedTombstonedRecords ?? 0;

    if (skippedNonCanonical > 0) {
      warnings.push('skipped_non_canonical');
      details.push(`Filtered ${skippedNonCanonical.toLocaleString()} non-canonical registry records during aggregation.`);
    }

    if (raw > processed) {
      const difference = raw - processed;
      warnings.push('raw_processed_mismatch');
      details.push(`Registry snapshot contains ${difference.toLocaleString()} records that were excluded from the canonical stats total.`);
    }

    if (skippedComponents > 0) {
      details.push(`Excluded ${skippedComponents.toLocaleString()} ServiceRadar component device records (pollers/agents/checkers).`);
    }

    if (skippedTombstoned > 0) {
      details.push(`Filtered ${skippedTombstoned.toLocaleString()} tombstoned or merged device aliases.`);
    }

    if (stats?.timestamp) {
      details.push(`Snapshot timestamp ${stats.timestamp}`);
    }

    return {
      summary: headers,
      recordedAt,
      warnings,
      details
    };
  }

  private computeServiceStats(
    services: unknown[]
  ): { failingCount: number; highLatencyCount: number; latencyBuckets: ServiceLatencyBucket[] } {
    let failingCount = 0;
    let highLatencyCount = 0;
    const latencyBuckets: ServiceLatencyBucket[] = [];

    services.forEach((entry) => {
      if (!entry || typeof entry !== 'object') {
        return;
      }

      const service = entry as Record<string, unknown>;
      const available = this.normalizeBoolean(service.available);

      if (available === false) {
        failingCount += 1;
      }

      const serviceType =
        this.normalizeString(service.service_type) ?? this.normalizeString(service.type);
      if (serviceType !== 'icmp') {
        return;
      }

      if (available === false) {
        return;
      }

      const responseTimeNs = this.extractResponseTime(service);
      if (typeof responseTimeNs !== 'number') {
        return;
      }

      const responseTimeMs = responseTimeNs / 1_000_000;
      const name =
        this.normalizeDisplayName(service.name) ??
        this.normalizeDisplayName(service.service_name) ??
        'unknown';

      latencyBuckets.push({ name, responseTimeMs });
      if (responseTimeNs > this.LATENCY_THRESHOLD_NS) {
        highLatencyCount += 1;
      }
    });

    latencyBuckets.sort((a, b) => b.responseTimeMs - a.responseTimeMs);
    return { failingCount, highLatencyCount, latencyBuckets };
  }

  private extractResponseTime(service: Record<string, unknown>): number | undefined {
    const direct = service.response_time;
    if (typeof direct === 'number' && Number.isFinite(direct)) {
      return direct;
    }

    const directMs = service.response_time_ms;
    if (typeof directMs === 'number' && Number.isFinite(directMs)) {
      return directMs * 1_000_000;
    }

    const detailsRaw = service.details ?? service.detail;
    if (!detailsRaw) {
      return undefined;
    }

    let details: GenericServiceDetails | undefined;
    if (typeof detailsRaw === 'string') {
      try {
        details = JSON.parse(detailsRaw) as GenericServiceDetails;
      } catch {
        return undefined;
      }
    } else if (typeof detailsRaw === 'object') {
      details = detailsRaw as GenericServiceDetails;
    }

    if (!details) {
      return undefined;
    }

    if (typeof details.response_time === 'number' && Number.isFinite(details.response_time)) {
      return details.response_time;
    }

    const nested = details.data;
    if (nested && typeof nested === 'object') {
      const nestedRecord = nested as Record<string, unknown>;
      const nestedNs = nestedRecord.response_time;
      if (typeof nestedNs === 'number' && Number.isFinite(nestedNs)) {
        return nestedNs;
      }
      const nestedMs = nestedRecord.response_time_ms;
      if (typeof nestedMs === 'number' && Number.isFinite(nestedMs)) {
        return nestedMs * 1_000_000;
      }
    }

    return undefined;
  }

  private normalizeString(value: unknown): string | undefined {
    return typeof value === 'string' && value.trim() ? value.trim().toLowerCase() : undefined;
  }

  private normalizeDisplayName(value: unknown): string | undefined {
    if (typeof value === 'string' && value.trim()) {
      return value;
    }
    return undefined;
  }

  private normalizeBoolean(value: unknown): boolean | undefined {
    if (typeof value === 'boolean') {
      return value;
    }
    if (typeof value === 'string') {
      const normalized = value.trim().toLowerCase();
      if (normalized === 'true') {
        return true;
      }
      if (normalized === 'false') {
        return false;
      }
    }
    if (typeof value === 'number') {
      if (value === 1) {
        return true;
      }
      if (value === 0) {
        return false;
      }
    }
    return undefined;
  }

  private extractField(result: unknown, field: string): number {
    if (!result || typeof result !== 'object') {
      return 0;
    }
    const payload = result as { results?: Array<Record<string, unknown>> };
    if (!Array.isArray(payload.results) || payload.results.length === 0) {
      return 0;
    }
    const row = payload.results[0];
    if (!row || typeof row !== 'object') {
      return 0;
    }
    const value = (row as Record<string, unknown>)[field];
    const numeric = this.toNumber(value as number | string | undefined);
    return numeric ?? 0;
  }

  private extractTotal(result: unknown): number {
    if (!result || typeof result !== 'object') {
      return 0;
    }
    const payload = result as { results?: Array<{ total?: number }> };
    const total = payload.results?.[0]?.total;
    return typeof total === 'number' && Number.isFinite(total) ? total : 0;
  }

  private sliceResults<T = unknown>(result: unknown, limit: number): T[] {
    if (!result || typeof result !== 'object') {
      return [];
    }
    const payload = result as { results?: T[] };
    if (!Array.isArray(payload.results)) {
      return [];
    }
    return payload.results.slice(0, limit);
  }

  private async fetchSysmonSummaries(token?: string): Promise<SysmonAgentSummary[]> {
    const cpuAverageQuery =
      'in:cpu_metrics time:last_2h stats:"avg(usage_percent) as avg_cpu_usage by device_id"';
    const cpuLatestQuery = 'in:cpu_metrics time:last_2h sort:timestamp:desc limit:5000';
    const memoryLatestQuery = 'in:memory_metrics time:last_2h sort:timestamp:desc limit:5000';
    const diskLatestQuery = 'in:disk_metrics time:last_2h sort:timestamp:desc limit:10000';

    const [cpuAvgRows, cpuSampleRows, memoryRows, diskRows] = await Promise.all([
      this.executeSrqlQuery<CpuAverageRow>(cpuAverageQuery, token).catch(() => []),
      this.executeSrqlQuery<CpuSampleRow>(cpuLatestQuery, token).catch(() => []),
      this.executeSrqlQuery<MemorySampleRow>(memoryLatestQuery, token).catch(() => []),
      this.executeSrqlQuery<DiskSampleRow>(diskLatestQuery, token).catch(() => [])
    ]);

    const summaries = new Map<string, SysmonAgentSummary>();
    const cpuAverages = new Map<string, number>();

    cpuAvgRows.forEach((row) => {
      const deviceId = row.device_id;
      const avg = this.toNumber(row.avg_cpu_usage);
      if (deviceId && typeof avg === 'number') {
        cpuAverages.set(deviceId, avg);
      }
    });

    const ensureSummary = (
      deviceId?: string,
      pollerId?: string,
      hostId?: string,
      partition?: string
    ): SysmonAgentSummary | undefined => {
      const derivedDeviceId =
        deviceId ??
        (partition && hostId ? `${partition}:${hostId}` : undefined) ??
        hostId ??
        pollerId;
      if (!derivedDeviceId) {
        return undefined;
      }

      let summary = summaries.get(derivedDeviceId);
      if (!summary) {
        summary = {
          deviceId: deviceId ?? derivedDeviceId,
          pollerId,
          hostId,
          partition,
          disks: []
        };
        summaries.set(derivedDeviceId, summary);
      } else {
        summary.deviceId = summary.deviceId ?? deviceId ?? derivedDeviceId;
        if (pollerId && !summary.pollerId) {
          summary.pollerId = pollerId;
        }
        if (hostId && !summary.hostId) {
          summary.hostId = hostId;
        }
        if (partition && !summary.partition) {
          summary.partition = partition;
        }
      }

      return summary;
    };

    cpuSampleRows.forEach((row) => {
      const summary = ensureSummary(row.device_id, row.poller_id, row.host_id, row.partition);
      if (!summary) {
        return;
      }
      summary.pollerId = summary.pollerId ?? row.poller_id ?? undefined;
      summary.agentId = summary.agentId ?? row.agent_id ?? undefined;
      summary.hostId = summary.hostId ?? row.host_id ?? undefined;
      summary.deviceId = summary.deviceId ?? row.device_id ?? undefined;
      summary.partition = summary.partition ?? row.partition ?? undefined;
      const derivedId = summary.deviceId ?? row.device_id ?? summary.pollerId ?? summary.hostId;
      if (derivedId && cpuAverages.has(derivedId)) {
        summary.avgCpuUsage = cpuAverages.get(derivedId);
      } else if (summary.avgCpuUsage === undefined) {
        summary.avgCpuUsage = this.toNumber(row.usage_percent);
      }
      const ts = this.normalizeTimestamp(row.timestamp);
      if (ts) {
        summary.lastTimestamp = summary.lastTimestamp
          ? new Date(summary.lastTimestamp) > new Date(ts)
            ? summary.lastTimestamp
            : ts
          : ts;
      }
    });

    memoryRows.forEach((row) => {
      const summary = ensureSummary(row.device_id, row.poller_id, row.host_id, row.partition);
      if (!summary) {
        return;
      }
      summary.pollerId = summary.pollerId ?? row.poller_id ?? undefined;
      summary.agentId = summary.agentId ?? row.agent_id ?? undefined;
      summary.hostId = summary.hostId ?? row.host_id ?? undefined;
      summary.deviceId = summary.deviceId ?? row.device_id ?? undefined;
      summary.partition = summary.partition ?? row.partition ?? undefined;
      summary.memoryUsagePercent = this.toNumber(row.usage_percent);
      summary.usedMemoryBytes = this.toNumber(row.used_bytes);
      summary.totalMemoryBytes = this.toNumber(row.total_bytes);

      const timestamp = this.normalizeTimestamp(row.timestamp);
      if (timestamp) {
        summary.lastTimestamp = summary.lastTimestamp
          ? new Date(summary.lastTimestamp) > new Date(timestamp)
            ? summary.lastTimestamp
            : timestamp
          : timestamp;
      }
    });

    diskRows.forEach((row) => {
      if (!row.mount_point) {
        return;
      }
      const summary = ensureSummary(row.device_id, row.poller_id, row.host_id, row.partition);
      if (!summary) {
        return;
      }
      summary.pollerId = summary.pollerId ?? row.poller_id ?? undefined;
      summary.agentId = summary.agentId ?? row.agent_id ?? undefined;
      summary.hostId = summary.hostId ?? row.host_id ?? undefined;
      summary.deviceId = summary.deviceId ?? row.device_id ?? undefined;
      summary.partition = summary.partition ?? row.partition ?? undefined;

      const diskEntry: SysmonDiskSummary = {
        mountPoint: row.mount_point,
        usagePercent: this.toNumber(row.usage_percent),
        usedBytes: this.toNumber(row.used_bytes),
        totalBytes: this.toNumber(row.total_bytes),
        lastTimestamp: this.normalizeTimestamp(row.timestamp)
      };
      const existing = summary.disks.find((disk) => disk.mountPoint === diskEntry.mountPoint);
      if (existing) {
        const existingTimestamp = existing.lastTimestamp ? new Date(existing.lastTimestamp) : null;
        const newTimestamp = diskEntry.lastTimestamp ? new Date(diskEntry.lastTimestamp) : null;
        if (!existingTimestamp || (newTimestamp && newTimestamp > existingTimestamp)) {
          existing.usagePercent = diskEntry.usagePercent;
          existing.usedBytes = diskEntry.usedBytes;
          existing.totalBytes = diskEntry.totalBytes;
          existing.lastTimestamp = diskEntry.lastTimestamp;
        }
      } else {
        summary.disks.push(diskEntry);
      }

      if (diskEntry.lastTimestamp) {
        summary.lastTimestamp = summary.lastTimestamp
          ? new Date(summary.lastTimestamp) > new Date(diskEntry.lastTimestamp)
            ? summary.lastTimestamp
            : diskEntry.lastTimestamp
          : diskEntry.lastTimestamp;
      }
    });

    cpuAverages.forEach((avg, deviceId) => {
      const summary = summaries.get(deviceId) ?? ensureSummary(deviceId);
      if (summary && summary.avgCpuUsage === undefined) {
        summary.avgCpuUsage = avg;
      }
    });

    return Array.from(summaries.values()).sort((a, b) => {
      const deviceA = a.deviceId ?? '';
      const deviceB = b.deviceId ?? '';
      if (deviceA !== deviceB) {
        return deviceA.localeCompare(deviceB);
      }
      const pollerA = a.pollerId ?? '';
      const pollerB = b.pollerId ?? '';
      return pollerA.localeCompare(pollerB);
    });
  }

  private async fetchRperfData(token?: string): Promise<RperfData[]> {
    const query = 'in:rperf_metrics time:last_2h sort:timestamp:asc limit:2000';
    const rows = await this.executeSrqlQuery<SrqlRperfRow>(query, token).catch(() => []);

    if (!rows.length) {
      return [];
    }

    const grouped = new Map<string, RperfMetric[]>();
    const dedupe = new Set<string>();

    rows.forEach((row) => {
      const parsed = this.rowToMetric(row);
      if (!parsed) {
        return;
      }

      const { pollerId, metric } = parsed;
      const key = `${pollerId}|${metric.target}|${metric.timestamp}|${metric.bits_per_second}|${metric.bytes_sent}|${metric.bytes_received}`;
      if (dedupe.has(key)) {
        return;
      }
      dedupe.add(key);

      const entry = grouped.get(pollerId);
      if (entry) {
        entry.push(metric);
      } else {
        grouped.set(pollerId, [metric]);
      }
    });

    return Array.from(grouped.entries()).map(([pollerId, rperfMetrics]) => ({
      pollerId,
      rperfMetrics
    }));
  }

  private rowToMetric(row: SrqlRperfRow): { pollerId: string; metric: RperfMetric } | null {
    const rawPayload = row.metadata ?? row.message;
    if (!rawPayload) {
      return null;
    }

    let metadata: RperfMetadataPayload;
    try {
      metadata = JSON.parse(rawPayload) as RperfMetadataPayload;
    } catch (err) {
      console.error('Failed to parse rperf metadata payload', err);
      return null;
    }

    const pollerId =
      row.poller_id ||
      metadata.agent_id ||
      metadata.service_name ||
      metadata.service_type ||
      'unknown';

    const timestamp =
      this.normalizeTimestamp(row.timestamp) ??
      this.normalizeTimestamp(metadata.timestamp) ??
      new Date().toISOString();

    const metric: RperfMetric = {
      timestamp,
      name: metadata.name ?? row.metric_name ?? 'rperf_metric',
      target: metadata.target ?? row.target_device_ip ?? metadata.agent_id ?? 'unknown',
      agent_id: metadata.agent_id ?? '',
      service_name: metadata.service_name ?? '',
      service_type: metadata.service_type ?? '',
      version: metadata.version ?? '',
      response_time: metadata.response_time ?? 0,
      success: metadata.success ?? false,
      error: metadata.error ?? null,
      bits_per_second: metadata.bits_per_second ?? 0,
      bytes_received: metadata.bytes_received ?? 0,
      bytes_sent: metadata.bytes_sent ?? 0,
      duration: metadata.duration ?? 0,
      jitter_ms: metadata.jitter_ms ?? 0,
      loss_percent: metadata.loss_percent ?? 0,
      packets_lost: metadata.packets_lost ?? 0,
      packets_received: metadata.packets_received ?? 0,
      packets_sent: metadata.packets_sent ?? 0
    };

    return { pollerId, metric };
  }

  private toNumber(value: number | string | undefined): number | undefined {
    if (typeof value === 'number') {
      return Number.isFinite(value) ? value : undefined;
    }
    if (typeof value === 'string' && value.trim() !== '') {
      const parsed = Number(value);
      return Number.isFinite(parsed) ? parsed : undefined;
    }
    return undefined;
  }

  private normalizeTimestamp(timestamp?: string): string | undefined {
    if (!timestamp) {
      return undefined;
    }
    const parsed = Date.parse(timestamp);
    if (Number.isNaN(parsed)) {
      return undefined;
    }
    return new Date(parsed).toISOString();
  }
}

export const dataService = new DataService();
