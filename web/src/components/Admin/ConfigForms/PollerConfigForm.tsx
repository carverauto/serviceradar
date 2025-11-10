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

type TLSConfig = {
  cert_file?: string;
  key_file?: string;
  ca_file?: string;
  client_ca_file?: string;
};

type SecurityConfig = {
  mode?: string;
  cert_dir?: string;
  server_name?: string;
  role?: string;
  server_spiffe_id?: string;
  trust_domain?: string;
  workload_socket?: string;
  tls?: TLSConfig;
};

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

type PollerCheck = {
  service_name?: string;
  service_type?: string;
  details?: string;
  port?: number;
  results_interval?: string | number | null;
};

type PollerAgentConfig = {
  address?: string;
  security?: SecurityConfig | null;
  checks?: PollerCheck[];
};

interface PollerConfig {
  poller_id?: string;
  service_name?: string;
  service_type?: string;
  listen_addr?: string;
  core_address?: string;
  poll_interval?: string | number;
  partition?: string;
  source_ip?: string;
  kv_address?: string;
  kv_domain?: string;
  agents?: Record<string, PollerAgentConfig>;
  logging?: LoggingConfig;
  security?: SecurityConfig | null;
}

interface PollerConfigFormProps {
  config: PollerConfig;
  onChange: (config: PollerConfig) => void;
}

const stringValue = (value?: string | number | null) =>
  value === undefined || value === null ? '' : String(value);

interface SecurityFieldsProps {
  security?: SecurityConfig | null;
  onChange: (path: string, value: unknown) => void;
}

const securityRoles = [
  { label: 'Poller', value: 'poller' },
  { label: 'Agent', value: 'agent' },
  { label: 'Core', value: 'core' },
  { label: 'KV Store', value: 'kv' },
  { label: 'Data Service', value: 'datasvc' },
  { label: 'Checker', value: 'checker' },
];

const SecurityFields = ({ security, onChange }: SecurityFieldsProps) => (
  <div className="space-y-4">
    <div className="grid grid-cols-2 gap-4">
      <div>
        <label className="block text-sm font-medium mb-2">Mode</label>
        <select
          value={security?.mode ?? ''}
          onChange={(e) => onChange('mode', e.target.value)}
          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
        >
          <option value="">Not Configured</option>
          <option value="none">None</option>
          <option value="tls">TLS</option>
          <option value="mtls">mTLS</option>
          <option value="spiffe">SPIFFE</option>
        </select>
      </div>
      <div>
        <label className="block text-sm font-medium mb-2">Role</label>
        <select
          value={security?.role ?? ''}
          onChange={(e) => onChange('role', e.target.value)}
          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
        >
          <option value="">Not Set</option>
          {securityRoles.map((role) => (
            <option key={role.value} value={role.value}>
              {role.label}
            </option>
          ))}
        </select>
      </div>
    </div>

    <div className="grid grid-cols-2 gap-4">
      <div>
        <label className="block text-sm font-medium mb-2">Certificate Directory</label>
        <input
          type="text"
          value={security?.cert_dir ?? ''}
          onChange={(e) => onChange('cert_dir', e.target.value)}
          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
          placeholder="/etc/serviceradar/certs"
        />
      </div>
      <div>
        <label className="block text-sm font-medium mb-2">Server Name</label>
        <input
          type="text"
          value={security?.server_name ?? ''}
          onChange={(e) => onChange('server_name', e.target.value)}
          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
          placeholder="serviceradar-core"
        />
      </div>
    </div>

    <div className="grid grid-cols-3 gap-4">
      <div>
        <label className="block text-sm font-medium mb-2">Server SPIFFE ID</label>
        <input
          type="text"
          value={security?.server_spiffe_id ?? ''}
          onChange={(e) => onChange('server_spiffe_id', e.target.value)}
          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
          placeholder="spiffe://..."
        />
      </div>
      <div>
        <label className="block text-sm font-medium mb-2">Trust Domain</label>
        <input
          type="text"
          value={security?.trust_domain ?? ''}
          onChange={(e) => onChange('trust_domain', e.target.value)}
          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
          placeholder="carverauto.dev"
        />
      </div>
      <div>
        <label className="block text-sm font-medium mb-2">Workload Socket</label>
        <input
          type="text"
          value={security?.workload_socket ?? ''}
          onChange={(e) => onChange('workload_socket', e.target.value)}
          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
          placeholder="unix:/run/spire/sockets/agent.sock"
        />
      </div>
    </div>

    <div className="grid grid-cols-2 gap-4">
      <div>
        <label className="block text-sm font-medium mb-2">TLS CA File</label>
        <input
          type="text"
          value={security?.tls?.ca_file ?? ''}
          onChange={(e) => onChange('tls.ca_file', e.target.value)}
          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
          placeholder="root.pem"
        />
      </div>
      <div>
        <label className="block text-sm font-medium mb-2">TLS Client CA File</label>
        <input
          type="text"
          value={security?.tls?.client_ca_file ?? ''}
          onChange={(e) => onChange('tls.client_ca_file', e.target.value)}
          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
          placeholder="root.pem"
        />
      </div>
    </div>

    <div className="grid grid-cols-2 gap-4">
      <div>
        <label className="block text-sm font-medium mb-2">TLS Certificate File</label>
        <input
          type="text"
          value={security?.tls?.cert_file ?? ''}
          onChange={(e) => onChange('tls.cert_file', e.target.value)}
          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
          placeholder="poller.pem"
        />
      </div>
      <div>
        <label className="block text-sm font-medium mb-2">TLS Key File</label>
        <input
          type="text"
          value={security?.tls?.key_file ?? ''}
          onChange={(e) => onChange('tls.key_file', e.target.value)}
          className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
          placeholder="poller-key.pem"
        />
      </div>
    </div>
  </div>
);

export default function PollerConfigForm({ config, onChange }: PollerConfigFormProps) {
  const updateConfig = (path: string, value: unknown) => {
    const next = { ...config };
    safeSet(next as Record<string, unknown>, path, value);
    onChange(next as PollerConfig);
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
      if (!parsed || Array.isArray(parsed) || typeof parsed !== 'object') {
        throw new Error('Headers must be an object');
      }
      updateConfig('logging.otel.headers', parsed);
      setOtelHeadersError(null);
    } catch {
      setOtelHeadersError('Headers must be a JSON object (e.g. {"x-api-key":"secret"})');
    }
  };

  const setAgents = (agents: Record<string, PollerAgentConfig>) => {
    const next = { ...config };
    if (Object.keys(agents).length === 0) {
      delete next.agents;
    } else {
      next.agents = agents;
    }
    onChange(next);
  };

  const updateAgent = (agentId: string, path: string, value: unknown) => {
    const agents = { ...(config.agents ?? {}) };
    const current = { ...(agents[agentId] ?? {}) };
    safeSet(current as Record<string, unknown>, path, value);
    agents[agentId] = current;
    setAgents(agents);
  };

  const handleAddAgent = () => {
    const agents = { ...(config.agents ?? {}) };
    let index = Object.keys(agents).length + 1;
    let candidate = `agent-${index}`;
    while (agents[candidate]) {
      index += 1;
      candidate = `agent-${index}`;
    }
    agents[candidate] = { address: '', checks: [] };
    setAgents(agents);
  };

  const handleRemoveAgent = (agentId: string) => {
    const agents = { ...(config.agents ?? {}) };
    delete agents[agentId];
    setAgents(agents);
  };

  const handleAddCheck = (agentId: string) => {
    const agents = { ...(config.agents ?? {}) };
    const agent = { ...(agents[agentId] ?? {}) };
    const checks = Array.isArray(agent.checks) ? [...agent.checks] : [];
    checks.push({ service_name: '', service_type: '', details: '' });
    agent.checks = checks;
    agents[agentId] = agent;
    setAgents(agents);
  };

  const handleCheckChange = (agentId: string, index: number, field: keyof PollerCheck, value: unknown) => {
    const agents = { ...(config.agents ?? {}) };
    const agent = { ...(agents[agentId] ?? {}) };
    const checks = Array.isArray(agent.checks) ? [...agent.checks] : [];
    const current = { ...(checks[index] ?? {}) };
    safeSet(current as Record<string, unknown>, field, value);
    checks[index] = current;
    agent.checks = checks;
    agents[agentId] = agent;
    setAgents(agents);
  };

  const handleRemoveCheck = (agentId: string, index: number) => {
    const agents = { ...(config.agents ?? {}) };
    const agent = { ...(agents[agentId] ?? {}) };
    const checks = Array.isArray(agent.checks) ? [...agent.checks] : [];
    checks.splice(index, 1);
    agent.checks = checks;
    agents[agentId] = agent;
    setAgents(agents);
  };

  const agentEntries = Object.entries(config.agents ?? {});

  return (
    <div className="space-y-6">
      <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border border-gray-200 dark:border-gray-700">
        <h3 className="text-lg font-semibold">Poller Service</h3>
        <p className="text-sm text-gray-600 dark:text-gray-400">Identity and runtime settings for this poller.</p>

        <div className="grid grid-cols-2 gap-4 mt-4">
          <div>
            <label className="block text-sm font-medium mb-2">Poller ID</label>
            <input
              type="text"
              value={config.poller_id ?? ''}
              onChange={(e) => updateConfig('poller_id', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="k8s-poller"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Service Name</label>
            <input
              type="text"
              value={config.service_name ?? ''}
              onChange={(e) => updateConfig('service_name', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="PollerService"
            />
          </div>
        </div>

        <div className="grid grid-cols-3 gap-4 mt-4">
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
          <div>
            <label className="block text-sm font-medium mb-2">Poll Interval</label>
            <input
              type="text"
              value={stringValue(config.poll_interval)}
              onChange={(e) => updateConfig('poll_interval', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="30s"
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

        <div className="grid grid-cols-3 gap-4 mt-4">
          <div>
            <label className="block text-sm font-medium mb-2">Source IP</label>
            <input
              type="text"
              value={config.source_ip ?? ''}
              onChange={(e) => updateConfig('source_ip', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="poller"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Listen Address</label>
            <input
              type="text"
              value={config.listen_addr ?? ''}
              onChange={(e) => updateConfig('listen_addr', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder=":50053"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Core Address</label>
            <input
              type="text"
              value={config.core_address ?? ''}
              onChange={(e) => updateConfig('core_address', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="serviceradar-core:50052"
            />
          </div>
        </div>

        <div className="grid grid-cols-3 gap-4 mt-4">
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
          <div>
            <label className="block text-sm font-medium mb-2">KV Domain</label>
            <input
              type="text"
              value={config.kv_domain ?? ''}
              onChange={(e) => updateConfig('kv_domain', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="hub"
            />
          </div>
          <div />
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
              id="poller-logging-debug"
              type="checkbox"
              checked={config.logging?.debug ?? false}
              onChange={(e) => updateConfig('logging.debug', e.target.checked)}
              className="h-4 w-4"
            />
            <label htmlFor="poller-logging-debug" className="text-sm">Enable Debug Output</label>
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
                placeholder="serviceradar-poller"
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
              id="poller-otel-insecure"
              type="checkbox"
              checked={config.logging?.otel?.insecure ?? false}
              onChange={(e) => updateConfig('logging.otel.insecure', e.target.checked)}
              className="h-4 w-4"
            />
            <label htmlFor="poller-otel-insecure" className="text-sm">Allow Insecure (no TLS)</label>
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
                placeholder="/etc/serviceradar/certs/poller.pem"
              />
            </div>
            <div>
              <label className="block text-sm font-medium mb-2">TLS Key</label>
              <input
                type="text"
                value={config.logging?.otel?.tls?.key_file ?? ''}
                onChange={(e) => updateConfig('logging.otel.tls.key_file', e.target.value)}
                className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                placeholder="/etc/serviceradar/certs/poller-key.pem"
              />
            </div>
          </div>
        </div>
      </div>

      <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border border-gray-200 dark:border-gray-700">
        <h3 className="text-lg font-semibold">Poller Security</h3>
        <p className="text-sm text-gray-600 dark:text-gray-400">SPIFFE / TLS configuration for the poller itself.</p>
        <div className="mt-4">
          <SecurityFields
            security={config.security}
            onChange={(path, value) => updateConfig(`security.${path}`, value)}
          />
        </div>
      </div>

      <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border border-gray-200 dark:border-gray-700">
        <div className="flex items-center justify-between">
          <div>
            <h3 className="text-lg font-semibold">Agents & Checks</h3>
            <p className="text-sm text-gray-600 dark:text-gray-400">
              Configure each remote agent and the checks it should run.
            </p>
          </div>
          <button
            type="button"
            onClick={handleAddAgent}
            className="px-3 py-2 text-sm font-medium text-blue-600 hover:text-blue-700"
          >
            + Add Agent
          </button>
        </div>

        <div className="mt-4 space-y-4">
          {agentEntries.length === 0 && (
            <div className="text-sm text-gray-500 dark:text-gray-400 border border-dashed border-gray-300 dark:border-gray-600 rounded-md p-4">
              No agents defined. Add an agent to begin assigning checks.
            </div>
          )}

          {agentEntries.map(([agentId, agentConfig]) => {
            const checks = Array.isArray(agentConfig?.checks) ? agentConfig.checks : [];
            return (
              <div key={agentId} className="border border-gray-200 dark:border-gray-700 rounded-lg p-4 space-y-4">
                <div className="flex items-center justify-between">
                  <div>
                    <p className="text-xs uppercase text-gray-500 dark:text-gray-400">Agent ID</p>
                    <code className="text-sm break-all">{agentId}</code>
                  </div>
                  <button
                    type="button"
                    onClick={() => handleRemoveAgent(agentId)}
                    className="text-sm text-red-600 hover:text-red-700"
                  >
                    Remove Agent
                  </button>
                </div>

                <div className="grid grid-cols-2 gap-4">
                  <div>
                    <label className="block text-sm font-medium mb-2">Agent Address</label>
                    <input
                      type="text"
                      value={agentConfig?.address ?? ''}
                      onChange={(e) => updateAgent(agentId, 'address', e.target.value)}
                      className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                      placeholder="serviceradar-agent:50051"
                    />
                  </div>
                </div>

                <div>
                  <h4 className="text-sm font-medium mb-2">Agent Security</h4>
                  <SecurityFields
                    security={agentConfig?.security}
                    onChange={(path, value) => updateAgent(agentId, `security.${path}`, value)}
                  />
                </div>

                <div>
                  <div className="flex items-center justify-between">
                    <h4 className="text-sm font-medium">Checks</h4>
                    <button
                      type="button"
                      onClick={() => handleAddCheck(agentId)}
                      className="text-sm text-blue-600 hover:text-blue-700"
                    >
                      + Add Check
                    </button>
                  </div>
                  <div className="mt-3 space-y-3">
                    {checks.length === 0 && (
                      <div className="text-sm text-gray-500 dark:text-gray-400 border border-dashed border-gray-300 dark:border-gray-600 rounded-md p-3">
                        No checks configured for this agent.
                      </div>
                    )}
                    {checks.map((check, index) => (
                      <div
                        key={`${agentId}-check-${index}`}
                        className="border border-gray-200 dark:border-gray-700 rounded-md p-3 space-y-3"
                      >
                        <div className="flex items-center justify-between">
                          <span className="text-sm font-medium">Check #{index + 1}</span>
                          <button
                            type="button"
                            onClick={() => handleRemoveCheck(agentId, index)}
                            className="text-xs text-red-600 hover:text-red-700"
                          >
                            Remove
                          </button>
                        </div>
                        <div className="grid grid-cols-2 gap-3">
                          <div>
                            <label className="block text-xs font-medium mb-1">Service Name</label>
                            <input
                              type="text"
                              value={check?.service_name ?? ''}
                              onChange={(e) => handleCheckChange(agentId, index, 'service_name', e.target.value)}
                              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                              placeholder="serviceradar-agent"
                            />
                          </div>
                          <div>
                            <label className="block text-xs font-medium mb-1">Service Type</label>
                            <input
                              type="text"
                              value={check?.service_type ?? ''}
                              onChange={(e) => handleCheckChange(agentId, index, 'service_type', e.target.value)}
                              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                              placeholder="grpc / icmp / sweep"
                            />
                          </div>
                        </div>
                        <div className="grid grid-cols-3 gap-3">
                          <div className="col-span-2">
                            <label className="block text-xs font-medium mb-1">Details</label>
                            <input
                              type="text"
                              value={check?.details ?? ''}
                              onChange={(e) => handleCheckChange(agentId, index, 'details', e.target.value)}
                              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                              placeholder="serviceradar-agent:22"
                            />
                          </div>
                          <div>
                            <label className="block text-xs font-medium mb-1">Port</label>
                            <input
                              type="number"
                              value={check?.port ?? ''}
                              onChange={(e) =>
                                handleCheckChange(
                                  agentId,
                                  index,
                                  'port',
                                  e.target.value === '' ? undefined : Number(e.target.value),
                                )
                              }
                              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                              placeholder="0"
                            />
                          </div>
                        </div>
                        <div>
                          <label className="block text-xs font-medium mb-1">Results Interval</label>
                          <input
                            type="text"
                            value={stringValue(check?.results_interval)}
                            onChange={(e) =>
                              handleCheckChange(
                                agentId,
                                index,
                                'results_interval',
                                e.target.value.trim() ? e.target.value : null,
                              )
                            }
                            className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                            placeholder="5m0s"
                          />
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
