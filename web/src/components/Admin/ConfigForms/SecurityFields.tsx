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

export type TLSConfig = {
  cert_file?: string;
  key_file?: string;
  ca_file?: string;
  client_ca_file?: string;
};

export type SecurityConfig = {
  mode?: string;
  cert_dir?: string;
  server_name?: string;
  role?: string;
  server_spiffe_id?: string;
  trust_domain?: string;
  workload_socket?: string;
  tls?: TLSConfig;
};

type SecurityRole = { label: string; value: string };

const DEFAULT_ROLES: SecurityRole[] = [
  { label: 'Poller', value: 'poller' },
  { label: 'Agent', value: 'agent' },
  { label: 'Core', value: 'core' },
  { label: 'KV Store', value: 'kv' },
  { label: 'Data Service', value: 'datasvc' },
  { label: 'Checker', value: 'checker' },
];

interface SecurityFieldsProps {
  security?: SecurityConfig | null;
  onChange: (path: string, value: unknown) => void;
  roles?: SecurityRole[];
}

export default function SecurityFields({ security, onChange, roles = DEFAULT_ROLES }: SecurityFieldsProps) {
  return (
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
            {roles.map((role) => (
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
            placeholder="service.pem"
          />
        </div>
        <div>
          <label className="block text-sm font-medium mb-2">TLS Key File</label>
          <input
            type="text"
            value={security?.tls?.key_file ?? ''}
            onChange={(e) => onChange('tls.key_file', e.target.value)}
            className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            placeholder="service-key.pem"
          />
        </div>
      </div>
    </div>
  );
}

export { DEFAULT_ROLES as DefaultSecurityRoles };
