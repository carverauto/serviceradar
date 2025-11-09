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

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Activity, AlertTriangle, RefreshCw } from 'lucide-react';

type WatcherStatus = 'running' | 'stopped' | 'error';

type WatcherInfo = {
  id: string;
  service: string;
  scope: string;
  kv_key: string;
  started_at: string;
  last_event?: string;
  status: WatcherStatus;
  last_error?: string;
};

const statusStyles: Record<WatcherStatus, string> = {
  running: 'bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-200',
  stopped: 'bg-gray-200 text-gray-700 dark:bg-gray-800 dark:text-gray-200',
  error: 'bg-red-100 text-red-800 dark:bg-red-900/50 dark:text-red-200',
};

const formatRelativeTime = (timestamp?: string) => {
  if (!timestamp) {
    return 'Never';
  }
  const date = new Date(timestamp);
  if (Number.isNaN(date.getTime())) {
    return 'Unknown';
  }
  const diffMs = Date.now() - date.getTime();
  if (diffMs < 60_000) {
    return 'just now';
  }
  if (diffMs < 3_600_000) {
    const minutes = Math.round(diffMs / 60_000);
    return `${minutes}m ago`;
  }
  if (diffMs < 86_400_000) {
    const hours = Math.round(diffMs / 3_600_000);
    return `${hours}h ago`;
  }
  const days = Math.round(diffMs / 86_400_000);
  return `${days}d ago`;
};

const formatAbsoluteTime = (timestamp?: string) => {
  if (!timestamp) {
    return '';
  }
  const date = new Date(timestamp);
  if (Number.isNaN(date.getTime())) {
    return '';
  }
  return date.toLocaleString();
};

export default function WatcherTelemetryPanel() {
  const [watchers, setWatchers] = useState<WatcherInfo[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [lastUpdated, setLastUpdated] = useState<string | null>(null);

  const fetchWatchers = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const token = document.cookie
        .split('; ')
        .find((row) => row.startsWith('accessToken='))
        ?.split('=')[1];
      const response = await fetch('/api/admin/config/watchers', {
        headers: token ? { Authorization: `Bearer ${token}` } : {},
      });
      if (!response.ok) {
        throw new Error('Failed to fetch watcher telemetry');
      }
      const data = await response.json();
      if (Array.isArray(data)) {
        setWatchers(data as WatcherInfo[]);
      } else {
        setWatchers([]);
      }
      setLastUpdated(new Date().toISOString());
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Watcher telemetry unavailable';
      setError(message);
      setWatchers([]);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    const load = async () => {
      if (cancelled) {
        return;
      }
      await fetchWatchers();
    };
    load();
    const interval = setInterval(() => {
      void fetchWatchers();
    }, 30_000);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [fetchWatchers]);

  const rows = useMemo(() => {
    return [...watchers].sort((a, b) => {
      if (a.service === b.service) {
        return (b.last_event ?? '').localeCompare(a.last_event ?? '');
      }
      return a.service.localeCompare(b.service);
    });
  }, [watchers]);

  const renderStatusPill = (status: WatcherStatus, lastError?: string) => (
    <span
      className={`px-2 py-0.5 rounded-full text-[11px] font-medium ${statusStyles[status]}`}
      title={lastError || undefined}
    >
      {status === 'running' ? 'Running' : status === 'stopped' ? 'Stopped' : 'Error'}
    </span>
  );

  return (
    <section className="border-b border-gray-200 bg-white p-4 shadow-sm dark:border-gray-700 dark:bg-gray-900/70">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Activity className="h-4 w-4 text-blue-600" />
          <div>
            <p className="text-sm font-semibold text-gray-900 dark:text-gray-100">Watcher Telemetry</p>
            <p className="text-xs text-gray-500 dark:text-gray-400">Last reloads sourced from /api/admin/config/watchers</p>
          </div>
        </div>
        <div className="flex items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
          {lastUpdated && <span>Updated {formatRelativeTime(lastUpdated)}</span>}
          <button
            onClick={() => fetchWatchers()}
            disabled={loading}
            className="inline-flex items-center gap-1 rounded border border-gray-300 px-2.5 py-1 text-xs font-medium text-gray-700 hover:bg-gray-100 disabled:opacity-60 dark:border-gray-600 dark:text-gray-200 dark:hover:bg-gray-800"
          >
            <RefreshCw className={`h-3.5 w-3.5 ${loading ? 'animate-spin' : ''}`} />
            Refresh
          </button>
        </div>
      </div>

      {error && (
        <div className="mt-3 flex items-center gap-2 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-xs text-red-700 dark:border-red-900/40 dark:bg-red-900/20 dark:text-red-200">
          <AlertTriangle className="h-3.5 w-3.5" />
          <span>{error}</span>
        </div>
      )}

      {!error && rows.length === 0 && !loading && (
        <p className="mt-3 text-xs text-gray-500 dark:text-gray-400">No watchers registered in this process yet.</p>
      )}

      <div className="mt-3 max-h-56 overflow-y-auto rounded-md border border-gray-200 bg-white text-xs dark:border-gray-700 dark:bg-gray-900">
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-800">
          <thead className="bg-gray-50 text-[11px] uppercase tracking-wide text-gray-500 dark:bg-gray-900/70 dark:text-gray-400">
            <tr>
              <th scope="col" className="px-3 py-2 text-left font-medium">Service</th>
              <th scope="col" className="px-3 py-2 text-left font-medium">Scope</th>
              <th scope="col" className="px-3 py-2 text-left font-medium">KV Key</th>
              <th scope="col" className="px-3 py-2 text-left font-medium">Last Reload</th>
              <th scope="col" className="px-3 py-2 text-left font-medium">Status</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-200 dark:divide-gray-800">
            {rows.map((watcher) => (
              <tr key={watcher.id} className="whitespace-nowrap">
                <td className="px-3 py-2 font-medium text-gray-900 dark:text-gray-100">{watcher.service}</td>
                <td className="px-3 py-2 capitalize text-gray-600 dark:text-gray-300">{watcher.scope}</td>
                <td className="px-3 py-2 font-mono text-[11px] text-gray-500 dark:text-gray-400">{watcher.kv_key}</td>
                <td className="px-3 py-2 text-gray-700 dark:text-gray-200" title={formatAbsoluteTime(watcher.last_event)}>
                  {formatRelativeTime(watcher.last_event)}
                </td>
                <td className="px-3 py-2">{renderStatusPill(watcher.status, watcher.last_error)}</td>
              </tr>
            ))}
            {loading && (
              <tr>
                <td colSpan={5} className="px-3 py-2 text-center text-gray-500 dark:text-gray-300">
                  Loading telemetry…
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}
