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

interface PollerConfig {
  id: string;
  name: string;
  interval: string;
  timeout: string;
  max_workers: number;
  targets?: {
    networks: string[];
    exclude: string[];
  };
  checkers?: {
    icmp?: { enabled: boolean; timeout?: string; };
    snmp?: { enabled: boolean; community?: string; timeout?: string; };
    http?: { enabled: boolean; timeout?: string; user_agent?: string; };
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

interface PollerConfigFormProps {
  config: PollerConfig;
  onChange: (config: PollerConfig) => void;
}

export default function PollerConfigForm({ config, onChange }: PollerConfigFormProps) {
  const updateConfig = (path: string, value: unknown) => {
    const newConfig = { ...config };
    const keys = path.split('.');
    let current: Record<string, unknown> = newConfig as Record<string, unknown>;
    
    // Validate keys to prevent prototype pollution
    const dangerousKeys = ['__proto__', 'constructor', 'prototype'];
    for (const key of keys) {
      if (dangerousKeys.includes(key)) {
        console.error(`Attempted to set dangerous property: ${key}`);
        return;
      }
    }
    
    for (let i = 0; i < keys.length - 1; i++) {
      if (!current[keys[i]]) current[keys[i]] = {};
      current = current[keys[i]] as Record<string, unknown>;
    }
    
    current[keys[keys.length - 1]] = value;
    onChange(newConfig as PollerConfig);
  };

  const addToArray = (path: string, value: string) => {
    const current = path.split('.').reduce<unknown>((obj, key) => (obj as Record<string, unknown>)[key], config) as string[];
    updateConfig(path, [...(current || []), value]);
  };

  const removeFromArray = (path: string, index: number) => {
    const current = path.split('.').reduce<unknown>((obj, key) => (obj as Record<string, unknown>)[key], config) as string[];
    updateConfig(path, (current || []).filter((_, i) => i !== index));
  };

  return (
    <div className="space-y-6">
      <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border">
        <h3 className="text-lg font-semibold mb-4">Poller Configuration</h3>
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Poller ID</label>
            <input
              type="text"
              value={config.id || ''}
              onChange={(e) => updateConfig('id', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="unique-poller-id"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Poller Name</label>
            <input
              type="text"
              value={config.name || ''}
              onChange={(e) => updateConfig('name', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="My Poller"
            />
          </div>
        </div>
        <div className="grid grid-cols-3 gap-4 mt-4">
          <div>
            <label className="block text-sm font-medium mb-2">Poll Interval</label>
            <input
              type="text"
              value={config.interval || ''}
              onChange={(e) => updateConfig('interval', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="60s"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Timeout</label>
            <input
              type="text"
              value={config.timeout || ''}
              onChange={(e) => updateConfig('timeout', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="30s"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Max Workers</label>
            <input
              type="number"
              value={config.max_workers || 0}
              onChange={(e) => updateConfig('max_workers', parseInt(e.target.value))}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="10"
            />
          </div>
        </div>
      </div>

      <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border">
        <h3 className="text-lg font-semibold mb-4">Target Networks</h3>
        <div>
          <label className="block text-sm font-medium mb-2">Networks to Monitor</label>
          <div className="space-y-2">
            {config.targets?.networks?.map((network, index) => (
              <div key={index} className="flex gap-2">
                <input
                  type="text"
                  value={network}
                  onChange={(e) => {
                    const newNetworks = [...(config.targets?.networks || [])];
                    newNetworks[index] = e.target.value;
                    updateConfig('targets.networks', newNetworks);
                  }}
                  className="flex-1 p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                  placeholder="192.168.1.0/24"
                />
                <button
                  onClick={() => removeFromArray('targets.networks', index)}
                  className="px-3 py-2 text-red-600 hover:bg-red-50 dark:hover:bg-red-900 rounded-md"
                >
                  Remove
                </button>
              </div>
            ))}
            <button
              onClick={() => addToArray('targets.networks', '')}
              className="px-3 py-2 text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900 rounded-md"
            >
              Add Network
            </button>
          </div>
        </div>

        <div className="mt-4">
          <label className="block text-sm font-medium mb-2">Exclude Networks</label>
          <div className="space-y-2">
            {config.targets?.exclude?.map((exclude, index) => (
              <div key={index} className="flex gap-2">
                <input
                  type="text"
                  value={exclude}
                  onChange={(e) => {
                    const newExcludes = [...(config.targets?.exclude || [])];
                    newExcludes[index] = e.target.value;
                    updateConfig('targets.exclude', newExcludes);
                  }}
                  className="flex-1 p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                  placeholder="192.168.1.1"
                />
                <button
                  onClick={() => removeFromArray('targets.exclude', index)}
                  className="px-3 py-2 text-red-600 hover:bg-red-50 dark:hover:bg-red-900 rounded-md"
                >
                  Remove
                </button>
              </div>
            ))}
            <button
              onClick={() => addToArray('targets.exclude', '')}
              className="px-3 py-2 text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900 rounded-md"
            >
              Add Exclusion
            </button>
          </div>
        </div>
      </div>

      <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border">
        <h3 className="text-lg font-semibold mb-4">Checkers Configuration</h3>
        <div className="space-y-4">
          <div className="flex items-center justify-between p-3 border border-gray-200 dark:border-gray-600 rounded-md">
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

          <div className="flex items-center justify-between p-3 border border-gray-200 dark:border-gray-600 rounded-md">
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

          <div className="flex items-center justify-between p-3 border border-gray-200 dark:border-gray-600 rounded-md">
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