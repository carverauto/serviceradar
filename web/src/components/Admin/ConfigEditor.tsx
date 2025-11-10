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
import { Save, RefreshCw, AlertCircle, Check, Copy, FileJson, ArrowLeft } from 'lucide-react';
import CoreConfigForm from './ConfigForms/CoreConfigForm';
import SyncConfigForm from './ConfigForms/SyncConfigForm';
import PollerConfigForm from './ConfigForms/PollerConfigForm';
import AgentConfigForm from './ConfigForms/AgentConfigForm';
import type { ConfigDescriptor } from './types';

interface ServiceInfo {
  id: string;
  name: string;
  type: string; // 'core' | 'sync' | 'poller' | 'agent' | 'otel' | 'flowgger' | checker types
  kvStore?: string;
  pollerId?: string;
  agentId?: string;
  descriptor?: ConfigDescriptor | null;
}

interface ConfigEditorProps {
  service: ServiceInfo;
  kvStore: string;
  onSave: () => void;
  onClose?: () => void;
}

type ConfigMetadata = {
  service: string;
  kv_key: string;
  kv_store_id?: string;
  revision: number;
  origin?: 'seeded' | 'user' | 'unknown';
  last_writer?: string;
  updated_at?: string;
  format: 'json' | 'toml';
};

type ConfigEnvelope = {
  metadata: ConfigMetadata;
  config?: Record<string, unknown>;
  raw_config?: string;
};

const normalizeConfigPayload = (payload: unknown): Record<string, unknown> => {
  if (!payload) {
    return {};
  }
  if (typeof payload === 'string') {
    try {
      return normalizeConfigPayload(JSON.parse(payload));
    } catch {
      return {};
    }
  }
  if (typeof payload !== 'object' || Array.isArray(payload)) {
    return {};
  }
  try {
    return JSON.parse(JSON.stringify(payload));
  } catch {
    return { ...(payload as Record<string, unknown>) };
  }
};

export default function ConfigEditor({ service, kvStore, onSave, onClose }: ConfigEditorProps) {
  const [config, setConfig] = useState<Record<string, unknown> | null>(null);
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState(false);
  const [jsonMode, setJsonMode] = useState(false);
  const [jsonValue, setJsonValue] = useState('');
  const [isToml, setIsToml] = useState(false);
  const [rawValue, setRawValue] = useState('');
  // KV Info state
  const [kvInfo, setKvInfo] = useState<{ domain: string; bucket: string } | null>(null);
  const [kvInfoError, setKvInfoError] = useState<string | null>(null);
  const [metadata, setMetadata] = useState<ConfigMetadata | null>(null);
  const descriptorMeta = service.descriptor ?? null;
  const canonicalServiceType = descriptorMeta?.service_type ?? service.type;
  const needsAgentContext = React.useMemo(() => {
    if (descriptorMeta) {
      return descriptorMeta.scope === 'agent' || Boolean(descriptorMeta.requires_agent);
    }
    return Boolean(service.agentId) && service.type !== 'poller' && service.type !== 'agent';
  }, [descriptorMeta, service.agentId, service.type]);
  const needsPollerContext = React.useMemo(() => {
    if (descriptorMeta) {
      return descriptorMeta.scope === 'poller' || Boolean(descriptorMeta.requires_poller);
    }
    return service.type === 'poller' || Boolean(service.pollerId);
  }, [descriptorMeta, service.pollerId, service.type]);
  const scopeHint = descriptorMeta?.scope ?? (needsAgentContext ? 'agent' : needsPollerContext ? 'poller' : 'global');

  const applyJsonConfig = useCallback(
    (payload: unknown) => {
      const normalized = normalizeConfigPayload(payload);
      setIsToml(false);
      setConfig(normalized);
      setRawValue('');
      setJsonValue(JSON.stringify(normalized, null, 2));
    },
    [setConfig, setIsToml, setRawValue, setJsonValue],
  );

  const buildConfigQuery = React.useCallback(() => {
    const params = new URLSearchParams();
    if (kvStore) {
      params.set('kv_store_id', kvStore);
    }
    if (needsAgentContext) {
      if (!service.agentId) {
        throw new Error('Select an agent before editing this configuration');
      }
      params.set('agent_id', service.agentId);
      if (canonicalServiceType) {
        params.set('service_type', canonicalServiceType);
      }
    }
    if (needsPollerContext) {
      if (!service.pollerId) {
        throw new Error('Select a poller before editing this configuration');
      }
      params.set('poller_id', service.pollerId);
      if (canonicalServiceType) {
        params.set('service_type', canonicalServiceType);
      }
    }
    const query = params.toString();
    return query ? `?${query}` : '';
  }, [kvStore, needsAgentContext, needsPollerContext, service.agentId, service.pollerId, canonicalServiceType]);

  const fetchConfig = React.useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      
      // Get token from cookie instead of localStorage
      const token = document.cookie
        .split("; ")
        .find((row) => row.startsWith("accessToken="))
        ?.split("=")[1];
      let query = '';
      try {
        query = buildConfigQuery();
      } catch (buildErr) {
        const message = buildErr instanceof Error ? buildErr.message : 'Invalid configuration selection';
        setMetadata(null);
        setConfig(null);
        setRawValue('');
        setError(message);
        return;
      }

      const targetService = canonicalServiceType || service.type;
      if (!targetService) {
        setMetadata(null);
        setConfig(null);
        setRawValue('');
        setError('Unknown service descriptor');
        return;
      }

      const response = await fetch(`/api/admin/config/${targetService}${query}`, {
        headers: {
          'Authorization': `Bearer ${token}`,
        },
      });

      if (!response.ok) {
        setMetadata(null);
        if (response.status === 404) {
          const def = getDefaultConfig(targetService);
          if (typeof def === 'string') {
            setIsToml(true);
            setRawValue(def);
            setConfig(null);
            setJsonValue(def);
          } else {
            applyJsonConfig(def);
          }
        } else {
          throw new Error('Failed to fetch configuration');
        }
      } else {
        const ct = response.headers.get('content-type') || '';
        if (ct.includes('application/json')) {
          const data = await response.json();
          if (data && 'metadata' in data) {
            const envelope = data as ConfigEnvelope;
            setMetadata(envelope.metadata);
            const fmt = envelope.metadata.format;
            if (fmt === 'toml') {
              setIsToml(true);
              setRawValue(envelope.raw_config ?? '');
              setConfig(null);
              setJsonValue(envelope.raw_config ?? '');
              setJsonMode(false);
            } else {
              applyJsonConfig(envelope.config ?? {});
            }
          } else {
            setMetadata(null);
            applyJsonConfig(data);
          }
        } else {
          const text = await response.text();
          setMetadata(null);
          setIsToml(true);
          setRawValue(text);
          setConfig(null);
          setJsonValue(text);
        }
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : 'Unknown error';
      setError(message);
      setMetadata(null);
      // Load default config on error
      const fallbackTarget = canonicalServiceType || service.type;
      const def = getDefaultConfig(fallbackTarget);
      if (typeof def === 'string') {
        setIsToml(true);
        setRawValue(def);
        setConfig(null);
        setJsonValue(def);
      } else {
        applyJsonConfig(def);
      }
    } finally {
      setLoading(false);
    }
  }, [applyJsonConfig, buildConfigQuery, canonicalServiceType, service.type]);

  const fetchKvInfo = React.useCallback(async () => {
    try {
      setKvInfoError(null);
      const token = document.cookie
        .split("; ")
        .find((row) => row.startsWith("accessToken="))
        ?.split("=")[1];
      const query = kvStore ? `?kv_store_id=${encodeURIComponent(kvStore)}` : '';
      const response = await fetch(`/api/kv/info${query}`, {
        headers: { 'Authorization': `Bearer ${token}` }
      });
      if (!response.ok) throw new Error('Failed to fetch KV info');
      const data = await response.json();
      setKvInfo({ domain: data.domain, bucket: data.bucket });
    } catch (err: unknown) {
      setKvInfo(null);
      const message = err instanceof Error ? err.message : 'KV info unavailable';
      setKvInfoError(message);
    }
  }, [kvStore]);

  useEffect(() => {
    fetchConfig();
    fetchKvInfo();
  }, [fetchConfig, fetchKvInfo]);


  const getDefaultConfig = (type: string): Record<string, unknown> | string => {
    switch (type) {
      case 'core':
        return {
          listen_addr: ':8090',
          grpc_addr: ':50052',
          alert_threshold: '5m',
          known_pollers: ['default-poller'],
          metrics: {
            enabled: true,
            retention: 100,
            max_pollers: 10000
          },
          database: {
            addresses: ['proton:9440'],
            name: 'default',
            username: 'default',
            password: '',
            max_conns: 10,
            idle_conns: 5
          },
          nats: {
            url: 'nats://127.0.0.1:4222'
          },
          auth: {
            jwt_secret: '',
            jwt_expiration: '24h',
            local_users: {
              admin: ''
            }
          }
        };
      case 'sync':
        return {
          grpc_addr: ':50053',
          sync_interval: '30s',
          batch_size: 100,
          nats: {
            url: 'nats://127.0.0.1:4222'
          }
        };
      case 'poller':
        return {
          id: '',
          name: '',
          interval: '60s',
          timeout: '30s',
          max_workers: 10,
          nats: {
            url: 'nats://127.0.0.1:4222'
          }
        };
      case 'agent':
        return {
          id: '',
          name: '',
          poller_id: '',
          checkers: {
            icmp: { enabled: true },
            snmp: { enabled: false },
            http: { enabled: false }
          },
          nats: {
            url: 'nats://127.0.0.1:4222'
          }
        };
      case 'sweep':
        return { networks: [], interval: '60s', timeout: '5s' };
      case 'snmp':
        return { enabled: false, listen_addr: ':50043', node_address: 'localhost:50043', partition: 'default', targets: [] };
      case 'mapper':
        return { enabled: true, address: 'serviceradar-mapper:50056' };
      case 'trapd':
        return { enabled: false, listen_addr: ':50043' };
      case 'rperf':
        return { enabled: false, targets: [] };
      case 'sysmon':
        return { enabled: true, interval: '10s' };
      case 'db-event-writer':
        return {
          listen_addr: ':50061',
          database: { addresses: ['proton:9440'], name: 'default', username: 'default', password: '' },
          logging: { level: 'info', output: 'stdout' },
          security: null,
        };
      case 'zen-consumer':
        return {
          listen_addr: ':50062',
          nats: { url: 'nats://127.0.0.1:4222', subject: 'events.zen', stream: 'events' },
          logging: { level: 'info', output: 'stdout' },
          security: null,
        };
      case 'otel':
        return `# ServiceRadar OTEL Collector\n[server]\nbind_address = "0.0.0.0"\nport = 4317\n\n[nats]\nurl = "nats://localhost:4222"\nsubject = "events.otel"\nstream = "events"\n`;
      case 'flowgger':
        return `# Flowgger\n[input]\ntype = "syslog-tls"\nformat = "rfc5424"\n\n[output]\ntype = "tls"\nformat = "gelf"\n`;
      default:
        return {};
    }
  };

  const handleSave = async () => {
    try {
      setSaving(true);
      setError(null);
      setSuccess(false);

      const configToSave = isToml ? rawValue : (jsonMode ? JSON.parse(jsonValue) : config);

      // Get token from cookie instead of localStorage
      const token = document.cookie
        .split("; ")
        .find((row) => row.startsWith("accessToken="))
        ?.split("=")[1];
      let query = '';
      try {
        query = buildConfigQuery();
      } catch (buildErr) {
        const message = buildErr instanceof Error ? buildErr.message : 'Invalid configuration selection';
        setError(message);
        return;
      }

      const targetService = canonicalServiceType || service.type;
      if (!targetService) {
        setError('Unknown service descriptor');
        return;
      }

      const response = await fetch(`/api/admin/config/${targetService}${query}`, {
        method: 'PUT',
        headers: isToml ? {
          'Content-Type': 'text/plain',
          'Authorization': `Bearer ${token}`,
        } : {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${token}`,
        },
        body: isToml ? (configToSave as string) : JSON.stringify(configToSave),
      });

      if (!response.ok) {
        throw new Error('Failed to save configuration');
      }

      setSuccess(true);
      // Notify listeners (e.g., Global Services status) that a config was saved
      try {
        // Use a custom event; keep payload minimal and generic
        const evt = new CustomEvent('sr:config-saved', {
          detail: {
            serviceType: targetService,
            scope: scopeHint,
            kvStore,
          }
        });
        window.dispatchEvent(evt);
      } catch {}
      try {
        await fetchConfig();
      } catch {
        // fetchConfig already surfaces its own error state
      }
      onSave();
      
      setTimeout(() => setSuccess(false), 3000);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : 'Unknown error';
      setError(message);
    } finally {
      setSaving(false);
    }
  };

  const handleConfigChange = (newConfig: Record<string, unknown>) => {
    setConfig(newConfig);
    setJsonValue(JSON.stringify(newConfig, null, 2));
  };

  const handleJsonChange = (value: string) => {
    setJsonValue(value);
    try {
      const parsed = JSON.parse(value);
      setConfig(parsed);
      setError(null);
    } catch {
      // JSON is invalid, but allow editing
    }
  };

  const currentConfig = React.useMemo(() => {
    if (isToml) return null;
    return config;
  }, [isToml, config]);

  const copyToClipboard = () => {
    navigator.clipboard.writeText(jsonValue);
  };

  const effectiveServiceType = React.useMemo(
    () => (canonicalServiceType || service.type || '').toLowerCase(),
    [canonicalServiceType, service.type],
  );

  const renderConfigForm = () => {
    // Don't render form if config is not loaded yet
    if (isToml) {
      return (
        <div className="h-full">
          <div className="flex items-center justify-between mb-2">
            <span className="text-sm text-gray-600 dark:text-gray-400">TOML Configuration</span>
            <button onClick={copyToClipboard} className="text-sm text-blue-600 hover:text-blue-700 flex items-center gap-1">
              <Copy className="h-3 w-3" />
              Copy
            </button>
          </div>
          <textarea
            value={rawValue}
            onChange={(e) => setRawValue(e.target.value)}
            className="w-full h-full font-mono text-sm p-3 border border-gray-300 dark:border-gray-600 rounded-md bg-gray-50 dark:bg-gray-900"
            spellCheck={false}
          />
        </div>
      );
    }
    if (!currentConfig) {
      return (
        <div className="flex items-center justify-center p-8">
          <div className="text-gray-500 dark:text-gray-400">
            {loading ? 'Loading configuration...' : 'No configuration loaded'}
          </div>
        </div>
      );
    }

    switch (effectiveServiceType) {
      case 'core':
        return <CoreConfigForm config={currentConfig as unknown as Parameters<typeof CoreConfigForm>[0]['config']} onChange={handleConfigChange as unknown as Parameters<typeof CoreConfigForm>[0]['onChange']} />;
      case 'sync':
        return <SyncConfigForm config={currentConfig as unknown as Parameters<typeof SyncConfigForm>[0]['config']} onChange={handleConfigChange as unknown as Parameters<typeof SyncConfigForm>[0]['onChange']} />;
      case 'poller':
        return <PollerConfigForm config={currentConfig as unknown as Parameters<typeof PollerConfigForm>[0]['config']} onChange={handleConfigChange as unknown as Parameters<typeof PollerConfigForm>[0]['onChange']} />;
      case 'agent':
        return <AgentConfigForm config={currentConfig as unknown as Parameters<typeof AgentConfigForm>[0]['config']} onChange={handleConfigChange as unknown as Parameters<typeof AgentConfigForm>[0]['onChange']} />;
      default:
        return null;
    }
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center h-full">
        <div className="flex items-center space-x-2">
          <RefreshCw className="h-5 w-5 animate-spin" />
          <span>Loading configuration...</span>
        </div>
      </div>
    );
  }

  return (
    <div className="h-full flex flex-col">
      <div className="border-b border-gray-200 dark:border-gray-700 p-4">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div className="flex flex-1 items-start gap-3 min-w-0">
            {onClose && (
              <button
                type="button"
                onClick={onClose}
                aria-label="Back to service list"
                className="mt-1 inline-flex h-9 w-9 items-center justify-center rounded-full border border-gray-200 text-gray-600 hover:bg-gray-100 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
              >
                <ArrowLeft className="h-4 w-4" />
              </button>
            )}
            <div className="min-w-0">
              <h2 className="text-lg font-semibold truncate">{service.name}</h2>
              <p className="text-sm text-gray-600 dark:text-gray-400">
                KV Store: {kvStore || 'default'} | Service ID: {service.id}
              </p>
              <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-gray-600 dark:text-gray-400">
                {kvInfo ? (
                  <>
                    <span className="px-1.5 py-0.5 rounded bg-gray-100 dark:bg-gray-700">Domain: {kvInfo.domain}</span>
                    <span className="px-1.5 py-0.5 rounded bg-gray-100 dark:bg-gray-700">Bucket: {kvInfo.bucket}</span>
                  </>
                ) : (
                  <span className="opacity-75">{kvInfoError ? `KV info: ${kvInfoError}` : 'Loading KV info…'}</span>
                )}
              </div>
            </div>
          </div>
          <div className="flex items-center gap-2">
            {!isToml && (<button
              onClick={() => setJsonMode(!jsonMode)}
              className="px-3 py-1.5 text-sm border border-gray-300 dark:border-gray-600 rounded-md hover:bg-gray-100 dark:hover:bg-gray-700 flex items-center gap-2"
            >
              <FileJson className="h-4 w-4" />
              {jsonMode ? 'Form View' : 'JSON View'}
            </button>)}
            <button
              onClick={fetchConfig}
              className="px-3 py-1.5 text-sm border border-gray-300 dark:border-gray-600 rounded-md hover:bg-gray-100 dark:hover:bg-gray-700 flex items-center gap-2"
            >
              <RefreshCw className="h-4 w-4" />
              Refresh
            </button>
            <button
              onClick={handleSave}
              disabled={saving}
              className="px-4 py-1.5 text-sm bg-blue-600 text-white rounded-md hover:bg-blue-700 disabled:opacity-50 flex items-center gap-2"
            >
              {saving ? (
                <RefreshCw className="h-4 w-4 animate-spin" />
              ) : (
                <Save className="h-4 w-4" />
              )}
              Save
            </button>
          </div>
        </div>

        {error && (
          <div className="mt-2 p-2 bg-red-100 dark:bg-red-900 text-red-800 dark:text-red-200 rounded-md flex items-center gap-2">
            <AlertCircle className="h-4 w-4" />
            <span className="text-sm">{error}</span>
          </div>
        )}

        {success && (
          <div className="mt-2 p-2 bg-green-100 dark:bg-green-900 text-green-800 dark:text-green-200 rounded-md flex items-center gap-2">
            <Check className="h-4 w-4" />
            <span className="text-sm">Configuration saved successfully</span>
          </div>
        )}

        {metadata && (
          <div className="mt-3 flex flex-wrap gap-2 text-xs text-gray-600 dark:text-gray-400">
            <span className="px-1.5 py-0.5 rounded bg-gray-100 dark:bg-gray-800">
              Revision #{metadata.revision ?? 0}
            </span>
            <span className="px-1.5 py-0.5 rounded bg-gray-100 dark:bg-gray-800">
              {metadata.origin === 'seeded'
                ? 'Fresh seed'
                : metadata.origin === 'user'
                  ? 'User-edited'
                  : 'Origin unknown'}
              {metadata.last_writer ? ` by ${metadata.last_writer}` : ''}
            </span>
            {metadata.updated_at && (
              <span className="px-1.5 py-0.5 rounded bg-gray-100 dark:bg-gray-800">
                Updated {new Date(metadata.updated_at).toLocaleString()}
              </span>
            )}
          </div>
        )}
      </div>

      <div className="flex-1 overflow-y-auto p-4">
        {jsonMode ? (
          <div className="h-full">
            <div className="flex items-center justify-between mb-2">
              <span className="text-sm text-gray-600 dark:text-gray-400">JSON Configuration</span>
              <button
                onClick={copyToClipboard}
                className="text-sm text-blue-600 hover:text-blue-700 flex items-center gap-1"
              >
                <Copy className="h-3 w-3" />
                Copy
              </button>
            </div>
            <textarea
              value={jsonValue}
              onChange={(e) => handleJsonChange(e.target.value)}
              className="w-full h-full font-mono text-sm p-3 border border-gray-300 dark:border-gray-600 rounded-md bg-gray-50 dark:bg-gray-900"
              spellCheck={false}
            />
          </div>
        ) : (
          renderConfigForm()
        )}
      </div>
    </div>
  );
}
