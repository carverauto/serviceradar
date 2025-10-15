/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
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

export interface ServiceLatencyBucket {
  name: string;
  responseTimeMs: number;
}

export interface AnalyticsData {
  // Device stats
  totalDevices: number;
  offlineDevices: number;
  onlineDevices: number;
  
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
  recentErrorLogs: unknown[];
  
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

interface CachedAnalyticsData {
  data: AnalyticsData;
  timestamp: number;
  promise?: Promise<AnalyticsData>;
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

interface RecentSlowSpan {
  trace_id: string;
  service_name: string;
  span_name: string;
  duration_ms: number;
  timestamp: string | number | null;
}

class AnalyticsService {
  private cache: CachedAnalyticsData | null = null;
  private readonly CACHE_DURATION = 30000; // 30 seconds cache
  private subscribers: Set<() => void> = new Set();
  private readonly LATENCY_THRESHOLD_NS = 100 * 1_000_000; // 100ms

  async getAnalyticsData(token?: string): Promise<AnalyticsData> {
    const now = Date.now();
    
    // Return cached data if still valid
    if (this.cache && (now - this.cache.timestamp) < this.CACHE_DURATION) {
      return this.cache.data;
    }
    
    // If there's already a request in flight, wait for it
    if (this.cache?.promise) {
      return this.cache.promise;
    }
    
    // Start new request
    const promise = this.fetchAllAnalyticsData(token);
    
    // Store the promise to prevent duplicate requests
    if (this.cache) {
      this.cache.promise = promise;
    } else {
      this.cache = {
        data: this.getEmptyData(),
        timestamp: 0,
        promise
      };
    }
    
    try {
      const data = await promise;
      
      // Update cache with successful result
      this.cache = {
        data,
        timestamp: now,
        promise: undefined
      };
      
      // Notify all subscribers
      this.notifySubscribers();
      
      return data;
    } catch (error) {
      // Clear the promise on error so retry can work
      if (this.cache) {
        this.cache.promise = undefined;
      }
      throw error;
    }
  }

  private async fetchAllAnalyticsData(token?: string): Promise<AnalyticsData> {
    
    const headers = {
      'Content-Type': 'application/json',
      ...(token && { Authorization: `Bearer ${token}` }),
    };

    const now = Date.now();
    const last24HoursIso = new Date(now - 24 * 60 * 60 * 1000).toISOString();
    const last7DaysIso = new Date(now - 7 * 24 * 60 * 60 * 1000).toISOString();

    // Execute all queries in parallel - this reduces from 20+ queries to 1 batch
    const queries = [
      'in:devices stats:"count() as total" sort:total:desc',
      'in:devices is_available:false stats:"count() as total" sort:total:desc',
      `in:events time:[${last24HoursIso},] stats:"count() as total" sort:total:desc`,
      `in:events severity:Critical time:[${last24HoursIso},] stats:"count() as total" sort:total:desc`,
      `in:events severity:High time:[${last24HoursIso},] stats:"count() as total" sort:total:desc`,
      `in:events severity:Medium time:[${last24HoursIso},] stats:"count() as total" sort:total:desc`,
      `in:events severity:Low time:[${last24HoursIso},] stats:"count() as total" sort:total:desc`,
      `in:events severity:(Critical,High) time:[${last24HoursIso},] sort:event_timestamp:desc limit:100`,
      'in:logs stats:"count() as total" sort:total:desc time:last_24h',
      'in:logs severity_text:fatal stats:"count() as total" sort:total:desc time:last_24h',
      'in:logs severity_text:error stats:"count() as total" sort:total:desc time:last_24h',
      'in:logs severity_text:(warning,warn) stats:"count() as total" sort:total:desc time:last_24h',
      'in:logs severity_text:info stats:"count() as total" sort:total:desc time:last_24h',
      'in:logs severity_text:debug stats:"count() as total" sort:total:desc time:last_24h',
      'in:logs severity_text:(fatal,error) time:last_24h sort:timestamp:desc limit:100',
      'in:otel_metrics stats:"count() as total" sort:total:desc time:last_24h',
      'in:otel_trace_summaries stats:"count() as total" sort:total:desc time:last_24h',
      'in:otel_trace_summaries status_code!=1 stats:"count() as total" sort:total:desc time:last_24h',
      'in:otel_trace_summaries duration_ms>100 stats:"count() as total" sort:total:desc time:last_24h',
      'in:otel_trace_summaries time:last_24h sort:duration_ms:desc limit:100',
      `in:devices time:[${last7DaysIso},] sort:last_seen:desc limit:100`,
      'in:services sort:timestamp:desc limit:200'
    ];

    // Batch all queries together
    const queryPromises = queries.map(async (query, index) => {
      try {
        const response = await fetch('/api/query', {
          method: 'POST',
          headers,
          body: JSON.stringify({ query, limit: index < 15 ? 1000 : 100 }), // Different limits for different query types
        });
        
        if (!response.ok) {
          const errorData = await response.json();
          throw new Error(errorData.error || `Failed to execute query: ${query}`);
        }
        
        return response.json();
      } catch (error) {
        console.warn(`Query failed: ${query}`, error);
        return { results: [] }; // Return empty results for failed queries
      }
    });

    // Wait for all data
    const queryResults = await Promise.all(queryPromises);

    // Parse results
    const [
      totalDevicesRes, offlineDevicesRes, totalEventsRes, criticalEventsRes,
      highEventsRes, mediumEventsRes, lowEventsRes, recentCriticalEventsRes,
      totalLogsRes, fatalLogsRes, errorLogsRes, warningLogsRes, infoLogsRes,
      debugLogsRes, recentErrorLogsRes, totalMetricsRes, totalTracesRes,
      errorTracesRes, slowTracesRes, slowTraceListRes, devicesLatestRes, servicesLatestRes
    ] = queryResults;

    const servicesLatest = Array.isArray(servicesLatestRes?.results) ? servicesLatestRes.results : [];
    const {
      failingCount,
      highLatencyCount,
      latencyBuckets
    } = this.computeServiceStats(servicesLatest);

    const totalDevices = Array.isArray(totalDevicesRes?.results) ? totalDevicesRes.results[0]?.total || 0 : 0;
    const offlineDevices = Array.isArray(offlineDevicesRes?.results) ? offlineDevicesRes.results[0]?.total || 0 : 0;

    return {
      // Device stats
      totalDevices,
      offlineDevices,
      onlineDevices: Math.max(totalDevices - offlineDevices, 0),
      
      // Event stats
      totalEvents: this.extractTotal(totalEventsRes),
      criticalEvents: this.extractTotal(criticalEventsRes),
      highEvents: this.extractTotal(highEventsRes),
      mediumEvents: this.extractTotal(mediumEventsRes),
      lowEvents: this.extractTotal(lowEventsRes),
      recentCriticalEvents: this.sliceResults(recentCriticalEventsRes, 5),
      
      // Log stats
      totalLogs: this.extractTotal(totalLogsRes),
      fatalLogs: this.extractTotal(fatalLogsRes),
      errorLogs: this.extractTotal(errorLogsRes),
      warningLogs: this.extractTotal(warningLogsRes),
      infoLogs: this.extractTotal(infoLogsRes),
      debugLogs: this.extractTotal(debugLogsRes),
      recentErrorLogs: this.sliceResults(recentErrorLogsRes, 5),
      
      // Observability stats
      totalMetrics: this.extractTotal(totalMetricsRes),
      totalTraces: this.extractTotal(totalTracesRes),
      slowTraces: this.extractTotal(slowTracesRes),
      errorTraces: this.extractTotal(errorTracesRes),
      recentSlowSpans: this.sliceResults<SlowTraceResult>(slowTraceListRes, 5).map((trace): RecentSlowSpan => ({
        trace_id: trace.trace_id ?? 'unknown_trace',
        service_name: trace.root_service_name || trace.service_name || 'Unknown Service',
        span_name: trace.root_span_name || 'Root Span',
        duration_ms: trace.duration_ms || 0,
        timestamp: trace.timestamp || trace.start_time_unix_nano || null,
      })),
      
      // Raw data for widgets
      devicesLatest: Array.isArray(devicesLatestRes?.results) ? devicesLatestRes.results : [],
      servicesLatest,
      failingServiceCount: failingCount,
      highLatencyServiceCount: highLatencyCount,
      serviceLatencyBuckets: latencyBuckets
    };
  }

  private getEmptyData(): AnalyticsData {
    return {
      totalDevices: 0, offlineDevices: 0, onlineDevices: 0,
      totalEvents: 0, criticalEvents: 0, highEvents: 0, mediumEvents: 0, lowEvents: 0, recentCriticalEvents: [],
      totalLogs: 0, fatalLogs: 0, errorLogs: 0, warningLogs: 0, infoLogs: 0, debugLogs: 0, recentErrorLogs: [],
      totalMetrics: 0, totalTraces: 0, slowTraces: 0, errorTraces: 0, recentSlowSpans: [],
      devicesLatest: [], servicesLatest: [], failingServiceCount: 0, highLatencyServiceCount: 0, serviceLatencyBuckets: []
    };
  }

  // Subscription system for real-time updates
  subscribe(callback: () => void): () => void {
    this.subscribers.add(callback);
    return () => this.subscribers.delete(callback);
  }

  private notifySubscribers(): void {
    this.subscribers.forEach(callback => callback());
  }

  // Method to force refresh
  refresh(token?: string): Promise<AnalyticsData> {
    this.cache = null;
    return this.getAnalyticsData(token);
  }

  // Check if cache is valid
  isCacheValid(): boolean {
    if (!this.cache) return false;
    const now = Date.now();
    return (now - this.cache.timestamp) < this.CACHE_DURATION;
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

      const serviceType = this.normalizeString(service.service_type) ?? this.normalizeString(service.type);
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
}

// Export singleton instance
export const analyticsService = new AnalyticsService();
