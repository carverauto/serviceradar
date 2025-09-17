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
  slowMetrics: number;
  errorMetrics: number;
  recentSlowSpans: unknown[];
  
  // Device data for widgets
  devicesLatest: unknown[];
  servicesLatest: unknown[];
  
  // Pollers data
  pollers: unknown[];
}

interface CachedAnalyticsData {
  data: AnalyticsData;
  timestamp: number;
  promise?: Promise<AnalyticsData>;
}

class AnalyticsService {
  private cache: CachedAnalyticsData | null = null;
  private readonly CACHE_DURATION = 30000; // 30 seconds cache
  private subscribers: Set<() => void> = new Set();

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
      'in:otel_traces stats:"count() as total" sort:total:desc time:last_24h',
      'in:otel_metrics is_slow:true stats:"count() as total" sort:total:desc time:last_24h',
      'in:otel_metrics http_status_code:[400,] stats:"count() as total" sort:total:desc time:last_24h',
      'in:otel_metrics is_slow:true time:last_24h sort:timestamp:desc limit:100',
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

    // Get pollers data
    const pollersPromise = fetch('/api/pollers', { headers })
      .then(res => res.ok ? res.json() : [])
      .catch(() => []);

    // Wait for all data
    const [queryResults, pollers] = await Promise.all([
      Promise.all(queryPromises),
      pollersPromise
    ]);

    // Parse results
    const [
      totalDevicesRes, offlineDevicesRes, totalEventsRes, criticalEventsRes,
      highEventsRes, mediumEventsRes, lowEventsRes, recentCriticalEventsRes,
      totalLogsRes, fatalLogsRes, errorLogsRes, warningLogsRes, infoLogsRes,
      debugLogsRes, recentErrorLogsRes, totalMetricsRes, totalTracesRes,
      slowMetricsRes, errorMetricsRes, recentSlowSpansRes, devicesLatestRes, servicesLatestRes
    ] = queryResults;

    const totalDevices = totalDevicesRes.results[0]?.total || 0;
    const offlineDevices = offlineDevicesRes.results[0]?.total || 0;

    return {
      // Device stats
      totalDevices,
      offlineDevices,
      onlineDevices: totalDevices - offlineDevices,
      
      // Event stats
      totalEvents: totalEventsRes.results[0]?.total || 0,
      criticalEvents: criticalEventsRes.results[0]?.total || 0,
      highEvents: highEventsRes.results[0]?.total || 0,
      mediumEvents: mediumEventsRes.results[0]?.total || 0,
      lowEvents: lowEventsRes.results[0]?.total || 0,
      recentCriticalEvents: (recentCriticalEventsRes.results || []).slice(0, 5),
      
      // Log stats
      totalLogs: totalLogsRes.results[0]?.total || 0,
      fatalLogs: fatalLogsRes.results[0]?.total || 0,
      errorLogs: errorLogsRes.results[0]?.total || 0,
      warningLogs: warningLogsRes.results[0]?.total || 0,
      infoLogs: infoLogsRes.results[0]?.total || 0,
      debugLogs: debugLogsRes.results[0]?.total || 0,
      recentErrorLogs: (recentErrorLogsRes.results || []).slice(0, 5),
      
      // Observability stats
      totalMetrics: totalMetricsRes.results[0]?.total || 0,
      totalTraces: totalTracesRes.results[0]?.total || 0,
      slowMetrics: slowMetricsRes.results[0]?.total || 0,
      errorMetrics: errorMetricsRes.results[0]?.total || 0,
      recentSlowSpans: (recentSlowSpansRes.results || []).slice(0, 5),
      
      // Raw data for widgets
      devicesLatest: devicesLatestRes.results || [],
      servicesLatest: servicesLatestRes.results || [],
      pollers: pollers || []
    };
  }

  private getEmptyData(): AnalyticsData {
    return {
      totalDevices: 0, offlineDevices: 0, onlineDevices: 0,
      totalEvents: 0, criticalEvents: 0, highEvents: 0, mediumEvents: 0, lowEvents: 0, recentCriticalEvents: [],
      totalLogs: 0, fatalLogs: 0, errorLogs: 0, warningLogs: 0, infoLogs: 0, debugLogs: 0, recentErrorLogs: [],
      totalMetrics: 0, totalTraces: 0, slowMetrics: 0, errorMetrics: 0, recentSlowSpans: [],
      devicesLatest: [], servicesLatest: [], pollers: []
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
}

// Export singleton instance
export const analyticsService = new AnalyticsService();
