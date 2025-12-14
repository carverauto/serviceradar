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

type MapperJobCredentials = {
  version?: 'v1' | 'v2c' | 'v3';
  community?: string;
  username?: string;
  auth_protocol?: string;
  auth_password?: string;
  privacy_protocol?: string;
  privacy_password?: string;
};

type MapperCredentialRule = {
  targets?: string[];
  version?: 'v1' | 'v2c' | 'v3';
  community?: string;
  username?: string;
  auth_protocol?: string;
  auth_password?: string;
  privacy_protocol?: string;
  privacy_password?: string;
};

type MapperUniFiAPI = {
  name?: string;
  base_url?: string;
  api_key?: string;
  insecure_skip_verify?: boolean;
};

type MapperStreamConfig = {
  device_stream?: string;
  interface_stream?: string;
  topology_stream?: string;
  agent_id?: string;
  publish_batch_size?: number;
  publish_retries?: number;
  publish_retry_interval?: string;
};

type MapperScheduledJob = {
  name?: string;
  interval?: string;
  enabled?: boolean;
  seeds?: string[];
  type?: string;
  credentials?: MapperJobCredentials;
  concurrency?: number;
  timeout?: string;
  retries?: number;
  options?: Record<string, string>;
};

type MapperConfig = {
  scheduled_jobs?: MapperScheduledJob[];
  default_credentials?: MapperJobCredentials;
  credentials?: MapperCredentialRule[];
  unifi_apis?: MapperUniFiAPI[];
  stream_config?: MapperStreamConfig;
  seeds?: string[];
  workers?: number;
  timeout?: string;
  retries?: number;
  max_active_jobs?: number;
  result_retention?: string;
} & Record<string, unknown>;

interface Props {
  config: MapperConfig;
  onChange: (config: MapperConfig) => void;
}

const stringValue = (value?: string | number | null) =>
  value === undefined || value === null ? '' : String(value);

const normalizeSeeds = (value: unknown): string[] => {
  if (!Array.isArray(value)) return [];
  return value
    .map((v) => (typeof v === 'string' ? v.trim() : ''))
    .filter((v) => v.length > 0);
};

const normalizeCredentialRules = (value: unknown): MapperCredentialRule[] =>
  Array.isArray(value) ? (value as MapperCredentialRule[]) : [];

const normalizeUniFiApis = (value: unknown): MapperUniFiAPI[] =>
  Array.isArray(value) ? (value as MapperUniFiAPI[]) : [];

const defaultScheduledJob = (): MapperScheduledJob => ({
  name: 'primary-lan-discovery',
  enabled: true,
  interval: '1h',
  seeds: [],
  type: 'full',
  credentials: { version: 'v2c', community: '' },
  concurrency: 10,
  timeout: '45s',
  retries: 2,
  options: { trigger_discovery: 'false' },
});

export default function MapperConfigForm({ config, onChange }: Props) {
  const scheduledJobs = useMemo(
    () => (Array.isArray(config.scheduled_jobs) ? config.scheduled_jobs : []),
    [config.scheduled_jobs],
  );
  const [expanded, setExpanded] = useState<Record<number, boolean>>({});
  const [pendingSecrets, setPendingSecrets] = useState<Record<string, string>>({});

  const credentialRules = useMemo(() => normalizeCredentialRules(config.credentials), [config.credentials]);
  const unifiApis = useMemo(() => normalizeUniFiApis(config.unifi_apis), [config.unifi_apis]);

  const setConfigValue = (path: string, value: unknown) => {
    const next = { ...config };
    safeSet(next as Record<string, unknown>, path, value);
    onChange(next);
  };

  const setJob = (index: number, nextJob: MapperScheduledJob) => {
    const nextJobs = [...scheduledJobs];
    nextJobs[index] = { ...nextJob };
    setConfigValue('scheduled_jobs', nextJobs);
  };

  const addJob = () => {
    const nextJobs = [...scheduledJobs, defaultScheduledJob()];
    setConfigValue('scheduled_jobs', nextJobs);
    setExpanded((prev) => ({ ...prev, [nextJobs.length - 1]: true }));
  };

  const removeJob = (index: number) => {
    const nextJobs = [...scheduledJobs];
    nextJobs.splice(index, 1);
    setConfigValue('scheduled_jobs', nextJobs);
  };

  const setJobSeeds = (index: number, seeds: string[]) => {
    const job = scheduledJobs[index] ?? {};
    setJob(index, { ...job, seeds });
  };

  const setJobCredential = (index: number, path: keyof MapperJobCredentials, value: unknown) => {
    const job = scheduledJobs[index] ?? {};
    const creds = { ...(job.credentials ?? {}) };
    safeSet(creds as Record<string, unknown>, path, value);
    setJob(index, { ...job, credentials: creds });
  };

  const getSecretDraftKey = (scope: string, index: number, field: string) => `${scope}:${index}:${field}`;

  const showRedacted = (value: unknown): boolean =>
    typeof value === 'string' && value.trim() === REDACTED_PLACEHOLDER;

  const clearSecretDraft = (key: string) => {
    setPendingSecrets((prev) => {
      const next = { ...prev };
      delete next[key];
      return next;
    });
  };

  const handleJobSecretBlur = (index: number, field: keyof MapperJobCredentials) => {
    const key = getSecretDraftKey('job', index, field);
    const draft = (pendingSecrets[key] ?? '').trim();
    if (!draft) {
      return;
    }
    setJobCredential(index, field, draft);
    clearSecretDraft(key);
  };

  const setDefaultCredential = (path: keyof MapperJobCredentials, value: unknown) => {
    const next = { ...(config.default_credentials ?? {}) };
    safeSet(next as Record<string, unknown>, path, value);
    setConfigValue('default_credentials', next);
  };

  const handleDefaultSecretBlur = (field: keyof MapperJobCredentials) => {
    const key = getSecretDraftKey('default', 0, field);
    const draft = (pendingSecrets[key] ?? '').trim();
    if (!draft) return;
    setDefaultCredential(field, draft);
    clearSecretDraft(key);
  };

  const setRule = (index: number, nextRule: MapperCredentialRule) => {
    const nextRules = [...credentialRules];
    nextRules[index] = { ...nextRule };
    setConfigValue('credentials', nextRules);
  };

  const addRule = () => {
    const nextRules = [
      ...credentialRules,
      { targets: [], version: 'v2c', community: '' } satisfies MapperCredentialRule,
    ];
    setConfigValue('credentials', nextRules);
  };

  const removeRule = (index: number) => {
    const nextRules = [...credentialRules];
    nextRules.splice(index, 1);
    setConfigValue('credentials', nextRules);
  };

  const setRuleTargets = (index: number, targets: string[]) => {
    const rule = credentialRules[index] ?? {};
    setRule(index, { ...rule, targets });
  };

  const setRuleField = (index: number, path: keyof MapperCredentialRule, value: unknown) => {
    const rule = credentialRules[index] ?? {};
    const next = { ...rule };
    safeSet(next as Record<string, unknown>, path, value);
    setRule(index, next);
  };

  const handleRuleSecretBlur = (index: number, field: keyof MapperCredentialRule) => {
    const key = getSecretDraftKey('rule', index, field);
    const draft = (pendingSecrets[key] ?? '').trim();
    if (!draft) return;
    setRuleField(index, field, draft);
    clearSecretDraft(key);
  };

  const setUniFiApi = (index: number, nextApi: MapperUniFiAPI) => {
    const next = [...unifiApis];
    next[index] = { ...nextApi };
    setConfigValue('unifi_apis', next);
  };

  const addUniFiApi = () => {
    const next = [...unifiApis, { name: '', base_url: '', api_key: '', insecure_skip_verify: false }];
    setConfigValue('unifi_apis', next);
  };

  const removeUniFiApi = (index: number) => {
    const next = [...unifiApis];
    next.splice(index, 1);
    setConfigValue('unifi_apis', next);
  };

  const handleUniFiApiKeyBlur = (index: number) => {
    const key = getSecretDraftKey('unifi', index, 'api_key');
    const draft = (pendingSecrets[key] ?? '').trim();
    if (!draft) return;
    const api = unifiApis[index] ?? {};
    setUniFiApi(index, { ...api, api_key: draft });
    clearSecretDraft(key);
  };

  const setStreamConfigValue = (path: keyof MapperStreamConfig, value: unknown) => {
    const next = { ...(config.stream_config ?? {}) };
    safeSet(next as Record<string, unknown>, path, value);
    setConfigValue('stream_config', next);
  };

  return (
    <div className="space-y-6">
      <section className="bg-white dark:bg-gray-800 p-6 rounded-lg border border-gray-200 dark:border-gray-700 space-y-5">
        <h3 className="text-lg font-semibold">Mapper Runtime</h3>
        <p className="text-sm text-gray-600 dark:text-gray-400">
          Core mapper tuning settings. Use JSON view for advanced OID configuration.
        </p>

        <div className="grid grid-cols-3 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Workers</label>
            <input
              type="number"
              value={stringValue(config.workers as number | undefined)}
              onChange={(e) => setConfigValue('workers', e.target.value === '' ? undefined : Number(e.target.value))}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="20"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Timeout</label>
            <input
              type="text"
              value={stringValue(config.timeout as string | undefined)}
              onChange={(e) => setConfigValue('timeout', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="30s"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Retries</label>
            <input
              type="number"
              value={stringValue(config.retries as number | undefined)}
              onChange={(e) => setConfigValue('retries', e.target.value === '' ? undefined : Number(e.target.value))}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="3"
            />
          </div>
        </div>

        <div className="grid grid-cols-3 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Max Active Jobs</label>
            <input
              type="number"
              value={stringValue(config.max_active_jobs as number | undefined)}
              onChange={(e) => setConfigValue('max_active_jobs', e.target.value === '' ? undefined : Number(e.target.value))}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="100"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Result Retention</label>
            <input
              type="text"
              value={stringValue(config.result_retention as string | undefined)}
              onChange={(e) => setConfigValue('result_retention', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="24h"
            />
          </div>
          <div />
        </div>
      </section>

      <section className="bg-white dark:bg-gray-800 p-6 rounded-lg border border-gray-200 dark:border-gray-700 space-y-5">
        <h3 className="text-lg font-semibold">Default SNMP Credentials</h3>
        <p className="text-sm text-gray-600 dark:text-gray-400">
          Used when a scheduled job does not specify credentials explicitly.
        </p>

        {(() => {
          const creds = config.default_credentials ?? {};
          const communityRedacted = showRedacted(creds.community);
          const communityDraftKey = getSecretDraftKey('default', 0, 'community');
          return (
            <div className="grid grid-cols-3 gap-4">
              <div>
                <label className="block text-sm font-medium mb-2">Version</label>
                <select
                  value={creds.version ?? 'v2c'}
                  onChange={(e) => setDefaultCredential('version', e.target.value)}
                  className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-900"
                >
                  <option value="v1">v1</option>
                  <option value="v2c">v2c</option>
                  <option value="v3">v3</option>
                </select>
              </div>
              <div>
                <label className="block text-sm font-medium mb-2">Community</label>
                <input
                  type="password"
                  value={pendingSecrets[communityDraftKey] ?? ''}
                  onChange={(e) => setPendingSecrets((prev) => ({ ...prev, [communityDraftKey]: e.target.value }))}
                  onBlur={() => handleDefaultSecretBlur('community')}
                  className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                  placeholder={communityRedacted ? 'unchanged' : 'public'}
                  autoComplete="off"
                />
                {communityRedacted && (
                  <p className="mt-1 text-[11px] text-gray-500 dark:text-gray-400">
                    Existing value is redacted; leave blank to keep it unchanged.
                  </p>
                )}
              </div>
              <div className="text-xs text-gray-500 dark:text-gray-400 leading-5 pt-7">
                SNMPv3 fields are supported in JSON view; this form focuses on common v2c usage.
              </div>
            </div>
          );
        })()}
      </section>

      <section className="bg-white dark:bg-gray-800 p-6 rounded-lg border border-gray-200 dark:border-gray-700 space-y-4">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h3 className="text-lg font-semibold">Target-Specific Credentials</h3>
            <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">
              Apply credentials to matching IPs/CIDRs (for example <code>192.168.2.0/24</code>).
            </p>
          </div>
          <button
            type="button"
            onClick={addRule}
            className="px-3 py-2 text-sm font-medium text-blue-600 hover:text-blue-700 hover:bg-blue-50 dark:hover:bg-blue-900 rounded-md"
          >
            + Add Rule
          </button>
        </div>

        {credentialRules.length === 0 && (
          <div className="text-sm text-gray-500 dark:text-gray-400 border border-dashed border-gray-300 dark:border-gray-600 rounded-md p-4">
            No target-specific credentials configured.
          </div>
        )}

        <div className="space-y-4">
          {credentialRules.map((rule, index) => {
            const targets = normalizeSeeds(rule.targets);
            const communityRedacted = showRedacted(rule.community);
            const communityDraftKey = getSecretDraftKey('rule', index, 'community');
            return (
              <div key={`cred-${index}`} className="border border-gray-200 dark:border-gray-700 rounded-lg p-4 space-y-4">
                <div className="flex items-start justify-between gap-4">
                  <div className="min-w-0">
                    <p className="text-xs uppercase text-gray-500 dark:text-gray-400">Credential Rule</p>
                    <p className="text-sm text-gray-700 dark:text-gray-200 break-all">
                      {targets.length ? targets.join(', ') : 'No targets'}
                    </p>
                  </div>
                  <button
                    type="button"
                    onClick={() => removeRule(index)}
                    className="px-3 py-2 text-sm rounded-md text-red-600 hover:text-red-700 hover:bg-red-50 dark:hover:bg-red-900/20"
                  >
                    Remove
                  </button>
                </div>

                <div className="grid grid-cols-2 gap-3">
                  <div>
                    <label className="block text-xs font-medium mb-1">Targets (one per line)</label>
                    <textarea
                      value={targets.join('\n')}
                      onChange={(e) => setRuleTargets(index, normalizeSeeds(e.target.value.split('\n')))}
                      className="w-full h-24 font-mono text-sm p-2 border border-gray-300 dark:border-gray-600 rounded-md bg-gray-50 dark:bg-gray-900"
                      placeholder="192.168.2.0/24"
                      spellCheck={false}
                    />
                  </div>
                  <div className="grid grid-cols-2 gap-3">
                    <div>
                      <label className="block text-xs font-medium mb-1">Version</label>
                      <select
                        value={rule.version ?? 'v2c'}
                        onChange={(e) => setRuleField(index, 'version', e.target.value)}
                        className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-900"
                      >
                        <option value="v1">v1</option>
                        <option value="v2c">v2c</option>
                        <option value="v3">v3</option>
                      </select>
                    </div>
                    <div>
                      <label className="block text-xs font-medium mb-1">Community</label>
                      <input
                        type="password"
                        value={pendingSecrets[communityDraftKey] ?? ''}
                        onChange={(e) => setPendingSecrets((prev) => ({ ...prev, [communityDraftKey]: e.target.value }))}
                        onBlur={() => handleRuleSecretBlur(index, 'community')}
                        className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                        placeholder={communityRedacted ? 'unchanged' : 'public'}
                        autoComplete="off"
                      />
                      {communityRedacted && (
                        <p className="mt-1 text-[11px] text-gray-500 dark:text-gray-400">
                          Existing value is redacted; leave blank to keep it unchanged.
                        </p>
                      )}
                    </div>
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      </section>

      <section className="bg-white dark:bg-gray-800 p-6 rounded-lg border border-gray-200 dark:border-gray-700 space-y-4">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h3 className="text-lg font-semibold">UniFi APIs</h3>
            <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">
              Optional: controller integrations. API keys are redacted on read.
            </p>
          </div>
          <button
            type="button"
            onClick={addUniFiApi}
            className="px-3 py-2 text-sm font-medium text-blue-600 hover:text-blue-700 hover:bg-blue-50 dark:hover:bg-blue-900 rounded-md"
          >
            + Add UniFi API
          </button>
        </div>

        {unifiApis.length === 0 && (
          <div className="text-sm text-gray-500 dark:text-gray-400 border border-dashed border-gray-300 dark:border-gray-600 rounded-md p-4">
            No UniFi APIs configured.
          </div>
        )}

        <div className="space-y-4">
          {unifiApis.map((api, index) => {
            const apiKeyRedacted = showRedacted(api.api_key);
            const apiKeyDraftKey = getSecretDraftKey('unifi', index, 'api_key');
            const displayName = (api?.name ?? '').trim() || `api-${index + 1}`;
            return (
              <div key={`${displayName}:${index}`} className="border border-gray-200 dark:border-gray-700 rounded-lg p-4 space-y-4">
                <div className="flex items-start justify-between gap-4">
                  <div className="min-w-0">
                    <p className="text-xs uppercase text-gray-500 dark:text-gray-400">Controller</p>
                    <p className="text-sm font-medium break-all">{displayName}</p>
                    <p className="text-xs text-gray-500 dark:text-gray-400 mt-1 break-all">
                      {api?.base_url || '—'}
                    </p>
                  </div>
                  <button
                    type="button"
                    onClick={() => removeUniFiApi(index)}
                    className="px-3 py-2 text-sm rounded-md text-red-600 hover:text-red-700 hover:bg-red-50 dark:hover:bg-red-900/20"
                  >
                    Remove
                  </button>
                </div>

                <div className="grid grid-cols-2 gap-4">
                  <div>
                    <label className="block text-sm font-medium mb-2">Name</label>
                    <input
                      type="text"
                      value={api?.name ?? ''}
                      onChange={(e) => setUniFiApi(index, { ...api, name: e.target.value })}
                      className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                      placeholder="Main Controller"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium mb-2">Base URL</label>
                    <input
                      type="text"
                      value={api?.base_url ?? ''}
                      onChange={(e) => setUniFiApi(index, { ...api, base_url: e.target.value })}
                      className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                      placeholder="https://192.168.1.1/proxy/network/integration/v1"
                    />
                  </div>
                </div>

                <div className="grid grid-cols-3 gap-4">
                  <div>
                    <label className="block text-sm font-medium mb-2">API Key</label>
                    <input
                      type="password"
                      value={pendingSecrets[apiKeyDraftKey] ?? ''}
                      onChange={(e) => setPendingSecrets((prev) => ({ ...prev, [apiKeyDraftKey]: e.target.value }))}
                      onBlur={() => handleUniFiApiKeyBlur(index)}
                      className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                      placeholder={apiKeyRedacted ? 'unchanged' : ''}
                      autoComplete="off"
                    />
                    {apiKeyRedacted && (
                      <p className="mt-1 text-[11px] text-gray-500 dark:text-gray-400">
                        Existing value is redacted; leave blank to keep it unchanged.
                      </p>
                    )}
                  </div>
                  <div className="flex items-center gap-2 mt-7">
                    <input
                      id={`unifi-${index}-insecure`}
                      type="checkbox"
                      checked={api?.insecure_skip_verify ?? false}
                      onChange={(e) => setUniFiApi(index, { ...api, insecure_skip_verify: e.target.checked })}
                      className="h-4 w-4"
                    />
                    <label htmlFor={`unifi-${index}-insecure`} className="text-sm">
                      Insecure TLS (skip verify)
                    </label>
                  </div>
                  <div />
                </div>
              </div>
            );
          })}
        </div>
      </section>

      <section className="bg-white dark:bg-gray-800 p-6 rounded-lg border border-gray-200 dark:border-gray-700 space-y-5">
        <h3 className="text-lg font-semibold">Stream Publishing</h3>
        <p className="text-sm text-gray-600 dark:text-gray-400">
          Controls how discovery results are published to streams.
        </p>
        <div className="grid grid-cols-3 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Device Stream</label>
            <input
              type="text"
              value={stringValue(config.stream_config?.device_stream)}
              onChange={(e) => setStreamConfigValue('device_stream', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="sweep_results"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Interface Stream</label>
            <input
              type="text"
              value={stringValue(config.stream_config?.interface_stream)}
              onChange={(e) => setStreamConfigValue('interface_stream', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="discovered_interfaces"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Topology Stream</label>
            <input
              type="text"
              value={stringValue(config.stream_config?.topology_stream)}
              onChange={(e) => setStreamConfigValue('topology_stream', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="topology_discovery_events"
            />
          </div>
        </div>

        <div className="grid grid-cols-3 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Agent ID</label>
            <input
              type="text"
              value={stringValue(config.stream_config?.agent_id)}
              onChange={(e) => setStreamConfigValue('agent_id', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="snmp-discovery-agent"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Publish Batch Size</label>
            <input
              type="number"
              value={stringValue(config.stream_config?.publish_batch_size)}
              onChange={(e) =>
                setStreamConfigValue('publish_batch_size', e.target.value === '' ? undefined : Number(e.target.value))
              }
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="100"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Publish Retries</label>
            <input
              type="number"
              value={stringValue(config.stream_config?.publish_retries)}
              onChange={(e) =>
                setStreamConfigValue('publish_retries', e.target.value === '' ? undefined : Number(e.target.value))
              }
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="3"
            />
          </div>
        </div>

        <div className="grid grid-cols-3 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Publish Retry Interval</label>
            <input
              type="text"
              value={stringValue(config.stream_config?.publish_retry_interval)}
              onChange={(e) => setStreamConfigValue('publish_retry_interval', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="5s"
            />
          </div>
          <div />
          <div />
        </div>
      </section>

      <section className="bg-white dark:bg-gray-800 p-6 rounded-lg border border-gray-200 dark:border-gray-700 space-y-4">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h3 className="text-lg font-semibold">Scheduled Discovery Jobs</h3>
            <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">
              Configure LAN discovery runs without pasting JSON. Use JSON view for advanced mapper settings.
            </p>
          </div>
          <button
            type="button"
            onClick={addJob}
            className="px-3 py-2 text-sm font-medium text-blue-600 hover:text-blue-700 hover:bg-blue-50 dark:hover:bg-blue-900 rounded-md"
          >
            + Add Job
          </button>
        </div>

        {scheduledJobs.length === 0 && (
          <div className="text-sm text-gray-500 dark:text-gray-400 border border-dashed border-gray-300 dark:border-gray-600 rounded-md p-4">
            No scheduled jobs configured yet.
          </div>
        )}

        <div className="space-y-4">
          {scheduledJobs.map((job, index) => {
            const isOpen = expanded[index] ?? (scheduledJobs.length === 1);
            const jobName = (job?.name ?? '').trim() || `job-${index + 1}`;
            const seeds = normalizeSeeds(job?.seeds);
            const creds = job?.credentials ?? {};
            const communityRedacted = showRedacted(creds.community);
            const communityDraftKey = getSecretDraftKey('job', index, 'community');

            return (
              <div key={`${jobName}:${index}`} className="border border-gray-200 dark:border-gray-700 rounded-lg p-4">
                <div className="flex items-start justify-between gap-4">
                  <div className="min-w-0">
                    <p className="text-xs uppercase text-gray-500 dark:text-gray-400">Job</p>
                    <p className="text-sm font-medium break-all">{jobName}</p>
                    <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
                      {job?.enabled ? 'Enabled' : 'Disabled'} • Every {job?.interval || '—'} • {seeds.length} seed(s)
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
                      onClick={() => removeJob(index)}
                      className="px-3 py-2 text-sm rounded-md text-red-600 hover:text-red-700 hover:bg-red-50 dark:hover:bg-red-900/20"
                    >
                      Remove
                    </button>
                  </div>
                </div>

                {isOpen && (
                  <div className="mt-4 space-y-5">
                    <div className="grid grid-cols-2 gap-4">
                      <div>
                        <label className="block text-sm font-medium mb-2">Name</label>
                        <input
                          type="text"
                          value={job?.name ?? ''}
                          onChange={(e) => setJob(index, { ...job, name: e.target.value })}
                          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                          placeholder="primary-lan-discovery"
                        />
                      </div>
                      <div className="flex items-center gap-2 mt-7">
                        <input
                          id={`mapper-job-${index}-enabled`}
                          type="checkbox"
                          checked={job?.enabled ?? false}
                          onChange={(e) => setJob(index, { ...job, enabled: e.target.checked })}
                          className="h-4 w-4"
                        />
                        <label htmlFor={`mapper-job-${index}-enabled`} className="text-sm">
                          Enabled
                        </label>
                      </div>
                    </div>

                    <div className="grid grid-cols-3 gap-4">
                      <div>
                        <label className="block text-sm font-medium mb-2">Interval</label>
                        <input
                          type="text"
                          value={job?.interval ?? ''}
                          onChange={(e) => setJob(index, { ...job, interval: e.target.value })}
                          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                          placeholder="1h"
                        />
                      </div>
                      <div>
                        <label className="block text-sm font-medium mb-2">Discovery Type</label>
                        <select
                          value={job?.type ?? 'full'}
                          onChange={(e) => setJob(index, { ...job, type: e.target.value })}
                          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-900"
                        >
                          <option value="full">Full</option>
                          <option value="basic">Basic</option>
                          <option value="interfaces">Interfaces</option>
                          <option value="topology">Topology</option>
                        </select>
                      </div>
                      <div>
                        <label className="block text-sm font-medium mb-2">Concurrency</label>
                        <input
                          type="number"
                          value={stringValue(job?.concurrency)}
                          onChange={(e) =>
                            setJob(index, {
                              ...job,
                              concurrency: e.target.value === '' ? undefined : Number(e.target.value),
                            })
                          }
                          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                          placeholder="10"
                        />
                      </div>
                    </div>

                    <div className="grid grid-cols-3 gap-4">
                      <div>
                        <label className="block text-sm font-medium mb-2">Timeout</label>
                        <input
                          type="text"
                          value={job?.timeout ?? ''}
                          onChange={(e) => setJob(index, { ...job, timeout: e.target.value })}
                          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                          placeholder="45s"
                        />
                      </div>
                      <div>
                        <label className="block text-sm font-medium mb-2">Retries</label>
                        <input
                          type="number"
                          value={stringValue(job?.retries)}
                          onChange={(e) =>
                            setJob(index, { ...job, retries: e.target.value === '' ? undefined : Number(e.target.value) })
                          }
                          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                          placeholder="2"
                        />
                      </div>
                      <div />
                    </div>

                    <div className="border-t border-gray-200 dark:border-gray-700 pt-4 space-y-3">
                      <h4 className="text-sm font-medium">Seed Routers</h4>
                      <div className="grid grid-cols-2 gap-3">
                        <div>
                          <label className="block text-xs font-medium mb-1">Seeds (one per line)</label>
                          <textarea
                            value={seeds.join('\n')}
                            onChange={(e) => setJobSeeds(index, normalizeSeeds(e.target.value.split('\n')))}
                            className="w-full h-28 font-mono text-sm p-2 border border-gray-300 dark:border-gray-600 rounded-md bg-gray-50 dark:bg-gray-900"
                            placeholder="192.168.2.1"
                            spellCheck={false}
                          />
                        </div>
                        <div className="text-xs text-gray-500 dark:text-gray-400 leading-5 pt-6">
                          Enter router IPs (or CIDRs, if supported) that act as discovery entry points.
                        </div>
                      </div>
                    </div>

                    <div className="border-t border-gray-200 dark:border-gray-700 pt-4 space-y-3">
                      <h4 className="text-sm font-medium">SNMP Credentials</h4>
                      <div className="grid grid-cols-3 gap-4">
                        <div>
                          <label className="block text-sm font-medium mb-2">Version</label>
                          <select
                            value={creds.version ?? 'v2c'}
                            onChange={(e) => setJobCredential(index, 'version', e.target.value)}
                            className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-900"
                          >
                            <option value="v1">v1</option>
                            <option value="v2c">v2c</option>
                            <option value="v3">v3</option>
                          </select>
                        </div>
                        <div>
                          <label className="block text-sm font-medium mb-2">Community</label>
                          <input
                            type="password"
                            value={pendingSecrets[communityDraftKey] ?? ''}
                            onChange={(e) => setPendingSecrets((prev) => ({ ...prev, [communityDraftKey]: e.target.value }))}
                            onBlur={() => handleJobSecretBlur(index, 'community')}
                            className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                            placeholder={communityRedacted ? 'unchanged' : 'public'}
                            autoComplete="off"
                          />
                          {communityRedacted && (
                            <p className="mt-1 text-[11px] text-gray-500 dark:text-gray-400">
                              Existing value is redacted; leave blank to keep it unchanged.
                            </p>
                          )}
                        </div>
                        <div className="text-xs text-gray-500 dark:text-gray-400 leading-5 pt-7">
                          For SNMPv3, use JSON view for now (auth/privacy protocols/passwords).
                        </div>
                      </div>
                    </div>
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
