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

import { useState, useEffect, useCallback } from 'react';
import { analyticsService } from '@/services/analyticsService';
import { useAuth } from '@/components/AuthProvider';

export const useAnalytics = () => {
  const { token } = useAuth();
  const [data, setData] = useState(analyticsService.isCacheValid() ? null : null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchData = useCallback(async () => {
    try {
      setError(null);
      const analyticsData = await analyticsService.getAnalyticsData(token);
      setData(analyticsData);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to fetch analytics data');
    } finally {
      setLoading(false);
    }
  }, [token]);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      setError(null);
      const analyticsData = await analyticsService.refresh(token);
      setData(analyticsData);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to refresh analytics data');
    } finally {
      setLoading(false);
    }
  }, [token]);

  useEffect(() => {
    // Initial fetch
    fetchData();

    // Subscribe to updates
    const unsubscribe = analyticsService.subscribe(() => {
      fetchData();
    });

    // Set up refresh interval (60 seconds)
    const interval = setInterval(() => {
      fetchData();
    }, 60000);

    return () => {
      unsubscribe();
      clearInterval(interval);
    };
  }, [fetchData]);

  return {
    data,
    loading,
    error,
    refresh,
    isStale: !analyticsService.isCacheValid()
  };
};