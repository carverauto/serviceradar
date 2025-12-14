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

import React, { useMemo, useState } from 'react';
import safeSet from '../../../lib/safeSet';

const REDACTED_PLACEHOLDER = '__SR_REDACTED__';

type SnmpTarget = {
  name?: string;
  host?: string;
  port?: number;
  community?: string;
  version?: 'v1' | 'v2c' | 'v3';
  interval?: string;
  timeout?: string;
  retries?: number;
  oids?: unknown[];
};

type SnmpCheckerConfig = {
  node_address?: string;
  listen_addr?: string;
  timeout?: string;
  partition?: string;
  targets?: SnmpTarget[];
} & Record<string, unknown>;

interface Props {
  config: SnmpCheckerConfig;
  onChange: (config: SnmpCheckerConfig) => void;
}

const stringValue = (value?: string | number | null) =>
  value === undefined || value === null ? '' : String(value);

const normalizeTargets = (value: unknown): SnmpTarget[] => (Array.isArray(value) ? (value as SnmpTarget[]) : []);

const defaultTarget = (): SnmpTarget => ({
  name: 'router',
  host: '',
  port: 161,
  version: 'v2c',
  community: '',
});

export default function SnmpCheckerConfigForm({ config, onChange }: Props) {
  const targets = useMemo(() => normalizeTargets(config.targets), [config.targets]);
  const [expanded, setExpanded] = useState<Record<number, boolean>>({});
  const [pendingSecrets, setPendingSecrets] = useState<Record<string, string>>({});

  const setConfigValue = (path: string, value: unknown) => {
    const next = { ...config };
    safeSet(next as Record<string, unknown>, path, value);
    onChange(next);
  };

  const setTarget = (index: number, nextTarget: SnmpTarget) => {
    const nextTargets = [...targets];
    nextTargets[index] = { ...nextTarget };
    setConfigValue('targets', nextTargets);
  };

  const addTarget = () => {
    const nextTargets = [...targets, defaultTarget()];
    setConfigValue('targets', nextTargets);
    setExpanded((prev) => ({ ...prev, [nextTargets.length - 1]: true }));
  };

  const removeTarget = (index: number) => {
    const nextTargets = [...targets];
    nextTargets.splice(index, 1);
    setConfigValue('targets', nextTargets);
  };

  const secretDraftKey = (index: number) => `${index}:community`;
  const isRedacted = (value: unknown) => typeof value === 'string' && value.trim() === REDACTED_PLACEHOLDER;

  const commitCommunityIfProvided = (index: number) => {
    const key = secretDraftKey(index);
    const draft = (pendingSecrets[key] ?? '').trim();
    if (!draft) return;
    const t = targets[index] ?? {};
    setTarget(index, { ...t, community: draft });
    setPendingSecrets((prev) => {
      const next = { ...prev };
      delete next[key];
      return next;
    });
  };

  return (
    <div className="space-y-6">
      <section className="bg-white dark:bg-gray-800 p-6 rounded-lg border border-gray-200 dark:border-gray-700 space-y-4">
        <h3 className="text-lg font-semibold">SNMP Checker</h3>
        <p className="text-sm text-gray-600 dark:text-gray-400">
          Configure targets and credentials without editing raw JSON. Use JSON view for OIDs and advanced options.
        </p>

        <div className="grid grid-cols-3 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Node Address</label>
            <input
              type="text"
              value={config.node_address ?? ''}
              onChange={(e) => setConfigValue('node_address', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="agent:50051"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Listen Address</label>
            <input
              type="text"
              value={config.listen_addr ?? ''}
              onChange={(e) => setConfigValue('listen_addr', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder=":50054"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Partition</label>
            <input
              type="text"
              value={config.partition ?? ''}
              onChange={(e) => setConfigValue('partition', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="default"
            />
          </div>
        </div>

        <div className="grid grid-cols-3 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Default Timeout</label>
            <input
              type="text"
              value={config.timeout ?? ''}
              onChange={(e) => setConfigValue('timeout', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="5m"
            />
          </div>
          <div />
          <div />
        </div>
      </section>

      <section className="bg-white dark:bg-gray-800 p-6 rounded-lg border border-gray-200 dark:border-gray-700 space-y-4">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h3 className="text-lg font-semibold">Targets</h3>
            <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">
              Community values are redacted on read; leave blank to keep existing values unchanged.
            </p>
          </div>
          <button
            type="button"
            onClick={addTarget}
            className="px-3 py-2 text-sm font-medium text-blue-600 hover:text-blue-700 hover:bg-blue-50 dark:hover:bg-blue-900 rounded-md"
          >
            + Add Target
          </button>
        </div>

        {targets.length === 0 && (
          <div className="text-sm text-gray-500 dark:text-gray-400 border border-dashed border-gray-300 dark:border-gray-600 rounded-md p-4">
            No targets configured yet. Add a target to begin polling.
          </div>
        )}

        <div className="space-y-4">
          {targets.map((target, index) => {
            const isOpen = expanded[index] ?? (targets.length === 1);
            const name = (target?.name ?? '').trim() || `target-${index + 1}`;
            const hasOids = Array.isArray(target?.oids) && target.oids.length > 0;
            const redacted = isRedacted(target?.community);
            const draftKey = secretDraftKey(index);

            return (
              <div key={`${name}:${index}`} className="border border-gray-200 dark:border-gray-700 rounded-lg p-4">
                <div className="flex items-start justify-between gap-4">
                  <div className="min-w-0">
                    <p className="text-xs uppercase text-gray-500 dark:text-gray-400">Target</p>
                    <p className="text-sm font-medium break-all">{name}</p>
                    <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
                      {target?.host || '—'} • {target?.version || 'v2c'} • {hasOids ? 'OIDs configured' : 'No OIDs'}
                    </p>
                  </div>
                  <div className="flex items-center gap-2">
                    <button
                      type="button"
                      onClick={() => setExpanded((prev) => ({ ...prev, [index]: !isOpen }))}
                      className="px-3 py-2 text-sm rounded-md border border-gray-200 dark:border-gray-700 hover:bg-gray-50 dark:hover:bg-gray-900"
                    >
                      {isOpen ? 'Collapse' : 'Edit'}
                    </button>
                    <button
                      type="button"
                      onClick={() => removeTarget(index)}
                      className="px-3 py-2 text-sm rounded-md text-red-600 hover:text-red-700 hover:bg-red-50 dark:hover:bg-red-900/20"
                    >
                      Remove
                    </button>
                  </div>
                </div>

                {isOpen && (
                  <div className="mt-4 space-y-4">
                    <div className="grid grid-cols-3 gap-4">
                      <div>
                        <label className="block text-sm font-medium mb-2">Name</label>
                        <input
                          type="text"
                          value={target?.name ?? ''}
                          onChange={(e) => setTarget(index, { ...target, name: e.target.value })}
                          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                          placeholder="router"
                        />
                      </div>
                      <div>
                        <label className="block text-sm font-medium mb-2">Host</label>
                        <input
                          type="text"
                          value={target?.host ?? ''}
                          onChange={(e) => setTarget(index, { ...target, host: e.target.value })}
                          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                          placeholder="192.168.2.1"
                        />
                      </div>
                      <div>
                        <label className="block text-sm font-medium mb-2">Version</label>
                        <select
                          value={target?.version ?? 'v2c'}
                          onChange={(e) => setTarget(index, { ...target, version: e.target.value as SnmpTarget['version'] })}
                          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-900"
                        >
                          <option value="v1">v1</option>
                          <option value="v2c">v2c</option>
                          <option value="v3">v3</option>
                        </select>
                      </div>
                    </div>

                    <div className="grid grid-cols-3 gap-4">
                      <div>
                        <label className="block text-sm font-medium mb-2">Community</label>
                        <input
                          type="password"
                          value={pendingSecrets[draftKey] ?? ''}
                          onChange={(e) => setPendingSecrets((prev) => ({ ...prev, [draftKey]: e.target.value }))}
                          onBlur={() => commitCommunityIfProvided(index)}
                          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                          placeholder={redacted ? 'unchanged' : 'public'}
                          autoComplete="off"
                        />
                        {redacted && (
                          <p className="mt-1 text-[11px] text-gray-500 dark:text-gray-400">
                            Existing value is redacted; leave blank to keep it unchanged.
                          </p>
                        )}
                      </div>
                      <div>
                        <label className="block text-sm font-medium mb-2">Port</label>
                        <input
                          type="number"
                          value={stringValue(target?.port)}
                          onChange={(e) =>
                            setTarget(index, { ...target, port: e.target.value === '' ? undefined : Number(e.target.value) })
                          }
                          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                          placeholder="161"
                        />
                      </div>
                      <div>
                        <label className="block text-sm font-medium mb-2">Retries</label>
                        <input
                          type="number"
                          value={stringValue(target?.retries)}
                          onChange={(e) =>
                            setTarget(index, {
                              ...target,
                              retries: e.target.value === '' ? undefined : Number(e.target.value),
                            })
                          }
                          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                          placeholder="3"
                        />
                      </div>
                    </div>

                    <div className="grid grid-cols-2 gap-4">
                      <div>
                        <label className="block text-sm font-medium mb-2">Interval</label>
                        <input
                          type="text"
                          value={target?.interval ?? ''}
                          onChange={(e) => setTarget(index, { ...target, interval: e.target.value })}
                          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                          placeholder="60s"
                        />
                      </div>
                      <div>
                        <label className="block text-sm font-medium mb-2">Timeout</label>
                        <input
                          type="text"
                          value={target?.timeout ?? ''}
                          onChange={(e) => setTarget(index, { ...target, timeout: e.target.value })}
                          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                          placeholder="5s"
                        />
                      </div>
                    </div>

                    {!hasOids && (
                      <p className="text-xs text-amber-600 dark:text-amber-400">
                        This target has no OIDs configured. Use JSON view to add OIDs (required).
                      </p>
                    )}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      </section>
    </div>
  );
}

