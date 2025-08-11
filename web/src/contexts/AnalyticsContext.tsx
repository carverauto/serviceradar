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

'use client';

import React, { createContext, useContext, useState, useEffect, useCallback } from 'react';
import { analyticsService } from '@/services/analyticsService';
import { useAuth } from '@/components/AuthProvider';

interface AnalyticsData {
  totalDevices: number;
  offlineDevices: number;
  onlineDevices: number;
  totalEvents: number;
  criticalEvents: number;
  highEvents: number;
  mediumEvents: number;
  lowEvents: number;
  recentCriticalEvents: unknown[];
  totalLogs: number;
  fatalLogs: number;
  errorLogs: number;
  warningLogs: number;
  infoLogs: number;
  debugLogs: number;
  recentErrorLogs: unknown[];
  totalMetrics: number;
  totalTraces: number;
  slowMetrics: number;
  errorMetrics: number;
  recentSlowSpans: unknown[];
  devicesLatest: unknown[];
  pollers: unknown[];
}

interface AnalyticsContextType {
  data: AnalyticsData | null;
  loading: boolean;
  error: string | null;
  refresh: () => Promise<void>;
}

const AnalyticsContext = createContext<AnalyticsContextType | undefined>(undefined);

export const useAnalytics = () => {
  const context = useContext(AnalyticsContext);
  if (context === undefined) {
    throw new Error('useAnalytics must be used within an AnalyticsProvider');
  }
  return context;
};

export const AnalyticsProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const { token } = useAuth();
  const [data, setData] = useState<AnalyticsData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchData = useCallback(async () => {
    try {
      console.log('[AnalyticsProvider] Fetching analytics data');
      setError(null);
      const analyticsData = await analyticsService.getAnalyticsData(token ?? undefined);
      setData(analyticsData);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to fetch analytics data');
    } finally {
      setLoading(false);
    }
  }, [token]);

  const refresh = useCallback(async () => {
    setLoading(true);
    await fetchData();
  }, [fetchData]);

  useEffect(() => {
    // Initial fetch
    fetchData();

    // Set up refresh interval (60 seconds)
    const interval = setInterval(fetchData, 60000);

    return () => clearInterval(interval);
  }, [fetchData]);

  const value = {
    data,
    loading,
    error,
    refresh,
  };

  return (
    <AnalyticsContext.Provider value={value}>
      {children}
    </AnalyticsContext.Provider>
  );
};