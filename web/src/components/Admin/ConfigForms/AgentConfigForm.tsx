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

import React from 'react';

interface AgentConfig {
  id: string;
  name: string;
  poller_id: string;
  checkers: {
    icmp?: { enabled: boolean; timeout?: string; };
    snmp?: { enabled: boolean; community?: string; timeout?: string; };
    http?: { enabled: boolean; timeout?: string; user_agent?: string; };
    sysmon?: { enabled: boolean; interval?: string; };
  };
  nats: {
    url: string;
    security?: {
      mode: string;
      cert_dir: string;
      server_name: string;
      role: string;
      tls?: {
        cert_file: string;
        key_file: string;
        ca_file: string;
        client_ca_file: string;
      };
    };
  };
  logging?: {
    level: string;
    debug: boolean;
    output: string;
  };
}

interface AgentConfigFormProps {
  config: AgentConfig;
  onChange: (config: AgentConfig) => void;
}

export default function AgentConfigForm({ config, onChange }: AgentConfigFormProps) {
  const updateConfig = (path: string, value: unknown) => {
    const newConfig = { ...config };
    const keys = path.split('.');
    let current: Record<string, unknown> = newConfig as Record<string, unknown>;
    
    for (let i = 0; i < keys.length - 1; i++) {
      if (!current[keys[i]]) current[keys[i]] = {};
      current = current[keys[i]] as Record<string, unknown>;
    }
    
    current[keys[keys.length - 1]] = value;
    onChange(newConfig as AgentConfig);
  };

  return (
    <div className="space-y-6">
      <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border">
        <h3 className="text-lg font-semibold mb-4">Agent Configuration</h3>
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Agent ID</label>
            <input
              type="text"
              value={config.id || ''}
              onChange={(e) => updateConfig('id', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="unique-agent-id"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Agent Name</label>
            <input
              type="text"
              value={config.name || ''}
              onChange={(e) => updateConfig('name', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="My Agent"
            />
          </div>
        </div>
        <div className="mt-4">
          <label className="block text-sm font-medium mb-2">Associated Poller ID</label>
          <input
            type="text"
            value={config.poller_id || ''}
            onChange={(e) => updateConfig('poller_id', e.target.value)}
            className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            placeholder="poller-id"
          />
        </div>
      </div>

      <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border">
        <h3 className="text-lg font-semibold mb-4">Checkers Configuration</h3>
        <div className="space-y-4">
          <div className="border border-gray-200 dark:border-gray-600 rounded-md p-4">
            <div className="flex items-center justify-between mb-3">
              <div>
                <span className="font-medium">ICMP Checker</span>
                <p className="text-sm text-gray-600 dark:text-gray-400">Ping-based availability checks</p>
              </div>
              <label className="flex items-center">
                <input
                  type="checkbox"
                  checked={config.checkers?.icmp?.enabled || false}
                  onChange={(e) => updateConfig('checkers.icmp.enabled', e.target.checked)}
                  className="mr-2"
                />
                Enable
              </label>
            </div>
            {config.checkers?.icmp?.enabled && (
              <div>
                <label className="block text-sm font-medium mb-2">Timeout</label>
                <input
                  type="text"
                  value={config.checkers.icmp.timeout || ''}
                  onChange={(e) => updateConfig('checkers.icmp.timeout', e.target.value)}
                  className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                  placeholder="5s"
                />
              </div>
            )}
          </div>

          <div className="border border-gray-200 dark:border-gray-600 rounded-md p-4">
            <div className="flex items-center justify-between mb-3">
              <div>
                <span className="font-medium">SNMP Checker</span>
                <p className="text-sm text-gray-600 dark:text-gray-400">SNMP-based device monitoring</p>
              </div>
              <label className="flex items-center">
                <input
                  type="checkbox"
                  checked={config.checkers?.snmp?.enabled || false}
                  onChange={(e) => updateConfig('checkers.snmp.enabled', e.target.checked)}
                  className="mr-2"
                />
                Enable
              </label>
            </div>
            {config.checkers?.snmp?.enabled && (
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium mb-2">Community String</label>
                  <input
                    type="text"
                    value={config.checkers.snmp.community || ''}
                    onChange={(e) => updateConfig('checkers.snmp.community', e.target.value)}
                    className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                    placeholder="public"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium mb-2">Timeout</label>
                  <input
                    type="text"
                    value={config.checkers.snmp.timeout || ''}
                    onChange={(e) => updateConfig('checkers.snmp.timeout', e.target.value)}
                    className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                    placeholder="10s"
                  />
                </div>
              </div>
            )}
          </div>

          <div className="border border-gray-200 dark:border-gray-600 rounded-md p-4">
            <div className="flex items-center justify-between mb-3">
              <div>
                <span className="font-medium">HTTP Checker</span>
                <p className="text-sm text-gray-600 dark:text-gray-400">HTTP/HTTPS endpoint monitoring</p>
              </div>
              <label className="flex items-center">
                <input
                  type="checkbox"
                  checked={config.checkers?.http?.enabled || false}
                  onChange={(e) => updateConfig('checkers.http.enabled', e.target.checked)}
                  className="mr-2"
                />
                Enable
              </label>
            </div>
            {config.checkers?.http?.enabled && (
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium mb-2">User Agent</label>
                  <input
                    type="text"
                    value={config.checkers.http.user_agent || ''}
                    onChange={(e) => updateConfig('checkers.http.user_agent', e.target.value)}
                    className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                    placeholder="ServiceRadar/1.0"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium mb-2">Timeout</label>
                  <input
                    type="text"
                    value={config.checkers.http.timeout || ''}
                    onChange={(e) => updateConfig('checkers.http.timeout', e.target.value)}
                    className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                    placeholder="10s"
                  />
                </div>
              </div>
            )}
          </div>

          <div className="border border-gray-200 dark:border-gray-600 rounded-md p-4">
            <div className="flex items-center justify-between mb-3">
              <div>
                <span className="font-medium">System Monitoring</span>
                <p className="text-sm text-gray-600 dark:text-gray-400">System resource monitoring</p>
              </div>
              <label className="flex items-center">
                <input
                  type="checkbox"
                  checked={config.checkers?.sysmon?.enabled || false}
                  onChange={(e) => updateConfig('checkers.sysmon.enabled', e.target.checked)}
                  className="mr-2"
                />
                Enable
              </label>
            </div>
            {config.checkers?.sysmon?.enabled && (
              <div>
                <label className="block text-sm font-medium mb-2">Check Interval</label>
                <input
                  type="text"
                  value={config.checkers.sysmon.interval || ''}
                  onChange={(e) => updateConfig('checkers.sysmon.interval', e.target.value)}
                  className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                  placeholder="30s"
                />
              </div>
            )}
          </div>
        </div>
      </div>

      <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border">
        <h3 className="text-lg font-semibold mb-4">NATS Configuration</h3>
        <div>
          <label className="block text-sm font-medium mb-2">NATS URL</label>
          <input
            type="text"
            value={config.nats?.url || ''}
            onChange={(e) => updateConfig('nats.url', e.target.value)}
            className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            placeholder="nats://127.0.0.1:4222"
          />
        </div>
      </div>
    </div>
  );
}