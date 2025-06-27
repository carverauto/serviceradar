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

import React, { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import {
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  ResponsiveContainer
} from 'recharts';
import { RefreshCw, AlertCircle, ArrowLeft } from 'lucide-react';
import { useAuth } from '@/components/AuthProvider';

// Constants
const AUTO_REFRESH_INTERVAL = 10000; // 10 seconds, matching other components

const DuskDashboard = ({ initialDuskService = null, pollerId, initialError = null }) => {
  const router = useRouter();
  const { token } = useAuth(); // Get authentication token
  const [pollerStatus, setPollerStatus] = useState(initialDuskService);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(initialError);
  const [blockHistory, setBlockHistory] = useState([]);
  const [refreshing, setRefreshing] = useState(false);
  const [chartHeight, setChartHeight] = useState(300);
  const [lastUpdated, setLastUpdated] = useState(new Date());
  const [autoRefreshEnabled, setAutoRefreshEnabled] = useState(true);

  // Parse service details and extract block history
  const parseServiceDetails = useCallback((service) => {
    if (!service) return;

    try {
      const details = typeof service.details === 'string'
          ? JSON.parse(service.details)
          : service.details;

      if (details?.history && Array.isArray(details.history)) {
        setBlockHistory(details.history);
      }

      return details;
    } catch (e) {
      console.error('Error parsing service details:', e);
      return {};
    }
  }, []);

  // Initialize from props
  useEffect(() => {
    if (initialDuskService) {
      setPollerStatus(initialDuskService);
      parseServiceDetails(initialDuskService);
    }

    if (initialError) {
      setError(initialError);
    }
  }, [initialDuskService, initialError, parseServiceDetails]);

  // Function to fetch latest service data
  const fetchLatestData = useCallback(async () => {
    if (!pollerId) return;

    try {
      setRefreshing(true);

      // Create headers with authentication token if available
      const headers = {
        'Content-Type': 'application/json',
      };

      if (token) {
        headers['Authorization'] = `Bearer ${token}`;
      }

      // Use the Next.js API routes
      const response = await fetch(`/api/pollers/${pollerId}/services/dusk`, {
        headers,
        cache: 'no-store',
      });

      if (!response.ok) {
        throw new Error(`Service data request failed: ${response.status}`);
      }

      const serviceData = await response.json();
      setPollerStatus(serviceData);
      parseServiceDetails(serviceData);
      setLastUpdated(new Date());
      setError(null);
    } catch (err) {
      console.error('Error fetching dusk service data:', err);
      setError(err.message || 'Failed to fetch service data');
    } finally {
      setRefreshing(false);
    }
  }, [pollerId, token, parseServiceDetails]);

  // Set up auto-refresh using router.refresh() and manual data fetching
  useEffect(() => {
    if (!autoRefreshEnabled) return;

    const intervalId = setInterval(() => {
      // Use Next.js router refresh to trigger server-side refetch
      router.refresh();

      // Also directly fetch the latest data
      fetchLatestData();
    }, AUTO_REFRESH_INTERVAL);

    return () => {
      clearInterval(intervalId);
    };
  }, [router, autoRefreshEnabled, fetchLatestData]);

  // Manual refresh handler
  const handleManualRefresh = () => {
    setRefreshing(true);
    router.refresh();
    fetchLatestData();
  };

  // Toggle auto-refresh
  const toggleAutoRefresh = () => {
    setAutoRefreshEnabled(!autoRefreshEnabled);
  };

  // Handler to go back to the main dashboard
  const handleBackToDashboard = () => {
    router.push('/dashboard');
  };

  // Adjust chart height based on screen size
  useEffect(() => {
    const handleResize = () => {
      const width = window.innerWidth;
      if (width < 640) { // small screens
        setChartHeight(200);
      } else if (width < 1024) { // medium screens
        setChartHeight(250);
      } else { // large screens
        setChartHeight(300);
      }
    };

    handleResize(); // Initial call
    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  }, []);

  // Loading state
  if (loading && !pollerStatus) {
    return (
        <div className="flex justify-center items-center h-64">
          <div className="text-lg dark:text-gray-100 transition-colors">
            Loading Dusk poller status...
          </div>
        </div>
    );
  }

  // Error state with no data
  if (!pollerStatus && error) {
    return (
        <div className="space-y-6">
          <div className="flex justify-between items-center">
            <h2 className="text-xl sm:text-2xl font-bold text-gray-800 dark:text-gray-100">
              Dusk Node Monitor - {pollerId}
            </h2>
            <button
                onClick={handleBackToDashboard}
                className="px-4 py-2 bg-gray-100 dark:bg-gray-700 dark:text-gray-100 hover:bg-gray-200 dark:hover:bg-gray-600 rounded transition-colors flex items-center self-start"
            >
              <ArrowLeft className="mr-2 h-4 w-4" />
              Back to Dashboard
            </button>
          </div>

          <div className="bg-red-50 dark:bg-red-900/30 p-6 rounded-lg flex flex-col items-center">
            <AlertCircle className="h-8 w-8 text-red-500 dark:text-red-400 mb-2" />
            <div className="text-red-600 dark:text-red-300 text-lg font-medium mb-4">
              {error}
            </div>
            <button
                onClick={handleManualRefresh}
                className="px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-800 dark:text-gray-200 rounded hover:bg-gray-300 dark:hover:bg-gray-600 flex items-center"
            >
              <RefreshCw className="mr-2 h-4 w-4" />
              Retry
            </button>
          </div>
        </div>
    );
  }

  // Parse details
  const details = pollerStatus?.details || {};
  let parsedDetails = {};
  try {
    parsedDetails = typeof details === 'string' ? JSON.parse(details) : details;
  } catch (e) {
    console.error('Error parsing details:', e);
  }

  return (
      <div className="space-y-6 transition-colors">
        {/* Header with back button and refresh controls */}
        <div className="flex justify-between items-center">
          <div className="flex items-center gap-2">
            <button
                onClick={handleBackToDashboard}
                className="p-2 rounded-full bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600 transition-colors"
            >
              <ArrowLeft className="h-5 w-5" />
              <span className="sr-only">Back to Dashboard</span>
            </button>
            <h2 className="text-xl sm:text-2xl font-bold text-gray-800 dark:text-gray-100">
              Dusk Node Monitor - {pollerId}
            </h2>
          </div>

          <div className="flex items-center gap-2">
            <button
                onClick={handleManualRefresh}
                className="p-2 rounded-full bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600 transition-colors"
                disabled={refreshing}
            >
              <RefreshCw className={`h-5 w-5 ${refreshing ? 'animate-spin' : ''}`} />
              <span className="sr-only">Refresh Data</span>
            </button>
            <button
                onClick={toggleAutoRefresh}
                className={`px-3 py-1 rounded text-sm ${
                    autoRefreshEnabled
                        ? 'bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-100'
                        : 'bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-300'
                }`}
            >
              {autoRefreshEnabled ? 'Auto-refresh On' : 'Auto-refresh Off'}
            </button>
          </div>
        </div>

        {/* Error Alert */}
        {error && (
            <div className="bg-red-50 dark:bg-red-900/30 p-4 rounded-lg">
              <div className="flex items-center">
                <AlertCircle className="h-5 w-5 text-red-500 dark:text-red-400 mr-2" />
                <div className="text-red-600 dark:text-red-300 font-medium">
                  Warning: {error}
                </div>
              </div>
              <div className="mt-1 text-sm text-red-500 dark:text-red-400">
                {pollerStatus
                    ? 'Showing last known data. Auto-refresh will continue to attempt reconnection.'
                    : 'No data available. Please check your connection and try again.'}
              </div>
            </div>
        )}

        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          {/* Card 1: Poller Status */}
          <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
            <h3 className="text-lg font-semibold mb-2 text-gray-800 dark:text-gray-100">
              Poller Status
            </h3>
            <div
                className={`text-lg transition-colors ${
                    pollerStatus?.available
                        ? 'text-green-600 dark:text-green-400'
                        : 'text-red-600 dark:text-red-400'
                }`}
            >
              {pollerStatus?.available ? 'Online' : 'Offline'}
            </div>
          </div>

          {/* Card 2: Current Height */}
          <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
            <h3 className="text-lg font-semibold mb-2 text-gray-800 dark:text-gray-100">
              Current Height
            </h3>
            <div className="text-lg text-gray-800 dark:text-gray-100">
              {parsedDetails.height || 'N/A'}
            </div>
          </div>

          {/* Card 3: Latest Hash */}
          <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-6 transition-colors">
            <h3 className="text-lg font-semibold mb-2 text-gray-800 dark:text-gray-100">
              Latest Hash
            </h3>
            <div className="text-sm font-mono break-all text-gray-700 dark:text-gray-200">
              {parsedDetails.hash || 'N/A'}
            </div>
          </div>
        </div>

        {/* Last Updated Indicator */}
        <div className="flex justify-end items-center text-xs text-gray-500 dark:text-gray-400">
          <div className={refreshing ? 'text-blue-500 dark:text-blue-400' : 'invisible'}>
            <RefreshCw className="inline-block h-3 w-3 mr-1 animate-spin" />
            Refreshing data...
          </div>
          <div>
            Last updated: {lastUpdated.toLocaleString()}
          </div>
        </div>
      </div>
  );
};

export default DuskDashboard;