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

interface SyncConfig {
  grpc_addr: string;
  sync_interval: string;
  batch_size: number;
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

interface SyncConfigFormProps {
  config: SyncConfig;
  onChange: (config: SyncConfig) => void;
}

export default function SyncConfigForm({ config, onChange }: SyncConfigFormProps) {
  const updateConfig = (path: string, value: unknown) => {
    const newConfig = { ...config };
    const keys = path.split('.');
    let current: Record<string, unknown> = newConfig as Record<string, unknown>;
    
    for (let i = 0; i < keys.length - 1; i++) {
      if (!current[keys[i]]) current[keys[i]] = {};
      current = current[keys[i]] as Record<string, unknown>;
    }
    
    current[keys[keys.length - 1]] = value;
    onChange(newConfig as SyncConfig);
  };

  return (
    <div className="space-y-6">
      <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border">
        <h3 className="text-lg font-semibold mb-4">Sync Service Configuration</h3>
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">gRPC Address</label>
            <input
              type="text"
              value={config.grpc_addr || ''}
              onChange={(e) => updateConfig('grpc_addr', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder=":50053"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Sync Interval</label>
            <input
              type="text"
              value={config.sync_interval || ''}
              onChange={(e) => updateConfig('sync_interval', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="30s"
            />
          </div>
        </div>
        <div className="mt-4">
          <label className="block text-sm font-medium mb-2">Batch Size</label>
          <input
            type="number"
            value={config.batch_size || 0}
            onChange={(e) => updateConfig('batch_size', parseInt(e.target.value))}
            className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            placeholder="100"
          />
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
        
        {config.nats?.security && (
          <div className="mt-4 space-y-4">
            <h4 className="font-medium">Security Configuration</h4>
            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="block text-sm font-medium mb-2">Security Mode</label>
                <select
                  value={config.nats.security.mode || ''}
                  onChange={(e) => updateConfig('nats.security.mode', e.target.value)}
                  className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                >
                  <option value="">None</option>
                  <option value="tls">TLS</option>
                  <option value="mtls">mTLS</option>
                </select>
              </div>
              <div>
                <label className="block text-sm font-medium mb-2">Role</label>
                <input
                  type="text"
                  value={config.nats.security.role || ''}
                  onChange={(e) => updateConfig('nats.security.role', e.target.value)}
                  className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                  placeholder="sync"
                />
              </div>
            </div>
          </div>
        )}
      </div>

      <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border">
        <h3 className="text-lg font-semibold mb-4">Logging Configuration</h3>
        <div className="grid grid-cols-3 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Log Level</label>
            <select
              value={config.logging?.level || 'info'}
              onChange={(e) => updateConfig('logging.level', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            >
              <option value="debug">Debug</option>
              <option value="info">Info</option>
              <option value="warn">Warning</option>
              <option value="error">Error</option>
            </select>
          </div>
          <div>
            <label className="flex items-center">
              <input
                type="checkbox"
                checked={config.logging?.debug || false}
                onChange={(e) => updateConfig('logging.debug', e.target.checked)}
                className="mr-2"
              />
              Debug Mode
            </label>
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Output</label>
            <select
              value={config.logging?.output || 'stdout'}
              onChange={(e) => updateConfig('logging.output', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            >
              <option value="stdout">Standard Output</option>
              <option value="file">File</option>
              <option value="syslog">Syslog</option>
            </select>
          </div>
        </div>
      </div>
    </div>
  );
}