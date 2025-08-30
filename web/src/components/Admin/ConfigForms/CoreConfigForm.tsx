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

interface CoreConfig {
  listen_addr: string;
  grpc_addr: string;
  alert_threshold: string;
  known_pollers: string[];
  metrics: {
    enabled: boolean;
    retention: number;
    max_pollers: number;
  };
  database: {
    addresses: string[];
    name: string;
    username: string;
    password: string;
    max_conns: number;
    idle_conns: number;
    tls?: {
      cert_file: string;
      key_file: string;
      ca_file: string;
      server_name: string;
    };
    settings?: Record<string, any>;
  };
  security?: {
    mode: string;
    cert_dir: string;
    role: string;
    server_name: string;
    tls?: {
      cert_file: string;
      key_file: string;
      ca_file: string;
      client_ca_file: string;
      skip_verify: boolean;
    };
  };
  cors?: {
    allowed_origins: string[];
    allow_credentials: boolean;
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
  events?: {
    enabled: boolean;
    stream_name: string;
    subjects: string[];
  };
  auth: {
    jwt_secret: string;
    jwt_expiration: string;
    local_users: Record<string, string>;
  };
  webhooks?: Array<{
    enabled: boolean;
    url: string;
    cooldown: string;
    headers?: Array<{ key: string; value: string }>;
    template?: string;
  }>;
  logging?: {
    level: string;
    debug: boolean;
    output: string;
    time_format: string;
    otel?: {
      enabled: boolean;
      endpoint: string;
      service_name: string;
      batch_timeout: string;
      insecure: boolean;
      headers?: Record<string, string>;
      tls?: {
        cert_file: string;
        key_file: string;
        ca_file: string;
      };
    };
  };
  mcp?: {
    enabled: boolean;
  };
}

interface CoreConfigFormProps {
  config: CoreConfig;
  onChange: (config: CoreConfig) => void;
}

export default function CoreConfigForm({ config, onChange }: CoreConfigFormProps) {
  const updateConfig = (path: string, value: any) => {
    const newConfig = { ...config };
    const keys = path.split('.');
    let current: any = newConfig;
    
    for (let i = 0; i < keys.length - 1; i++) {
      if (!current[keys[i]]) current[keys[i]] = {};
      current = current[keys[i]];
    }
    
    current[keys[keys.length - 1]] = value;
    onChange(newConfig);
  };

  const addToArray = (path: string, value: string) => {
    const current = path.split('.').reduce((obj, key) => obj[key], config) as string[];
    updateConfig(path, [...current, value]);
  };

  const removeFromArray = (path: string, index: number) => {
    const current = path.split('.').reduce((obj, key) => obj[key], config) as string[];
    updateConfig(path, current.filter((_, i) => i !== index));
  };

  return (
    <div className="space-y-6">
      <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border">
        <h3 className="text-lg font-semibold mb-4">Server Configuration</h3>
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Listen Address</label>
            <input
              type="text"
              value={config.listen_addr || ''}
              onChange={(e) => updateConfig('listen_addr', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder=":8090"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">gRPC Address</label>
            <input
              type="text"
              value={config.grpc_addr || ''}
              onChange={(e) => updateConfig('grpc_addr', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder=":50052"
            />
          </div>
        </div>
        <div className="mt-4">
          <label className="block text-sm font-medium mb-2">Alert Threshold</label>
          <input
            type="text"
            value={config.alert_threshold || ''}
            onChange={(e) => updateConfig('alert_threshold', e.target.value)}
            className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            placeholder="5m"
          />
        </div>
      </div>

      <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border">
        <h3 className="text-lg font-semibold mb-4">Database Configuration</h3>
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Database Name</label>
            <input
              type="text"
              value={config.database?.name || ''}
              onChange={(e) => updateConfig('database.name', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Username</label>
            <input
              type="text"
              value={config.database?.username || ''}
              onChange={(e) => updateConfig('database.username', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
        </div>
        <div className="mt-4">
          <label className="block text-sm font-medium mb-2">Database Addresses</label>
          <div className="space-y-2">
            {config.database?.addresses?.map((addr, index) => (
              <div key={index} className="flex gap-2">
                <input
                  type="text"
                  value={addr}
                  onChange={(e) => {
                    const newAddresses = [...(config.database?.addresses || [])];
                    newAddresses[index] = e.target.value;
                    updateConfig('database.addresses', newAddresses);
                  }}
                  className="flex-1 p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                />
                <button
                  onClick={() => removeFromArray('database.addresses', index)}
                  className="px-3 py-2 text-red-600 hover:bg-red-50 dark:hover:bg-red-900 rounded-md"
                >
                  Remove
                </button>
              </div>
            ))}
            <button
              onClick={() => addToArray('database.addresses', '')}
              className="px-3 py-2 text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900 rounded-md"
            >
              Add Address
            </button>
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

      <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border">
        <h3 className="text-lg font-semibold mb-4">Authentication</h3>
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">JWT Expiration</label>
            <input
              type="text"
              value={config.auth?.jwt_expiration || ''}
              onChange={(e) => updateConfig('auth.jwt_expiration', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="24h"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">JWT Secret</label>
            <input
              type="password"
              value={config.auth?.jwt_secret || ''}
              onChange={(e) => updateConfig('auth.jwt_secret', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="Enter JWT secret"
            />
          </div>
        </div>
      </div>

      <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border">
        <h3 className="text-lg font-semibold mb-4">Metrics Configuration</h3>
        <div className="grid grid-cols-3 gap-4">
          <div>
            <label className="flex items-center">
              <input
                type="checkbox"
                checked={config.metrics?.enabled || false}
                onChange={(e) => updateConfig('metrics.enabled', e.target.checked)}
                className="mr-2"
              />
              Enable Metrics
            </label>
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Retention</label>
            <input
              type="number"
              value={config.metrics?.retention || 0}
              onChange={(e) => updateConfig('metrics.retention', parseInt(e.target.value))}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Max Pollers</label>
            <input
              type="number"
              value={config.metrics?.max_pollers || 0}
              onChange={(e) => updateConfig('metrics.max_pollers', parseInt(e.target.value))}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
        </div>
      </div>
    </div>
  );
}