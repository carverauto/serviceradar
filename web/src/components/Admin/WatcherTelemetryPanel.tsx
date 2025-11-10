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

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
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
  kv_store_id?: string;
};

type KvStoreOption = {
  id: string;
  name: string;
};

const CORE_KV_STORE: KvStoreOption = {
  id: '',
  name: 'Core KV (default)',
};

type WatcherTelemetryPanelProps = {
  kvStoreHints?: string[];
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

export default function WatcherTelemetryPanel({ kvStoreHints = [] }: WatcherTelemetryPanelProps) {
  const [watchers, setWatchers] = useState<WatcherInfo[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [lastUpdated, setLastUpdated] = useState<string | null>(null);
  const [kvStores, setKvStores] = useState<KvStoreOption[]>([CORE_KV_STORE]);
  const [kvStoreError, setKvStoreError] = useState<string | null>(null);
  const [selectedStore, setSelectedStore] = useState<string>(CORE_KV_STORE.id);
  const selectedStoreRef = useRef(selectedStore);

  useEffect(() => {
    selectedStoreRef.current = selectedStore;
  }, [selectedStore]);

  const readAccessToken = useCallback(
    () =>
      document.cookie
        .split('; ')
        .find((row) => row.startsWith('accessToken='))
        ?.split('=')[1],
    [],
  );

  const kvStoreLookup = useMemo(() => {
    const lookup = new Map<string, string>();
    kvStores.forEach((store) => {
      lookup.set(store.id, store.name);
    });
    return lookup;
  }, [kvStores]);

  const kvStoreName = useCallback(
    (id?: string | null) => {
      const normalized = id ?? '';
      return kvStoreLookup.get(normalized) || (normalized ? normalized : CORE_KV_STORE.name);
    },
    [kvStoreLookup],
  );

  useEffect(() => {
    let cancelled = false;

    const fetchStores = async () => {
      try {
        const token = readAccessToken();
        const response = await fetch('/api/config/kv-stores', {
          headers: token ? { Authorization: `Bearer ${token}` } : {},
        });
        if (!response.ok) {
          throw new Error('Failed to fetch KV stores');
        }
        const payload = await response.json();
        const parsed: KvStoreOption[] = Array.isArray(payload)
          ? payload
              .map((store: { id?: string; name?: string } | null) => {
                if (!store || typeof store.id !== 'string') {
                  return null;
                }
                const trimmedId = store.id.trim();
                if (!trimmedId) {
                  return null;
                }
                return {
                  id: trimmedId,
                  name: typeof store.name === 'string' && store.name.trim()
                    ? store.name.trim()
                    : trimmedId,
                };
              })
              .filter((store): store is KvStoreOption => Boolean(store))
          : [];
        const deduped: KvStoreOption[] = [];
        parsed.forEach((store) => {
          if (!deduped.some((candidate) => candidate.id === store.id)) {
            deduped.push(store);
          }
        });
        const nextStores: KvStoreOption[] = [CORE_KV_STORE, ...deduped];
        if (cancelled) {
          return;
        }
        setKvStores(nextStores);
        setKvStoreError(null);
        if (selectedStoreRef.current && !nextStores.some((store) => store.id === selectedStoreRef.current)) {
          setSelectedStore(CORE_KV_STORE.id);
        }
      } catch (err) {
        if (cancelled) {
          return;
        }
        setKvStores((prev) => (prev.length ? prev : [CORE_KV_STORE]));
        if (!kvStoreHints || kvStoreHints.length === 0) {
          setKvStoreError('KV stores unavailable; showing core telemetry only.');
        } else {
          setKvStoreError(null);
        }
        if (selectedStoreRef.current !== CORE_KV_STORE.id) {
          setSelectedStore(CORE_KV_STORE.id);
        }
      }
    };

    fetchStores();

    return () => {
      cancelled = true;
    };
  }, [kvStoreHints, readAccessToken]);

  useEffect(() => {
    if (!kvStoreHints || kvStoreHints.length === 0) {
      return;
    }
    setKvStores((previous) => {
      const dedup = new Map<string, KvStoreOption>();
      previous.forEach((store) => {
        dedup.set(store.id, store);
      });
      kvStoreHints.forEach((hint) => {
        const normalized = (hint ?? '').trim();
        if (!normalized || dedup.has(normalized)) {
          return;
        }
        dedup.set(normalized, { id: normalized, name: normalized });
      });
      return Array.from(dedup.values());
    });
  }, [kvStoreHints]);

  useEffect(() => {
    if (!kvStoreHints || kvStoreHints.length === 0) {
      return;
    }
    setKvStoreError((prev) => {
      if (!prev) {
        return prev;
      }
      if (prev.includes('core telemetry')) {
        return null;
      }
      return prev;
    });
  }, [kvStoreHints]);

  const fetchWatchers = useCallback(async () => {
    const storeId = selectedStore;
    try {
      setLoading(true);
      setError(null);
      const token = readAccessToken();
      const query = storeId ? `?kv_store_id=${encodeURIComponent(storeId)}` : '';
      const response = await fetch(`/api/admin/config/watchers${query}`, {
        headers: token ? { Authorization: `Bearer ${token}` } : {},
      });
      if (!response.ok) {
        throw new Error(`Failed to fetch watcher telemetry${storeId ? ` for ${storeId}` : ''}`);
      }
      const data = await response.json();
      const payload: WatcherInfo[] = Array.isArray(data)
        ? (data as WatcherInfo[]).map((watcher) => ({
            ...watcher,
            kv_store_id: storeId,
          }))
        : [];
      if (selectedStoreRef.current !== storeId) {
        return;
      }
      setWatchers(payload);
      setLastUpdated(new Date().toISOString());
    } catch (err) {
      if (selectedStoreRef.current !== storeId) {
        return;
      }
      const message = err instanceof Error ? err.message : 'Watcher telemetry unavailable';
      setError(message);
      setWatchers([]);
    } finally {
      if (selectedStoreRef.current === storeId) {
        setLoading(false);
      }
    }
  }, [readAccessToken, selectedStore]);

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
      const storeA = a.kv_store_id ?? '';
      const storeB = b.kv_store_id ?? '';
      if (storeA !== storeB) {
        return storeA.localeCompare(storeB);
      }
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
        <div className="flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
          <label className="flex items-center gap-1 text-[11px] font-medium text-gray-600 dark:text-gray-300">
            <span>KV store</span>
            <select
              className="rounded border border-gray-300 bg-white px-2 py-0.5 text-xs text-gray-700 focus:outline-none focus:ring-2 focus:ring-blue-500 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-100"
              value={selectedStore}
              onChange={(e) => setSelectedStore(e.target.value)}
            >
              {kvStores.map((store) => (
                <option key={store.id || 'core-default'} value={store.id}>
                  {store.name}
                </option>
              ))}
            </select>
          </label>
          {lastUpdated && <span>Updated {formatRelativeTime(lastUpdated)}</span>}
          <button
            onClick={() => {
              void fetchWatchers();
            }}
            disabled={loading}
            className="inline-flex items-center gap-1 rounded border border-gray-300 px-2.5 py-1 text-xs font-medium text-gray-700 hover:bg-gray-100 disabled:opacity-60 dark:border-gray-600 dark:text-gray-200 dark:hover:bg-gray-800"
          >
            <RefreshCw className={`h-3.5 w-3.5 ${loading ? 'animate-spin' : ''}`} />
            Refresh
          </button>
        </div>
      </div>

      {kvStoreError && (
        <p className="mt-2 text-xs text-yellow-700 dark:text-yellow-300">{kvStoreError}</p>
      )}

      {error && (
        <div className="mt-3 flex items-center gap-2 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-xs text-red-700 dark:border-red-900/40 dark:bg-red-900/20 dark:text-red-200">
          <AlertTriangle className="h-3.5 w-3.5" />
          <span>{error}</span>
        </div>
      )}

      {!error && rows.length === 0 && !loading && (
        <p className="mt-3 text-xs text-gray-500 dark:text-gray-400">
          No watchers registered for {kvStoreName(selectedStore)} yet.
        </p>
      )}

      <div className="mt-3 max-h-56 overflow-y-auto rounded-md border border-gray-200 bg-white text-xs dark:border-gray-700 dark:bg-gray-900">
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-800">
          <thead className="bg-gray-50 text-[11px] uppercase tracking-wide text-gray-500 dark:bg-gray-900/70 dark:text-gray-400">
            <tr>
              <th scope="col" className="px-3 py-2 text-left font-medium">KV Store</th>
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
                <td className="px-3 py-2 text-gray-600 dark:text-gray-300">{kvStoreName(watcher.kv_store_id)}</td>
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
                <td colSpan={6} className="px-3 py-2 text-center text-gray-500 dark:text-gray-300">
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
