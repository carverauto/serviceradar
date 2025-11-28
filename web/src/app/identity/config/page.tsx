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

import { useEffect, useState } from 'react';
import Link from 'next/link';
import { ArrowLeft, RefreshCw, Save, CheckCircle2, AlertCircle } from 'lucide-react';
import safeSet from '@/lib/safeSet';
import type { IdentityConfig, IdentityConfigResponse } from '@/types/identity';

const bool = (value?: boolean) => Boolean(value);

export default function IdentityConfigPage() {
  const [config, setConfig] = useState<IdentityConfig | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState(false);

  const updateConfig = (path: string, value: unknown) => {
    setConfig((prev) => {
      const next: Record<string, unknown> = { ...(prev || {}) };
      safeSet(next, path, value);
      return next as IdentityConfig;
    });
  };

  const fetchConfig = async () => {
    try {
      setLoading(true);
      setError(null);
      const response = await fetch('/api/identity/config', { cache: 'no-store' });
      if (!response.ok) {
        const detail = await response.text();
        throw new Error(detail || 'Failed to load identity configuration');
      }
      const data: IdentityConfigResponse = await response.json();
      setConfig(data.identity ?? {});
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Unknown error';
      setError(msg);
      setConfig(null);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchConfig();
  }, []);

  const handleSave = async () => {
    if (!config) {
      setError('Configuration unavailable');
      return;
    }
    try {
      setSaving(true);
      setError(null);
      setSuccess(false);
      const response = await fetch('/api/identity/config', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ identity: config }),
      });
      if (!response.ok) {
        const detail = await response.text();
        throw new Error(detail || 'Failed to save configuration');
      }
      setSuccess(true);
      setTimeout(() => setSuccess(false), 2000);
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Unknown error';
      setError(msg);
    } finally {
      setSaving(false);
    }
  };

  if (loading) {
    return (
      <div className="p-6 flex items-center gap-2 text-gray-600">
        <RefreshCw className="h-4 w-4 animate-spin" />
        <span>Loading identity configuration...</span>
      </div>
    );
  }

  return (
    <div className="p-6 space-y-6">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <Link
            href="/identity"
            className="inline-flex items-center gap-1 text-sm text-blue-600 hover:underline"
          >
            <ArrowLeft className="h-4 w-4" />
            Back to sightings
          </Link>
          <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-50">
            Identity Reconciliation Configuration
          </h1>
        </div>
        <div className="flex items-center gap-2">
          {success && (
            <span className="inline-flex items-center gap-1 text-green-700 dark:text-green-300 text-sm">
              <CheckCircle2 className="h-4 w-4" /> Saved
            </span>
          )}
          {error && (
            <span className="inline-flex items-center gap-1 text-red-700 dark:text-red-300 text-sm">
              <AlertCircle className="h-4 w-4" /> {error}
            </span>
          )}
          <button
            className="inline-flex items-center gap-2 rounded-md bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
            onClick={handleSave}
            disabled={saving || !config}
          >
            <Save className="h-4 w-4" />
            Save
          </button>
        </div>
      </div>

      {!config && (
        <div className="text-sm text-gray-600">Configuration could not be loaded.</div>
      )}

      {config && (
        <div className="grid gap-6 lg:grid-cols-2">
          <section className="space-y-4 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4 shadow-sm">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-lg font-medium">Feature Flags</p>
                <p className="text-sm text-gray-500">Toggle reconciliation and shadowing.</p>
              </div>
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={bool(config.enabled)}
                  onChange={(e) => updateConfig('enabled', e.target.checked)}
                />
                Enabled
              </label>
            </div>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={bool(config.sightings_only_mode)}
                onChange={(e) => updateConfig('sightings_only_mode', e.target.checked)}
              />
              Sightings-only mode
            </label>
          </section>

          <section className="space-y-4 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4 shadow-sm">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-lg font-medium">Promotion</p>
                <p className="text-sm text-gray-500">Automated promotion thresholds.</p>
              </div>
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={bool(config.promotion?.enabled)}
                  onChange={(e) => updateConfig('promotion.enabled', e.target.checked)}
                />
                Enabled
              </label>
            </div>
            <div className="grid grid-cols-2 gap-4">
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={bool(config.promotion?.shadow_mode)}
                  onChange={(e) => updateConfig('promotion.shadow_mode', e.target.checked)}
                />
                Shadow mode
              </label>
              <div>
                <p className="text-sm font-medium">Min persistence</p>
                <input
                  type="text"
                  value={config.promotion?.min_persistence ?? ''}
                  onChange={(e) => updateConfig('promotion.min_persistence', e.target.value)}
                  className="w-full rounded-md border border-gray-300 dark:border-gray-600 p-2 text-sm"
                  placeholder="24h"
                />
              </div>
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={bool(config.promotion?.require_hostname)}
                  onChange={(e) => updateConfig('promotion.require_hostname', e.target.checked)}
                />
                Require hostname
              </label>
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={bool(config.promotion?.require_fingerprint)}
                  onChange={(e) => updateConfig('promotion.require_fingerprint', e.target.checked)}
                />
                Require fingerprint
              </label>
            </div>
          </section>

          <section className="space-y-4 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4 shadow-sm">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-lg font-medium">Fingerprinting</p>
                <p className="text-sm text-gray-500">Weak signal gathering controls.</p>
              </div>
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={bool(config.fingerprinting?.enabled)}
                  onChange={(e) => updateConfig('fingerprinting.enabled', e.target.checked)}
                />
                Enabled
              </label>
            </div>
            <div className="grid grid-cols-2 gap-4">
              <div>
                <p className="text-sm font-medium">Port budget</p>
                <input
                  type="number"
                  value={config.fingerprinting?.port_budget ?? ''}
                  onChange={(e) =>
                    updateConfig(
                      'fingerprinting.port_budget',
                      e.target.value === '' ? undefined : Number(e.target.value),
                    )
                  }
                  className="w-full rounded-md border border-gray-300 dark:border-gray-600 p-2 text-sm"
                  placeholder="32"
                />
              </div>
              <div>
                <p className="text-sm font-medium">Timeout</p>
                <input
                  type="text"
                  value={config.fingerprinting?.timeout ?? ''}
                  onChange={(e) => updateConfig('fingerprinting.timeout', e.target.value)}
                  className="w-full rounded-md border border-gray-300 dark:border-gray-600 p-2 text-sm"
                  placeholder="2s"
                />
              </div>
            </div>
          </section>

          <section className="space-y-4 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4 shadow-sm">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-lg font-medium">Reaper</p>
                <p className="text-sm text-gray-500">TTL enforcement per subnet class.</p>
              </div>
              <div className="flex items-center gap-2">
                <p className="text-sm font-medium">Interval</p>
                <input
                  type="text"
                  value={config.reaper?.interval ?? ''}
                  onChange={(e) => updateConfig('reaper.interval', e.target.value)}
                  className="w-32 rounded-md border border-gray-300 dark:border-gray-600 p-2 text-sm"
                  placeholder="1h"
                />
              </div>
            </div>
            <div className="grid grid-cols-2 gap-4">
              {['default', 'dynamic', 'guest', 'static'].map((profile) => (
                <div key={profile} className="space-y-2">
                  <p className="text-sm font-medium capitalize">{profile} profile TTL</p>
                  <input
                    type="text"
                    value={config.reaper?.profiles?.[profile]?.ttl ?? ''}
                    onChange={(e) =>
                      updateConfig(`reaper.profiles.${profile}.ttl`, e.target.value)
                    }
                    className="w-full rounded-md border border-gray-300 dark:border-gray-600 p-2 text-sm"
                    placeholder="24h"
                  />
                  {profile === 'static' && (
                    <label className="flex items-center gap-2 text-xs">
                      <input
                        type="checkbox"
                        checked={bool(config.reaper?.profiles?.[profile]?.allow_ip_as_id)}
                        onChange={(e) =>
                          updateConfig(
                            `reaper.profiles.${profile}.allow_ip_as_id`,
                            e.target.checked,
                          )
                        }
                      />
                      Allow IP as ID
                    </label>
                  )}
                </div>
              ))}
            </div>
          </section>

          <section className="space-y-4 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4 shadow-sm">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-lg font-medium">Drift Protection</p>
                <p className="text-sm text-gray-500">Baseline and tolerance guardrails.</p>
              </div>
            </div>
            <div className="grid grid-cols-2 gap-4">
              <div>
                <p className="text-sm font-medium">Baseline devices</p>
                <input
                  type="number"
                  value={config.drift?.baseline_devices ?? ''}
                  onChange={(e) =>
                    updateConfig(
                      'drift.baseline_devices',
                      e.target.value === '' ? undefined : Number(e.target.value),
                    )
                  }
                  className="w-full rounded-md border border-gray-300 dark:border-gray-600 p-2 text-sm"
                  placeholder="50000"
                />
              </div>
              <div>
                <p className="text-sm font-medium">Tolerance %</p>
                <input
                  type="number"
                  value={config.drift?.tolerance_percent ?? ''}
                  onChange={(e) =>
                    updateConfig(
                      'drift.tolerance_percent',
                      e.target.value === '' ? undefined : Number(e.target.value),
                    )
                  }
                  className="w-full rounded-md border border-gray-300 dark:border-gray-600 p-2 text-sm"
                  placeholder="3"
                />
              </div>
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={bool(config.drift?.pause_on_drift)}
                  onChange={(e) => updateConfig('drift.pause_on_drift', e.target.checked)}
                />
                Pause on drift
              </label>
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={bool(config.drift?.alert_on_drift)}
                  onChange={(e) => updateConfig('drift.alert_on_drift', e.target.checked)}
                />
                Alert on drift
              </label>
            </div>
          </section>
        </div>
      )}
    </div>
  );
}
