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

import React, { useState, useEffect } from 'react';
import { Save, RefreshCw, AlertCircle, Check, Copy, FileJson } from 'lucide-react';
import CoreConfigForm from './ConfigForms/CoreConfigForm';
import SyncConfigForm from './ConfigForms/SyncConfigForm';
import PollerConfigForm from './ConfigForms/PollerConfigForm';
import AgentConfigForm from './ConfigForms/AgentConfigForm';

interface ServiceInfo {
  id: string;
  name: string;
  type: string; // 'core' | 'sync' | 'poller' | 'agent' | 'otel' | 'flowgger' | checker types
  kvStore?: string;
  pollerId?: string;
  agentId?: string;
}

interface ConfigEditorProps {
  service: ServiceInfo;
  kvStore: string;
  onSave: () => void;
}

export default function ConfigEditor({ service, kvStore, onSave }: ConfigEditorProps) {
  const [config, setConfig] = useState<any>(null);
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

  useEffect(() => {
    fetchConfig();
    fetchKvInfo();
  }, [service, kvStore]);

  const fetchConfig = async () => {
    try {
      setLoading(true);
      setError(null);
      
      // Get token from cookie instead of localStorage
      const token = document.cookie
        .split("; ")
        .find((row) => row.startsWith("accessToken="))
        ?.split("=")[1];
      const extraGet = (service.type !== 'poller' && service.type !== 'agent' && service.agentId) ? `&agent_id=${encodeURIComponent(service.agentId)}&service_type=${encodeURIComponent(service.type)}` : '';
      const response = await fetch(`/api/admin/config/${service.type}?kv_store_id=${kvStore}${extraGet}`, {
        headers: {
          'Authorization': `Bearer ${token}`,
        },
      });

      if (!response.ok) {
        if (response.status === 404) {
          // Load default config template
          const def = getDefaultConfig(service.type);
          if (typeof def === 'string') {
            setIsToml(true);
            setRawValue(def);
          } else {
            setIsToml(false);
            setConfig(def);
            setJsonValue(JSON.stringify(def, null, 2));
          }
        } else {
          throw new Error('Failed to fetch configuration');
        }
      } else {
        const ct = response.headers.get('content-type') || '';
        if (ct.includes('text/plain')) {
          const text = await response.text();
          setIsToml(true);
          setRawValue(text);
        } else {
          const data = await response.json();
          setIsToml(false);
          setConfig(data);
          setJsonValue(JSON.stringify(data, null, 2));
        }
      }
    } catch (err: any) {
      setError(err.message);
      // Load default config on error
      const def = getDefaultConfig(service.type);
      if (typeof def === 'string') { setIsToml(true); setRawValue(def); }
      else { setIsToml(false); setConfig(def); setJsonValue(JSON.stringify(def, null, 2)); }
    } finally {
      setLoading(false);
    }
  };

  const fetchKvInfo = async () => {
    try {
      setKvInfoError(null);
      const token = document.cookie
        .split("; ")
        .find((row) => row.startsWith("accessToken="))
        ?.split("=")[1];
      const response = await fetch(`/api/kv/info?kv_store_id=${encodeURIComponent(kvStore)}` , {
        headers: { 'Authorization': `Bearer ${token}` }
      });
      if (!response.ok) throw new Error('Failed to fetch KV info');
      const data = await response.json();
      setKvInfo({ domain: data.domain, bucket: data.bucket });
    } catch (err: any) {
      setKvInfo(null);
      setKvInfoError(err.message || 'KV info unavailable');
    }
  };

  const getDefaultConfig = (type: string): any => {
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
        
      const extra = (service.type !== 'poller' && service.type !== 'agent' && service.agentId) ? `&agent_id=${encodeURIComponent(service.agentId)}&service_type=${encodeURIComponent(service.type)}` : '';
      const response = await fetch(`/api/admin/config/${service.type}?kv_store_id=${kvStore}${extra}`, {
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
      onSave();
      
      setTimeout(() => setSuccess(false), 3000);
    } catch (err: any) {
      setError(err.message);
    } finally {
      setSaving(false);
    }
  };

  const handleConfigChange = (newConfig: any) => {
    setConfig(newConfig);
    setJsonValue(JSON.stringify(newConfig, null, 2));
  };

  const handleJsonChange = (value: string) => {
    setJsonValue(value);
    try {
      const parsed = JSON.parse(value);
      setConfig(parsed);
      setError(null);
    } catch (err) {
      // JSON is invalid, but allow editing
    }
  };

  const copyToClipboard = () => {
    navigator.clipboard.writeText(jsonValue);
  };

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
    if (!config) {
      return (
        <div className="flex items-center justify-center p-8">
          <div className="text-gray-500 dark:text-gray-400">
            {loading ? 'Loading configuration...' : 'No configuration loaded'}
          </div>
        </div>
      );
    }

    switch (service.type) {
      case 'core':
        return <CoreConfigForm config={config} onChange={handleConfigChange} />;
      case 'sync':
        return <SyncConfigForm config={config} onChange={handleConfigChange} />;
      case 'poller':
        return <PollerConfigForm config={config} onChange={handleConfigChange} />;
      case 'agent':
        return <AgentConfigForm config={config} onChange={handleConfigChange} />;
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
        <div className="flex items-center justify-between">
          <div>
            <h2 className="text-lg font-semibold">{service.name}</h2>
            <p className="text-sm text-gray-600 dark:text-gray-400">
              KV Store: {kvStore} | Service ID: {service.id}
            </p>
            <div className="mt-1 flex items-center gap-2 text-xs text-gray-600 dark:text-gray-400">
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
