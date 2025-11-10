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

type ServiceSecurityConfig = {
  mode?: string;
  cert_dir?: string;
  role?: string;
  server_name?: string;
  server_spiffe_id?: string;
  trust_domain?: string;
  workload_socket?: string;
  tls?: TLSConfig;
};

type RBACConfig = {
  role_permissions?: Record<string, string[]>;
  route_protection?: Record<string, unknown>;
  user_roles?: Record<string, string[]>;
};

type AuthConfig = {
  callback_url?: string;
  jwt_algorithm?: string;
  jwt_expiration?: string;
  jwt_key_id?: string;
  jwt_public_key_pem?: string;
  jwt_private_key_pem?: string;
  jwt_secret?: string;
  local_users?: Record<string, string>;
  sso_providers?: Record<string, unknown>;
  rbac?: RBACConfig;
};

type DatabaseConfig = {
  addresses?: string[];
  name?: string;
  username?: string;
  password?: string;
  max_conns?: number;
  idle_conns?: number;
  tls?: TLSConfig;
  settings?: Record<string, unknown>;
};

type EventsConfig = {
  enabled?: boolean;
  stream_name?: string;
  subjects?: string[];
};

type FeatureFlags = {
  require_device_registry?: boolean | null;
  use_device_search_planner?: boolean | null;
  use_log_digest?: boolean | null;
  use_stats_cache?: boolean | null;
};

type MetricsConfig = {
  enabled?: boolean;
  retention?: number;
  max_pollers?: number;
};

type OTelConfig = {
  enabled?: boolean;
  endpoint?: string;
  service_name?: string;
  batch_timeout?: string;
  insecure?: boolean;
  headers?: Record<string, string>;
  tls?: {
    cert_file?: string;
    key_file?: string;
    ca_file?: string;
  };
};

type LoggingConfig = {
  level?: string;
  debug?: boolean;
  output?: string;
  time_format?: string;
  otel?: OTelConfig;
};

type EdgeOnboardingConfig = {
  enabled?: boolean;
  encryption_key?: string;
  default_selectors?: string[];
  default_metadata?: Record<string, Record<string, string>>;
  downstream_path_template?: string;
  join_token_ttl?: string | number;
  download_token_ttl?: string | number;
  poller_id_prefix?: string;
};

type SpireAdminConfig = {
  enabled?: boolean;
  server_address?: string;
  server_spiffe_id?: string;
  workload_socket?: string;
  bundle_path?: string;
  join_token_ttl?: string | number;
};

type SRQLConfig = {
  enabled?: boolean;
  base_url?: string;
  api_key?: string;
  timeout?: string;
  path?: string;
};

type MCPConfig = {
  enabled?: boolean;
  api_key?: string;
} | null;

type KVEndpoint = {
  id?: string;
  name?: string;
  address?: string;
  domain?: string;
  type?: string;
};

type WebhookHeader = {
  key: string;
  value: string;
};

type WebhookConfig = {
  enabled?: boolean;
  url?: string;
  cooldown?: string;
  headers?: WebhookHeader[];
  template?: string;
};

type CORSConfig = {
  allowed_origins?: string[];
  allow_credentials?: boolean;
};

type NATSConfig = {
  url?: string;
  domain?: string;
  security?: ServiceSecurityConfig | null;
};

type SNMPTarget = Record<string, unknown>;

type SNMPConfig = {
  listen_addr?: string;
  node_address?: string;
  timeout?: string | number;
  security?: ServiceSecurityConfig | null;
  targets?: SNMPTarget[];
};

type WriteBufferConfig = {
  enabled?: boolean;
  flush_interval?: string | number;
  max_size?: number;
};

interface CoreConfig {
  listen_addr?: string;
  grpc_addr?: string;
  alert_threshold?: string;
  known_pollers?: string[];
  poller_patterns?: string[];
  metrics?: MetricsConfig;
  database?: DatabaseConfig;
  cors?: CORSConfig;
  nats?: NATSConfig;
  events?: EventsConfig;
  auth?: AuthConfig;
  webhooks?: WebhookConfig[];
  logging?: LoggingConfig;
  mcp?: MCPConfig;
  features?: FeatureFlags;
  kv_endpoints?: KVEndpoint[];
  security?: ServiceSecurityConfig | null;
  kv_security?: ServiceSecurityConfig | null;
  snmp?: SNMPConfig;
  edge_onboarding?: EdgeOnboardingConfig;
  spire_admin?: SpireAdminConfig;
  srql?: SRQLConfig;
  write_buffer?: WriteBufferConfig;
  db_addr?: string;
  db_name?: string;
  db_user?: string;
  db_pass?: string;
  db_path?: string;
}

interface CoreConfigFormProps {
  config: CoreConfig;
  onChange: (config: CoreConfig) => void;
}

interface SectionProps {
  title: string;
  description?: string;
  children: React.ReactNode;
}

const Section = ({ title, description, children }: SectionProps) => (
  <div className="bg-white dark:bg-gray-800 p-6 rounded-lg border space-y-4">
    <div>
      <h3 className="text-lg font-semibold">{title}</h3>
      {description && (
        <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">{description}</p>
      )}
    </div>
    {children}
  </div>
);

interface StringArrayEditorProps {
  label: string;
  values?: Array<string | null> | null;
  onChange: (values: string[]) => void;
  addLabel?: string;
  placeholder?: string;
  description?: string;
}

const StringArrayEditor = ({
  label,
  values,
  onChange,
  addLabel,
  placeholder,
  description,
}: StringArrayEditorProps) => {
  const list = Array.isArray(values) ? values : [];

  return (
    <div className="space-y-2">
      <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">{label}</label>
      {description && (
        <p className="text-sm text-gray-500 dark:text-gray-400">{description}</p>
      )}
      <div className="space-y-2">
        {list.map((value, index) => (
          <div key={`${label}-${index}`} className="flex gap-2">
            <input
              type="text"
              value={value ?? ''}
              onChange={(e) => {
                const next = [...list];
                next[index] = e.target.value;
                onChange(next.map((entry) => entry ?? ''));
              }}
              className="flex-1 p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder={placeholder}
            />
            <button
              type="button"
              onClick={() => {
                const next = list.filter((_, i) => i !== index);
                onChange(next.map((entry) => entry ?? ''));
              }}
              className="px-3 py-2 text-red-600 hover:bg-red-50 dark:hover:bg-red-900 rounded-md"
            >
              Remove
            </button>
          </div>
        ))}
        <button
          type="button"
          onClick={() => onChange([...list.map((entry) => entry ?? ''), ''])}
          className="px-3 py-2 text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900 rounded-md"
        >
          {addLabel ?? 'Add Entry'}
        </button>
      </div>
    </div>
  );
};

interface JsonTextAreaProps {
  label: string;
  value: string;
  onChange: (value: string) => void;
  onBlur: () => void;
  error?: string | null;
  description?: string;
  rows?: number;
}

const JsonTextArea = ({
  label,
  value,
  onChange,
  onBlur,
  error,
  description,
  rows = 6,
}: JsonTextAreaProps) => (
  <div className="space-y-2">
    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">{label}</label>
    {description && (
      <p className="text-sm text-gray-500 dark:text-gray-400">{description}</p>
    )}
    <textarea
      value={value}
      onChange={(e) => onChange(e.target.value)}
      onBlur={onBlur}
      rows={rows}
      spellCheck={false}
      className="w-full font-mono text-sm p-2 border border-gray-300 dark:border-gray-600 rounded-md bg-gray-50 dark:bg-gray-900"
    />
    {error && <p className="text-sm text-red-600">{error}</p>}
  </div>
);

interface SecurityFieldsProps {
  title: string;
  path: string;
  data?: ServiceSecurityConfig | null;
  updateConfig: (path: string, value: unknown) => void;
}

const SecurityFields = ({ title, path, data, updateConfig }: SecurityFieldsProps) => {
  const security = data ?? {};
  const tls = security.tls ?? {};

  return (
    <Section title={title}>
      <div className="grid grid-cols-2 gap-4">
        <div>
          <label className="block text-sm font-medium mb-2">Mode</label>
          <select
            value={security.mode ?? ''}
            onChange={(e) => updateConfig(`${path}.mode`, e.target.value || undefined)}
            className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
          >
            <option value="">Select mode</option>
            <option value="spiffe">SPIFFE</option>
            <option value="mtls">mTLS</option>
            <option value="tls">TLS</option>
            <option value="none">None</option>
          </select>
        </div>
        <div>
          <label className="block text-sm font-medium mb-2">Role</label>
          <input
            type="text"
            value={security.role ?? ''}
            onChange={(e) => updateConfig(`${path}.role`, e.target.value)}
            className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            placeholder="core"
          />
        </div>
        <div>
          <label className="block text-sm font-medium mb-2">Cert Directory</label>
          <input
            type="text"
            value={security.cert_dir ?? ''}
            onChange={(e) => updateConfig(`${path}.cert_dir`, e.target.value)}
            className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
          />
        </div>
        <div>
          <label className="block text-sm font-medium mb-2">Server Name</label>
          <input
            type="text"
            value={security.server_name ?? ''}
            onChange={(e) => updateConfig(`${path}.server_name`, e.target.value)}
            className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
          />
        </div>
        <div>
          <label className="block text-sm font-medium mb-2">Server SPIFFE ID</label>
          <input
            type="text"
            value={security.server_spiffe_id ?? ''}
            onChange={(e) => updateConfig(`${path}.server_spiffe_id`, e.target.value)}
            className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            placeholder="spiffe://..."
          />
        </div>
        <div>
          <label className="block text-sm font-medium mb-2">Trust Domain</label>
          <input
            type="text"
            value={security.trust_domain ?? ''}
            onChange={(e) => updateConfig(`${path}.trust_domain`, e.target.value)}
            className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
          />
        </div>
        <div>
          <label className="block text-sm font-medium mb-2">Workload Socket</label>
          <input
            type="text"
            value={security.workload_socket ?? ''}
            onChange={(e) => updateConfig(`${path}.workload_socket`, e.target.value)}
            className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            placeholder="unix:/run/spire/sockets/agent.sock"
          />
        </div>
      </div>
      <div className="grid grid-cols-2 gap-4">
        <div>
          <label className="block text-sm font-medium mb-2">CA File</label>
          <input
            type="text"
            value={tls.ca_file ?? ''}
            onChange={(e) => updateConfig(`${path}.tls.ca_file`, e.target.value)}
            className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
          />
        </div>
        <div>
          <label className="block text-sm font-medium mb-2">Client CA File</label>
          <input
            type="text"
            value={tls.client_ca_file ?? ''}
            onChange={(e) => updateConfig(`${path}.tls.client_ca_file`, e.target.value)}
            className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
          />
        </div>
        <div>
          <label className="block text-sm font-medium mb-2">Cert File</label>
          <input
            type="text"
            value={tls.cert_file ?? ''}
            onChange={(e) => updateConfig(`${path}.tls.cert_file`, e.target.value)}
            className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
          />
        </div>
        <div>
          <label className="block text-sm font-medium mb-2">Key File</label>
          <input
            type="text"
            value={tls.key_file ?? ''}
            onChange={(e) => updateConfig(`${path}.tls.key_file`, e.target.value)}
            className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
          />
        </div>
      </div>
    </Section>
  );
};

const stringValue = (value?: string | number | null) =>
  value === undefined || value === null ? '' : String(value);

export default function CoreConfigForm({ config, onChange }: CoreConfigFormProps) {
  const updateConfig = (path: string, value: unknown) => {
    const nextConfig = { ...config };
    safeSet(nextConfig, path, value);
    onChange(nextConfig as CoreConfig);
  };

  const [rolePermissionsText, setRolePermissionsText] = useState('{}');
  const [rolePermissionsError, setRolePermissionsError] = useState<string | null>(null);

  const [routeProtectionText, setRouteProtectionText] = useState('{}');
  const [routeProtectionError, setRouteProtectionError] = useState<string | null>(null);

  const [userRolesText, setUserRolesText] = useState('{}');
  const [userRolesError, setUserRolesError] = useState<string | null>(null);

  const [localUsersText, setLocalUsersText] = useState('{}');
  const [localUsersError, setLocalUsersError] = useState<string | null>(null);

  const [ssoProvidersText, setSsoProvidersText] = useState('{}');
  const [ssoProvidersError, setSsoProvidersError] = useState<string | null>(null);

  const [edgeMetadataText, setEdgeMetadataText] = useState('{}');
  const [edgeMetadataError, setEdgeMetadataError] = useState<string | null>(null);

  const [databaseSettingsText, setDatabaseSettingsText] = useState('{}');
  const [databaseSettingsError, setDatabaseSettingsError] = useState<string | null>(null);

  const [snmpTargetsText, setSnmpTargetsText] = useState('[]');
  const [snmpTargetsError, setSnmpTargetsError] = useState<string | null>(null);

  const [otelHeadersText, setOtelHeadersText] = useState('{}');
  const [otelHeadersError, setOtelHeadersError] = useState<string | null>(null);

  const serializedRolePermissions = useMemo(
    () => JSON.stringify(config.auth?.rbac?.role_permissions ?? {}, null, 2),
    [config.auth?.rbac?.role_permissions],
  );
  useEffect(() => {
    setRolePermissionsText(serializedRolePermissions);
  }, [serializedRolePermissions]);

  const serializedRouteProtection = useMemo(
    () => JSON.stringify(config.auth?.rbac?.route_protection ?? {}, null, 2),
    [config.auth?.rbac?.route_protection],
  );
  useEffect(() => {
    setRouteProtectionText(serializedRouteProtection);
  }, [serializedRouteProtection]);

  const serializedUserRoles = useMemo(
    () => JSON.stringify(config.auth?.rbac?.user_roles ?? {}, null, 2),
    [config.auth?.rbac?.user_roles],
  );
  useEffect(() => {
    setUserRolesText(serializedUserRoles);
  }, [serializedUserRoles]);

  const serializedLocalUsers = useMemo(
    () => JSON.stringify(config.auth?.local_users ?? {}, null, 2),
    [config.auth?.local_users],
  );
  useEffect(() => {
    setLocalUsersText(serializedLocalUsers);
  }, [serializedLocalUsers]);

  const serializedSsoProviders = useMemo(
    () => JSON.stringify(config.auth?.sso_providers ?? {}, null, 2),
    [config.auth?.sso_providers],
  );
  useEffect(() => {
    setSsoProvidersText(serializedSsoProviders);
  }, [serializedSsoProviders]);

  const serializedEdgeMetadata = useMemo(
    () => JSON.stringify(config.edge_onboarding?.default_metadata ?? {}, null, 2),
    [config.edge_onboarding?.default_metadata],
  );
  useEffect(() => {
    setEdgeMetadataText(serializedEdgeMetadata);
  }, [serializedEdgeMetadata]);

  const serializedDbSettings = useMemo(
    () => JSON.stringify(config.database?.settings ?? {}, null, 2),
    [config.database?.settings],
  );
  useEffect(() => {
    setDatabaseSettingsText(serializedDbSettings);
  }, [serializedDbSettings]);

  const serializedSnmpTargets = useMemo(
    () => JSON.stringify(config.snmp?.targets ?? [], null, 2),
    [config.snmp?.targets],
  );
  useEffect(() => {
    setSnmpTargetsText(serializedSnmpTargets);
  }, [serializedSnmpTargets]);

  const serializedOtelHeaders = useMemo(
    () => JSON.stringify(config.logging?.otel?.headers ?? {}, null, 2),
    [config.logging?.otel?.headers],
  );
  useEffect(() => {
    setOtelHeadersText(serializedOtelHeaders);
  }, [serializedOtelHeaders]);

  const handleJsonBlur = (
    text: string,
    path: string,
    setError: (err: string | null) => void,
    fallback: unknown,
  ) => {
    if (!text.trim()) {
      updateConfig(path, fallback);
      setError(null);
      return;
    }

    try {
      const parsed = JSON.parse(text);
      updateConfig(path, parsed);
      setError(null);
    } catch {
      setError('Invalid JSON format');
    }
  };

  const webhooks = Array.isArray(config.webhooks) ? config.webhooks : [];
  const handleWebhookChange = (index: number, field: keyof WebhookConfig, value: unknown) => {
    const next = [...webhooks];
    const current = next[index] ?? {};
    next[index] = { ...current, [field]: value };
    updateConfig('webhooks', next);
  };

  const handleWebhookHeaderChange = (
    webhookIndex: number,
    headerIndex: number,
    field: keyof WebhookHeader,
    value: string,
  ) => {
    const headers = Array.isArray(webhooks[webhookIndex]?.headers)
      ? [...(webhooks[webhookIndex]?.headers as WebhookHeader[])]
      : [];
    const current = headers[headerIndex] ?? { key: '', value: '' };
    headers[headerIndex] = { ...current, [field]: value };
    handleWebhookChange(webhookIndex, 'headers', headers);
  };

  const kvEndpoints = Array.isArray(config.kv_endpoints) ? config.kv_endpoints : [];
  const handleKvEndpointChange = (index: number, field: keyof KVEndpoint, value: string) => {
    const next = [...kvEndpoints];
    const current = next[index] ?? {};
    next[index] = { ...current, [field]: value };
    updateConfig('kv_endpoints', next);
  };

  const featureOptions: Array<{
    key: keyof FeatureFlags;
    label: string;
    description: string;
  }> = [
    {
      key: 'require_device_registry',
      label: 'Require device registry',
      description: 'Ensures devices exist in the registry before accepting telemetry.',
    },
    {
      key: 'use_device_search_planner',
      label: 'Use device search planner',
      description: 'Enable optimized search plans when querying devices.',
    },
    {
      key: 'use_log_digest',
      label: 'Use log digest',
      description: 'Enables log digest calculations for faster comparisons.',
    },
    {
      key: 'use_stats_cache',
      label: 'Use stats cache',
      description: 'Caches device statistics in memory.',
    },
  ];

  return (
    <div className="space-y-6">
      <Section title="Core Service">
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Listen Address</label>
            <input
              type="text"
              value={config.listen_addr ?? ''}
              onChange={(e) => updateConfig('listen_addr', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder=":8090"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">gRPC Address</label>
            <input
              type="text"
              value={config.grpc_addr ?? ''}
              onChange={(e) => updateConfig('grpc_addr', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder=":50052"
            />
          </div>
        </div>
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Alert Threshold</label>
            <input
              type="text"
              value={config.alert_threshold ?? ''}
              onChange={(e) => updateConfig('alert_threshold', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="5m0s"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">HTTP Listen Address (Legacy)</label>
            <input
              type="text"
              value={config.db_path ?? ''}
              onChange={(e) => updateConfig('db_path', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="/var/lib/serviceradar/core.db"
            />
          </div>
        </div>
        <StringArrayEditor
          label="Known Pollers"
          values={config.known_pollers}
          onChange={(next) => updateConfig('known_pollers', next)}
          placeholder="poller-id"
          addLabel="Add Poller"
        />
        <StringArrayEditor
          label="Poller Patterns"
          values={config.poller_patterns}
          onChange={(next) => updateConfig('poller_patterns', next)}
          placeholder="k8s-*"
          addLabel="Add Pattern"
          description="Use glob-style patterns to auto-match pollers."
        />
      </Section>

      <Section
        title="Legacy Proton Overrides"
        description="Optional compatibility fields for legacy bootstrap scripts."
      >
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">DB Address</label>
            <input
              type="text"
              value={config.db_addr ?? ''}
              onChange={(e) => updateConfig('db_addr', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="proton:9440"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">DB Name</label>
            <input
              type="text"
              value={config.db_name ?? ''}
              onChange={(e) => updateConfig('db_name', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">DB User</label>
            <input
              type="text"
              value={config.db_user ?? ''}
              onChange={(e) => updateConfig('db_user', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">DB Password</label>
            <input
              type="text"
              value={config.db_pass ?? ''}
              onChange={(e) => updateConfig('db_pass', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
        </div>
      </Section>

      <Section title="Database Configuration">
        <StringArrayEditor
          label="Addresses"
          values={config.database?.addresses}
          onChange={(next) => updateConfig('database.addresses', next)}
          placeholder="serviceradar-proton:9440"
          addLabel="Add Address"
        />
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Database Name</label>
            <input
              type="text"
              value={config.database?.name ?? ''}
              onChange={(e) => updateConfig('database.name', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Username</label>
            <input
              type="text"
              value={config.database?.username ?? ''}
              onChange={(e) => updateConfig('database.username', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Password</label>
            <input
              type="text"
              value={config.database?.password ?? ''}
              onChange={(e) => updateConfig('database.password', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium mb-2">Max Connections</label>
              <input
                type="number"
                value={config.database?.max_conns ?? ''}
                onChange={(e) =>
                  updateConfig(
                    'database.max_conns',
                    e.target.value === '' ? undefined : Number(e.target.value),
                  )
                }
                className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              />
            </div>
            <div>
              <label className="block text-sm font-medium mb-2">Idle Connections</label>
              <input
                type="number"
                value={config.database?.idle_conns ?? ''}
                onChange={(e) =>
                  updateConfig(
                    'database.idle_conns',
                    e.target.value === '' ? undefined : Number(e.target.value),
                  )
                }
                className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              />
            </div>
          </div>
        </div>
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">TLS CA File</label>
            <input
              type="text"
              value={config.database?.tls?.ca_file ?? ''}
              onChange={(e) => updateConfig('database.tls.ca_file', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">TLS Cert File</label>
            <input
              type="text"
              value={config.database?.tls?.cert_file ?? ''}
              onChange={(e) => updateConfig('database.tls.cert_file', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">TLS Key File</label>
            <input
              type="text"
              value={config.database?.tls?.key_file ?? ''}
              onChange={(e) => updateConfig('database.tls.key_file', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">TLS Client CA File</label>
            <input
              type="text"
              value={config.database?.tls?.client_ca_file ?? ''}
              onChange={(e) => updateConfig('database.tls.client_ca_file', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
        </div>
        <JsonTextArea
          label="Advanced Proton Settings"
          value={databaseSettingsText}
          onChange={setDatabaseSettingsText}
          onBlur={() =>
            handleJsonBlur(databaseSettingsText, 'database.settings', setDatabaseSettingsError, {})
          }
          error={databaseSettingsError}
          description="Key/value map is stored verbatim in the config; use valid JSON."
        />
      </Section>

      <Section title="CORS">
        <StringArrayEditor
          label="Allowed Origins"
          values={config.cors?.allowed_origins}
          onChange={(next) => updateConfig('cors.allowed_origins', next)}
          placeholder="https://example.com"
        />
        <label className="flex items-center gap-2">
          <input
            type="checkbox"
            checked={config.cors?.allow_credentials ?? false}
            onChange={(e) => updateConfig('cors.allow_credentials', e.target.checked)}
          />
          Allow credentials
        </label>
      </Section>

      <Section title="Authentication & RBAC">
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Callback URL</label>
            <input
              type="text"
              value={config.auth?.callback_url ?? ''}
              onChange={(e) => updateConfig('auth.callback_url', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="https://core.example.com/auth/callback"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">JWT Algorithm</label>
            <select
              value={config.auth?.jwt_algorithm ?? ''}
              onChange={(e) => updateConfig('auth.jwt_algorithm', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            >
              <option value="">Default (HS256)</option>
              <option value="HS256">HS256</option>
              <option value="RS256">RS256</option>
              <option value="ES256">ES256</option>
            </select>
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">JWT Expiration</label>
            <input
              type="text"
              value={config.auth?.jwt_expiration ?? ''}
              onChange={(e) => updateConfig('auth.jwt_expiration', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="24h0m0s"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">JWT Key ID</label>
            <input
              type="text"
              value={config.auth?.jwt_key_id ?? ''}
              onChange={(e) => updateConfig('auth.jwt_key_id', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
        </div>
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">JWT Public Key (PEM)</label>
            <textarea
              value={config.auth?.jwt_public_key_pem ?? ''}
              onChange={(e) => updateConfig('auth.jwt_public_key_pem', e.target.value)}
              rows={6}
              className="w-full font-mono text-sm p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="-----BEGIN PUBLIC KEY-----"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">JWT Private Key (PEM)</label>
            <textarea
              value={config.auth?.jwt_private_key_pem ?? ''}
              onChange={(e) => updateConfig('auth.jwt_private_key_pem', e.target.value)}
              rows={6}
              className="w-full font-mono text-sm p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="-----BEGIN PRIVATE KEY-----"
            />
          </div>
        </div>
        <div>
          <label className="block text-sm font-medium mb-2">JWT Secret</label>
          <div className="p-2 bg-gray-100 dark:bg-gray-700 rounded-md border border-gray-300 dark:border-gray-600 text-sm text-gray-600 dark:text-gray-300">
            Manage shared secrets directly in JSON mode or via secure deployment tooling.
          </div>
        </div>
        <JsonTextArea
          label="RBAC Role Permissions"
          value={rolePermissionsText}
          onChange={setRolePermissionsText}
          onBlur={() =>
            handleJsonBlur(rolePermissionsText, 'auth.rbac.role_permissions', setRolePermissionsError, {})
          }
          error={rolePermissionsError}
        />
        <JsonTextArea
          label="RBAC Route Protection"
          value={routeProtectionText}
          onChange={setRouteProtectionText}
          onBlur={() =>
            handleJsonBlur(routeProtectionText, 'auth.rbac.route_protection', setRouteProtectionError, {})
          }
          error={routeProtectionError}
          description="Supports either an array of roles or method map per route."
        />
        <JsonTextArea
          label="RBAC User Roles"
          value={userRolesText}
          onChange={setUserRolesText}
          onBlur={() =>
            handleJsonBlur(userRolesText, 'auth.rbac.user_roles', setUserRolesError, {})
          }
          error={userRolesError}
        />
        <JsonTextArea
          label="Local Users"
          value={localUsersText}
          onChange={setLocalUsersText}
          onBlur={() =>
            handleJsonBlur(localUsersText, 'auth.local_users', setLocalUsersError, {})
          }
          error={localUsersError}
          description="Values should already be hashed."
        />
        <JsonTextArea
          label="SSO Providers"
          value={ssoProvidersText}
          onChange={setSsoProvidersText}
          onBlur={() =>
            handleJsonBlur(ssoProvidersText, 'auth.sso_providers', setSsoProvidersError, {})
          }
          error={ssoProvidersError}
          description="Map provider names to client configuration."
        />
      </Section>

      <Section title="Logging & OTEL">
        <div className="grid grid-cols-4 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Level</label>
            <select
              value={config.logging?.level ?? ''}
              onChange={(e) => updateConfig('logging.level', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            >
              <option value="">Default (info)</option>
              <option value="debug">debug</option>
              <option value="info">info</option>
              <option value="warn">warn</option>
              <option value="error">error</option>
            </select>
          </div>
          <div className="flex items-center">
            <label className="flex items-center gap-2 mt-6">
              <input
                type="checkbox"
                checked={config.logging?.debug ?? false}
                onChange={(e) => updateConfig('logging.debug', e.target.checked)}
              />
              Debug mode
            </label>
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Output</label>
            <input
              type="text"
              value={config.logging?.output ?? ''}
              onChange={(e) => updateConfig('logging.output', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="stdout"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Time Format</label>
            <input
              type="text"
              value={config.logging?.time_format ?? ''}
              onChange={(e) => updateConfig('logging.time_format', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="RFC3339"
            />
          </div>
        </div>
        <div className="grid grid-cols-2 gap-4">
          <label className="flex items-center gap-2">
            <input
              type="checkbox"
              checked={config.logging?.otel?.enabled ?? false}
              onChange={(e) => updateConfig('logging.otel.enabled', e.target.checked)}
            />
            Enable OTEL exporter
          </label>
          <label className="flex items-center gap-2">
            <input
              type="checkbox"
              checked={config.logging?.otel?.insecure ?? false}
              onChange={(e) => updateConfig('logging.otel.insecure', e.target.checked)}
            />
            Insecure transport
          </label>
        </div>
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">OTEL Endpoint</label>
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
              placeholder="serviceradar-core"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Batch Timeout</label>
            <input
              type="text"
              value={config.logging?.otel?.batch_timeout ?? ''}
              onChange={(e) => updateConfig('logging.otel.batch_timeout', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="5s"
            />
          </div>
        </div>
        <JsonTextArea
          label="OTEL Headers"
          value={otelHeadersText}
          onChange={setOtelHeadersText}
          onBlur={() =>
            handleJsonBlur(otelHeadersText, 'logging.otel.headers', setOtelHeadersError, {})
          }
          error={otelHeadersError}
        />
        <div className="grid grid-cols-3 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">TLS CA File</label>
            <input
              type="text"
              value={config.logging?.otel?.tls?.ca_file ?? ''}
              onChange={(e) => updateConfig('logging.otel.tls.ca_file', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">TLS Cert File</label>
            <input
              type="text"
              value={config.logging?.otel?.tls?.cert_file ?? ''}
              onChange={(e) => updateConfig('logging.otel.tls.cert_file', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">TLS Key File</label>
            <input
              type="text"
              value={config.logging?.otel?.tls?.key_file ?? ''}
              onChange={(e) => updateConfig('logging.otel.tls.key_file', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
        </div>
      </Section>

      <Section title="Metrics & Feature Flags">
        <div className="grid grid-cols-3 gap-4">
          <label className="flex items-center gap-2">
            <input
              type="checkbox"
              checked={config.metrics?.enabled ?? false}
              onChange={(e) => updateConfig('metrics.enabled', e.target.checked)}
            />
            Enable metrics
          </label>
          <div>
            <label className="block text-sm font-medium mb-2">Retention</label>
            <input
              type="number"
              value={config.metrics?.retention ?? ''}
              onChange={(e) =>
                updateConfig(
                  'metrics.retention',
                  e.target.value === '' ? undefined : Number(e.target.value),
                )
              }
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Max Pollers</label>
            <input
              type="number"
              value={config.metrics?.max_pollers ?? ''}
              onChange={(e) =>
                updateConfig(
                  'metrics.max_pollers',
                  e.target.value === '' ? undefined : Number(e.target.value),
                )
              }
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
        </div>
        <div className="grid grid-cols-2 gap-4">
          {featureOptions.map((feature) => {
            const currentValue = config.features?.[feature.key];
            const selectValue =
              currentValue === undefined || currentValue === null
                ? 'inherit'
                : currentValue
                  ? 'true'
                  : 'false';
            return (
              <div key={feature.key}>
                <label className="block text-sm font-medium mb-1">{feature.label}</label>
                <p className="text-sm text-gray-500 dark:text-gray-400 mb-1">
                  {feature.description}
                </p>
                <select
                  value={selectValue}
                  onChange={(e) => {
                    if (e.target.value === 'inherit') {
                      updateConfig(`features.${feature.key as string}`, null);
                    } else {
                      updateConfig(
                        `features.${feature.key as string}`,
                        e.target.value === 'true',
                      );
                    }
                  }}
                  className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                >
                  <option value="inherit">Environment default</option>
                  <option value="true">Enabled</option>
                  <option value="false">Disabled</option>
                </select>
              </div>
            );
          })}
        </div>
      </Section>

      <Section title="Events & Messaging">
        <div className="grid grid-cols-2 gap-4">
          <label className="flex items-center gap-2">
            <input
              type="checkbox"
              checked={config.events?.enabled ?? false}
              onChange={(e) => updateConfig('events.enabled', e.target.checked)}
            />
            Enable events stream
          </label>
          <div>
            <label className="block text-sm font-medium mb-2">Stream Name</label>
            <input
              type="text"
              value={config.events?.stream_name ?? ''}
              onChange={(e) => updateConfig('events.stream_name', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="events"
            />
          </div>
        </div>
        <StringArrayEditor
          label="Event Subjects"
          values={config.events?.subjects}
          onChange={(next) => updateConfig('events.subjects', next)}
          placeholder="events.>"
        />
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">NATS URL</label>
            <input
              type="text"
              value={config.nats?.url ?? ''}
              onChange={(e) => updateConfig('nats.url', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="tls://serviceradar-nats:4222"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Domain</label>
            <input
              type="text"
              value={config.nats?.domain ?? ''}
              onChange={(e) => updateConfig('nats.domain', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="events"
            />
          </div>
        </div>
      </Section>

      <SecurityFields
        title="Core Security"
        path="security"
        data={config.security}
        updateConfig={updateConfig}
      />

      <SecurityFields
        title="KV Security"
        path="kv_security"
        data={config.kv_security}
        updateConfig={updateConfig}
      />

      <SecurityFields
        title="NATS Security"
        path="nats.security"
        data={config.nats?.security}
        updateConfig={updateConfig}
      />

      <Section title="Edge Onboarding">
        <label className="flex items-center gap-2">
          <input
            type="checkbox"
            checked={config.edge_onboarding?.enabled ?? false}
            onChange={(e) => updateConfig('edge_onboarding.enabled', e.target.checked)}
          />
          Enable onboarding packages
        </label>
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Encryption Key (base64)</label>
            <input
              type="text"
              value={config.edge_onboarding?.encryption_key ?? ''}
              onChange={(e) => updateConfig('edge_onboarding.encryption_key', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Poller ID Prefix</label>
            <input
              type="text"
              value={config.edge_onboarding?.poller_id_prefix ?? ''}
              onChange={(e) => updateConfig('edge_onboarding.poller_id_prefix', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Join Token TTL</label>
            <input
              type="text"
              value={stringValue(config.edge_onboarding?.join_token_ttl)}
              onChange={(e) => updateConfig('edge_onboarding.join_token_ttl', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="15m0s"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Download Token TTL</label>
            <input
              type="text"
              value={stringValue(config.edge_onboarding?.download_token_ttl)}
              onChange={(e) => updateConfig('edge_onboarding.download_token_ttl', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="10m0s"
            />
          </div>
          <div className="col-span-2">
            <label className="block text-sm font-medium mb-2">Downstream Path Template</label>
            <input
              type="text"
              value={config.edge_onboarding?.downstream_path_template ?? ''}
              onChange={(e) =>
                updateConfig('edge_onboarding.downstream_path_template', e.target.value)
              }
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
        </div>
        <StringArrayEditor
          label="Default Selectors"
          values={config.edge_onboarding?.default_selectors}
          onChange={(next) => updateConfig('edge_onboarding.default_selectors', next)}
          placeholder="unix:uid:0"
        />
        <JsonTextArea
          label="Default Metadata"
          value={edgeMetadataText}
          onChange={setEdgeMetadataText}
          onBlur={() =>
            handleJsonBlur(
              edgeMetadataText,
              'edge_onboarding.default_metadata',
              setEdgeMetadataError,
              {},
            )
          }
          error={edgeMetadataError}
          description="Map component types (poller, agent, etc.) to metadata entries."
        />
      </Section>

      <Section title="SPIRE & KV Connectivity">
        <label className="flex items-center gap-2">
          <input
            type="checkbox"
            checked={config.spire_admin?.enabled ?? false}
            onChange={(e) => updateConfig('spire_admin.enabled', e.target.checked)}
          />
          Enable SPIRE admin integration
        </label>
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Server Address</label>
            <input
              type="text"
              value={config.spire_admin?.server_address ?? ''}
              onChange={(e) => updateConfig('spire_admin.server_address', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="spire-server.demo.svc.cluster.local:8081"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Server SPIFFE ID</label>
            <input
              type="text"
              value={config.spire_admin?.server_spiffe_id ?? ''}
              onChange={(e) => updateConfig('spire_admin.server_spiffe_id', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Workload Socket</label>
            <input
              type="text"
              value={config.spire_admin?.workload_socket ?? ''}
              onChange={(e) => updateConfig('spire_admin.workload_socket', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Bundle Path</label>
            <input
              type="text"
              value={config.spire_admin?.bundle_path ?? ''}
              onChange={(e) => updateConfig('spire_admin.bundle_path', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Join Token TTL</label>
            <input
              type="text"
              value={stringValue(config.spire_admin?.join_token_ttl)}
              onChange={(e) => updateConfig('spire_admin.join_token_ttl', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="15m0s"
            />
          </div>
        </div>

        <div className="space-y-4">
          <div className="flex items-center justify-between">
            <h4 className="text-md font-semibold">KV Endpoints</h4>
            <button
              type="button"
              onClick={() =>
                updateConfig('kv_endpoints', [
                  ...kvEndpoints,
                  { id: '', name: '', address: '', domain: '', type: '' },
                ])
              }
              className="px-3 py-2 text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900 rounded-md"
            >
              Add endpoint
            </button>
          </div>
          {kvEndpoints.length === 0 && (
            <p className="text-sm text-gray-500 dark:text-gray-400">
              Configure KV endpoints to target hub/leaf stores.
            </p>
          )}
          <div className="space-y-4">
            {kvEndpoints.map((endpoint, index) => (
              <div
                key={`kv-endpoint-${index}`}
                className="border border-gray-200 dark:border-gray-700 rounded-md p-4 space-y-3"
              >
                <div className="flex justify-between items-center">
                  <strong>Endpoint #{index + 1}</strong>
                  <button
                    type="button"
                    onClick={() =>
                      updateConfig(
                        'kv_endpoints',
                        kvEndpoints.filter((_, i) => i !== index),
                      )
                    }
                    className="text-red-600 hover:underline text-sm"
                  >
                    Remove
                  </button>
                </div>
                <div className="grid grid-cols-2 gap-4">
                  <div>
                    <label className="block text-sm font-medium mb-2">ID</label>
                    <input
                      type="text"
                      value={endpoint.id ?? ''}
                      onChange={(e) => handleKvEndpointChange(index, 'id', e.target.value)}
                      className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium mb-2">Name</label>
                    <input
                      type="text"
                      value={endpoint.name ?? ''}
                      onChange={(e) => handleKvEndpointChange(index, 'name', e.target.value)}
                      className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium mb-2">Address</label>
                    <input
                      type="text"
                      value={endpoint.address ?? ''}
                      onChange={(e) => handleKvEndpointChange(index, 'address', e.target.value)}
                      className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                      placeholder="serviceradar-datasvc:50057"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium mb-2">Domain</label>
                    <input
                      type="text"
                      value={endpoint.domain ?? ''}
                      onChange={(e) => handleKvEndpointChange(index, 'domain', e.target.value)}
                      className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                      placeholder="demo"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium mb-2">Type</label>
                    <input
                      type="text"
                      value={endpoint.type ?? ''}
                      onChange={(e) => handleKvEndpointChange(index, 'type', e.target.value)}
                      className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                      placeholder="hub / leaf"
                    />
                  </div>
                </div>
              </div>
            ))}
          </div>
        </div>
      </Section>

      <Section title="Integrations">
        <div className="grid grid-cols-2 gap-4">
          <label className="flex items-center gap-2">
            <input
              type="checkbox"
              checked={config.srql?.enabled ?? false}
              onChange={(e) => updateConfig('srql.enabled', e.target.checked)}
            />
            Enable SRQL
          </label>
          <label className="flex items-center gap-2">
            <input
              type="checkbox"
              checked={config.mcp?.enabled ?? false}
              onChange={(e) => updateConfig('mcp.enabled', e.target.checked)}
            />
            Enable MCP Agent
          </label>
        </div>
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">SRQL Base URL</label>
            <input
              type="text"
              value={config.srql?.base_url ?? ''}
              onChange={(e) => updateConfig('srql.base_url', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="http://serviceradar-srql:8080"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">SRQL API Key</label>
            <input
              type="text"
              value={config.srql?.api_key ?? ''}
              onChange={(e) => updateConfig('srql.api_key', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">SRQL Timeout</label>
            <input
              type="text"
              value={config.srql?.timeout ?? ''}
              onChange={(e) => updateConfig('srql.timeout', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="15s"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">SRQL Path</label>
            <input
              type="text"
              value={config.srql?.path ?? ''}
              onChange={(e) => updateConfig('srql.path', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="/api/query"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">MCP API Key</label>
            <input
              type="text"
              value={config.mcp?.api_key ?? ''}
              onChange={(e) => updateConfig('mcp.api_key', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
        </div>
      </Section>

      <Section title="SNMP">
        <div className="grid grid-cols-3 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Listen Address</label>
            <input
              type="text"
              value={config.snmp?.listen_addr ?? ''}
              onChange={(e) => updateConfig('snmp.listen_addr', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder=":161"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Node Address</label>
            <input
              type="text"
              value={config.snmp?.node_address ?? ''}
              onChange={(e) => updateConfig('snmp.node_address', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Timeout</label>
            <input
              type="text"
              value={stringValue(config.snmp?.timeout)}
              onChange={(e) => updateConfig('snmp.timeout', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
        </div>
        <label className="flex items-center gap-2">
          <input
            type="checkbox"
            checked={Boolean(config.snmp?.security)}
            onChange={(e) => {
              if (e.target.checked) {
                updateConfig('snmp.security', config.snmp?.security ?? { mode: 'spiffe', tls: {} });
              } else {
                updateConfig('snmp.security', null);
              }
            }}
          />
          Configure SNMP security
        </label>
        {config.snmp?.security ? (
          <SecurityFields
            title="SNMP Security"
            path="snmp.security"
            data={config.snmp.security}
            updateConfig={updateConfig}
          />
        ) : null}
        <JsonTextArea
          label="Targets"
          value={snmpTargetsText}
          onChange={setSnmpTargetsText}
          onBlur={() =>
            handleJsonBlur(snmpTargetsText, 'snmp.targets', setSnmpTargetsError, [])
          }
          error={snmpTargetsError}
          description="Provide an array of SNMP target descriptors."
          rows={8}
        />
      </Section>

      <Section title="Webhooks">
        <div className="flex justify-end">
          <button
            type="button"
            onClick={() =>
              updateConfig('webhooks', [
                ...webhooks,
                {
                  enabled: false,
                  url: '',
                  cooldown: '15m0s',
                  template: '',
                  headers: [],
                },
              ])
            }
            className="px-3 py-2 text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900 rounded-md"
          >
            Add webhook
          </button>
        </div>
        {webhooks.length === 0 && (
          <p className="text-sm text-gray-500 dark:text-gray-400">
            No webhook destinations configured.
          </p>
        )}
        <div className="space-y-4">
          {webhooks.map((hook, index) => (
            <div
              key={`webhook-${index}`}
              className="border border-gray-200 dark:border-gray-700 rounded-md p-4 space-y-3"
            >
              <div className="flex justify-between items-center">
                <strong>Webhook #{index + 1}</strong>
                <button
                  type="button"
                  onClick={() =>
                    updateConfig(
                      'webhooks',
                      webhooks.filter((_, i) => i !== index),
                    )
                  }
                  className="text-red-600 hover:underline text-sm"
                >
                  Remove
                </button>
              </div>
              <label className="flex items-center gap-2">
                <input
                  type="checkbox"
                  checked={hook.enabled ?? false}
                  onChange={(e) => handleWebhookChange(index, 'enabled', e.target.checked)}
                />
                Enabled
              </label>
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium mb-2">URL</label>
                  <input
                    type="text"
                    value={hook.url ?? ''}
                    onChange={(e) => handleWebhookChange(index, 'url', e.target.value)}
                    className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                    placeholder="https://..."
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium mb-2">Cooldown</label>
                  <input
                    type="text"
                    value={hook.cooldown ?? ''}
                    onChange={(e) => handleWebhookChange(index, 'cooldown', e.target.value)}
                    className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                    placeholder="15m0s"
                  />
                </div>
              </div>
              <div>
                <label className="block text-sm font-medium mb-2">Template</label>
                <textarea
                  value={hook.template ?? ''}
                  onChange={(e) => handleWebhookChange(index, 'template', e.target.value)}
                  rows={4}
                  className="w-full font-mono text-sm p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                />
              </div>
              <div className="space-y-2">
                <div className="flex justify-between items-center">
                  <span className="text-sm font-medium text-gray-700 dark:text-gray-300">
                    Headers
                  </span>
                  <button
                    type="button"
                    onClick={() => {
                      const headers = Array.isArray(hook.headers) ? hook.headers : [];
                      handleWebhookChange(index, 'headers', [...headers, { key: '', value: '' }]);
                    }}
                    className="text-blue-600 hover:underline text-sm"
                  >
                    Add header
                  </button>
                </div>
                {(hook.headers ?? []).map((header, headerIndex) => (
                  <div key={`header-${headerIndex}`} className="flex gap-2">
                    <input
                      type="text"
                      value={header.key}
                      onChange={(e) =>
                        handleWebhookHeaderChange(index, headerIndex, 'key', e.target.value)
                      }
                      className="flex-1 p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                      placeholder="Header Key"
                    />
                    <input
                      type="text"
                      value={header.value}
                      onChange={(e) =>
                        handleWebhookHeaderChange(index, headerIndex, 'value', e.target.value)
                      }
                      className="flex-1 p-2 border border-gray-300 dark:border-gray-600 rounded-md"
                      placeholder="Header Value"
                    />
                    <button
                      type="button"
                      onClick={() => {
                        const headers = (hook.headers ?? []).filter((_, i) => i !== headerIndex);
                        handleWebhookChange(index, 'headers', headers);
                      }}
                      className="px-3 py-2 text-red-600 hover:bg-red-50 dark:hover:bg-red-900 rounded-md"
                    >
                      Remove
                    </button>
                  </div>
                ))}
              </div>
            </div>
          ))}
        </div>
      </Section>

      <Section title="Write Buffer">
        <label className="flex items-center gap-2">
          <input
            type="checkbox"
            checked={config.write_buffer?.enabled ?? false}
            onChange={(e) => updateConfig('write_buffer.enabled', e.target.checked)}
          />
          Enable write buffer
        </label>
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-2">Flush Interval</label>
            <input
              type="text"
              value={stringValue(config.write_buffer?.flush_interval)}
              onChange={(e) => updateConfig('write_buffer.flush_interval', e.target.value)}
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
              placeholder="5s"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-2">Max Size</label>
            <input
              type="number"
              value={config.write_buffer?.max_size ?? ''}
              onChange={(e) =>
                updateConfig(
                  'write_buffer.max_size',
                  e.target.value === '' ? undefined : Number(e.target.value),
                )
              }
              className="w-full p-2 border border-gray-300 dark:border-gray-600 rounded-md"
            />
          </div>
        </div>
      </Section>
    </div>
  );
}
