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

import React, { useEffect, useMemo, useState } from 'react';
import safeSet from '../../../lib/safeSet';
import SecurityFields, { SecurityConfig, TLSConfig } from './SecurityFields';

type OTelConfig = {
  enabled?: boolean;
  insecure?: boolean;
  endpoint?: string;
  service_name?: string;
  batch_timeout?: string | number;
  headers?: Record<string, string>;
  tls?: TLSConfig;
};

type LoggingConfig = {
  level?: string;
  debug?: boolean;
  output?: string;
  time_format?: string;
  otel?: OTelConfig;
};

interface AgentConfig {
  agent_id?: string;
  agent_name?: string;
  service_name?: string;
  service_type?: string;
  host_ip?: string;
  partition?: string;
  listen_addr?: string;
  checkers_dir?: string;
  kv_address?: string;
  security?: SecurityConfig | null;
  kv_security?: SecurityConfig | null;
  logging?: LoggingConfig;
}

interface AgentConfigFormProps {
  config: AgentConfig;
  onChange: (config: AgentConfig) => void;
}

const stringValue = (value?: string | number | null) =>
  value === undefined || value === null ? '' : String(value);

export default function AgentConfigForm({ config, onChange }: AgentConfigFormProps) {
  const updateConfig = (path: string, value: unknown) => {
    const next = { ...config };
    safeSet(next as Record<string, unknown>, path, value);
    onChange(next as AgentConfig);
  };

  const [otelHeadersText, setOtelHeadersText] = useState('{}');
  const [otelHeadersError, setOtelHeadersError] = useState<string | null>(null);

  const serializedHeaders = useMemo(
    () => JSON.stringify(config.logging?.otel?.headers ?? {}, null, 2),
    [config.logging?.otel?.headers],
  );

  useEffect(() => {
    setOtelHeadersText(serializedHeaders);
    setOtelHeadersError(null);
  }, [serializedHeaders]);

  const handleHeadersBlur = () => {
    if (!otelHeadersText.trim()) {
      updateConfig('logging.otel.headers', {});
      setOtelHeadersText('{}');
      setOtelHeadersError(null);
      return;
    }
    try {
      const parsed = JSON.parse(otelHeadersText);
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
        throw new Error('Headers must be a JSON object');
      }
      updateConfig('logging.otel.headers', parsed);
      setOtelHeadersError(null);
    } catch {
      setOtelHeadersError('Headers must be a JSON object (e.g. {"x-api-key":"secret"})');
    }
  };

  return (
    <div className="space-y-6">
      <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border border-gray-200 dark:border-gray-700">
        <h3 className="text-lg font-semibold">Agent Service</h3>
        <p className="text-sm text-gray-600 dark:text-gray-400">
          Identify this agent, its network listener, and KV wiring.
        </p>

        <div className="grid grid-cols-2 gap-4 mt-4">
          <div>
            <label className="block text-sm font-medium mb-2">Agent ID</label>
            <input
              type="text"
              value={config.agent_id ?? ''}
              onChange={(e) => updateConfig('agent_id', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="k8s-agent"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Agent Name</label>
            <input
              type="text"
              value={config.agent_name ?? ''}
              onChange={(e) => updateConfig('agent_name', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="serviceradar-agent"
            />
          </div>
        </div>

        <div className="grid grid-cols-2 gap-4 mt-4">
          <div>
            <label className="block text-sm font-medium mb-2">Service Name</label>
            <input
              type="text"
              value={config.service_name ?? ''}
              onChange={(e) => updateConfig('service_name', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="AgentService"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Service Type</label>
            <input
              type="text"
              value={config.service_type ?? ''}
              onChange={(e) => updateConfig('service_type', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="grpc"
            />
          </div>
        </div>

        <div className="grid grid-cols-3 gap-4 mt-4">
          <div>
            <label className="block text-sm font-medium mb-2">Listen Address</label>
            <input
              type="text"
              value={config.listen_addr ?? ''}
              onChange={(e) => updateConfig('listen_addr', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder=":50051"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Host IP</label>
            <input
              type="text"
              value={config.host_ip ?? ''}
              onChange={(e) => updateConfig('host_ip', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="PLACEHOLDER_HOST_IP"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Partition</label>
            <input
              type="text"
              value={config.partition ?? ''}
              onChange={(e) => updateConfig('partition', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="default"
            />
          </div>
        </div>

        <div className="grid grid-cols-2 gap-4 mt-4">
          <div>
            <label className="block text-sm font-medium mb-2">Checkers Directory</label>
            <input
              type="text"
              value={config.checkers_dir ?? ''}
              onChange={(e) => updateConfig('checkers_dir', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="/etc/serviceradar/checkers"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">KV Address</label>
            <input
              type="text"
              value={config.kv_address ?? ''}
              onChange={(e) => updateConfig('kv_address', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="serviceradar-datasvc:50057"
            />
          </div>
        </div>
      </div>

      <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border border-gray-200 dark:border-gray-700">
        <h3 className="text-lg font-semibold">Logging & Telemetry</h3>
        <p className="text-sm text-gray-600 dark:text-gray-400">Control log verbosity and OTEL export settings.</p>

        <div className="grid grid-cols-4 gap-4 mt-4">
          <div>
            <label className="block text-sm font-medium mb-2">Log Level</label>
            <select
              value={config.logging?.level ?? 'info'}
              onChange={(e) => updateConfig('logging.level', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            >
              <option value="debug">Debug</option>
              <option value="info">Info</option>
              <option value="warn">Warn</option>
              <option value="error">Error</option>
            </select>
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Output</label>
            <select
              value={config.logging?.output ?? 'stdout'}
              onChange={(e) => updateConfig('logging.output', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            >
              <option value="stdout">stdout</option>
              <option value="stderr">stderr</option>
              <option value="file">file</option>
            </select>
          </div>
          <div className="flex items-center gap-2 mt-6">
            <input
              id="agent-logging-debug"
              type="checkbox"
              checked={config.logging?.debug ?? false}
              onChange={(e) => updateConfig('logging.debug', e.target.checked)}
              className="h-4 w-4"
            />
            <label htmlFor="agent-logging-debug" className="text-sm">Enable Debug Output</label>
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Time Format</label>
            <input
              type="text"
              value={config.logging?.time_format ?? ''}
              onChange={(e) => updateConfig('logging.time_format', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="2006-01-02T15:04:05Z07:00"
            />
          </div>
        </div>

        <div className="mt-6 border-t border-gray-200 dark:border-gray-700 pt-4">
          <div className="flex items-center justify-between">
            <h4 className="font-medium">OpenTelemetry Exporter</h4>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={config.logging?.otel?.enabled ?? false}
                onChange={(e) => updateConfig('logging.otel.enabled', e.target.checked)}
                className="h-4 w-4"
              />
              Enabled
            </label>
          </div>

          <div className="grid grid-cols-3 gap-4 mt-4">
            <div>
              <label className="block text-sm font-medium mb-2">Endpoint</label>
              <input
                type="text"
                value={config.logging?.otel?.endpoint ?? ''}
                onChange={(e) => updateConfig('logging.otel.endpoint', e.target.value)}
                className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                placeholder="serviceradar-otel:4317"
              />
            </div>
            <div>
              <label className="block text-sm font-medium mb-2">Service Name</label>
              <input
                type="text"
                value={config.logging?.otel?.service_name ?? ''}
                onChange={(e) => updateConfig('logging.otel.service_name', e.target.value)}
                className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                placeholder="serviceradar-agent"
              />
            </div>
            <div>
              <label className="block text-sm font-medium mb-2">Batch Timeout</label>
              <input
                type="text"
                value={stringValue(config.logging?.otel?.batch_timeout)}
                onChange={(e) => updateConfig('logging.otel.batch_timeout', e.target.value)}
                className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                placeholder="5s"
              />
            </div>
          </div>

          <div className="flex items-center gap-2 mt-4">
            <input
              id="agent-otel-insecure"
              type="checkbox"
              checked={config.logging?.otel?.insecure ?? false}
              onChange={(e) => updateConfig('logging.otel.insecure', e.target.checked)}
              className="h-4 w-4"
            />
            <label htmlFor="agent-otel-insecure" className="text-sm">Allow Insecure (no TLS)</label>
          </div>

          <div className="mt-4">
            <label className="block text-sm font-medium mb-2">Headers (JSON object)</label>
            <textarea
              value={otelHeadersText}
              onChange={(e) => setOtelHeadersText(e.target.value)}
              onBlur={handleHeadersBlur}
              className="w-full h-32 font-mono text-sm p-2 border border-gray-300 dark:border-gray-600 rounded-md bg-gray-50 dark:bg-gray-900"
              spellCheck={false}
            />
            {otelHeadersError && (
              <p className="text-sm text-red-600 mt-1">{otelHeadersError}</p>
            )}
          </div>

          <div className="grid grid-cols-3 gap-4 mt-4">
            <div>
              <label className="block text-sm font-medium mb-2">TLS CA File</label>
              <input
                type="text"
                value={config.logging?.otel?.tls?.ca_file ?? ''}
                onChange={(e) => updateConfig('logging.otel.tls.ca_file', e.target.value)}
                className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                placeholder="/etc/serviceradar/certs/root.pem"
              />
            </div>
            <div>
              <label className="block text-sm font-medium mb-2">TLS Certificate</label>
              <input
                type="text"
                value={config.logging?.otel?.tls?.cert_file ?? ''}
                onChange={(e) => updateConfig('logging.otel.tls.cert_file', e.target.value)}
                className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                placeholder="/etc/serviceradar/certs/agent.pem"
              />
            </div>
            <div>
              <label className="block text-sm font-medium mb-2">TLS Key</label>
              <input
                type="text"
                value={config.logging?.otel?.tls?.key_file ?? ''}
                onChange={(e) => updateConfig('logging.otel.tls.key_file', e.target.value)}
                className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                placeholder="/etc/serviceradar/certs/agent-key.pem"
              />
            </div>
          </div>
        </div>
      </div>

      <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border border-gray-200 dark:border-gray-700">
        <h3 className="text-lg font-semibold">Agent Security</h3>
        <p className="text-sm text-gray-600 dark:text-gray-400">
          SPIFFE / TLS configuration for the agent control plane.
        </p>
        <div className="mt-4">
          <SecurityFields
            security={config.security}
            onChange={(path, value) => updateConfig(`security.${path}`, value)}
          />
        </div>
      </div>

      <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border border-gray-200 dark:border-gray-700">
        <h3 className="text-lg font-semibold">KV Security</h3>
        <p className="text-sm text-gray-600 dark:text-gray-400">
          Optional override when the agent dials KV with different credentials.
        </p>
        <div className="mt-4">
          <SecurityFields
            security={config.kv_security}
            onChange={(path, value) => updateConfig(`kv_security.${path}`, value)}
          />
        </div>
      </div>
    </div>
  );
}
