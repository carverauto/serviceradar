/*
 * Copyright 2025 Carver Automation.
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

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  AlertTriangle,
  Ban,
  CalendarClock,
  Check,
  Copy,
  Download,
  Link2,
  Loader2,
  Network,
  Package as PackageIcon,
  Plus,
  RefreshCw,
  ShieldPlus,
  Trash2,
} from 'lucide-react';

import RoleGuard from '@/components/Auth/RoleGuard';

type EdgeComponentType = 'poller' | 'agent' | 'checker' | '';

type EdgePackage = {
  package_id: string;
  label: string;
  component_id: string;
  component_type: EdgeComponentType;
  parent_type?: EdgeComponentType;
  parent_id?: string;
  poller_id: string;
  site?: string;
  status: string;
  downstream_spiffe_id: string;
  selectors: string[];
  join_token_expires_at: string;
  download_token_expires_at: string;
  created_by: string;
  created_at: string;
  updated_at: string;
  delivered_at?: string;
  activated_at?: string;
  activated_from_ip?: string;
  last_seen_spiffe_id?: string;
  revoked_at?: string;
  deleted_at?: string;
  metadata_json?: string;
  checker_kind?: string;
  checker_config_json?: string;
  kv_revision?: number;
  notes?: string;
};

type EdgeEvent = {
  event_time: string;
  event_type: string;
  actor: string;
  source_ip?: string;
  details_json?: string;
};

type EdgePackageSecrets = {
  joinToken: string;
  downloadToken: string;
  bundlePEM: string;
};

type EdgePackageDefaults = {
  selectors?: string[];
  metadata?: Record<string, Record<string, string>>;
};

type AgentInfo = {
  agent_id: string;
  poller_id: string;
  last_seen: string;
  service_types?: string[];
};

type CreateFormState = {
  componentType: EdgeComponentType;
  componentId: string;
  parentId: string;
  label: string;
  pollerId: string;
  site: string;
  selectors: string;
  metadataJSON: string;
  notes: string;
  joinTTLMinutes: string;
  downloadTTLMinutes: string;
  downstreamSPIFFEID: string;
};

const defaultFormState: CreateFormState = {
  componentType: 'poller',
  componentId: '',
  parentId: '',
  label: '',
  pollerId: '',
  site: '',
  selectors: '',
  metadataJSON: '',
  notes: '',
  joinTTLMinutes: '30',
  downloadTTLMinutes: '15',
  downstreamSPIFFEID: '',
};

const statusStyles: Record<string, string> = {
  issued: 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-200',
  delivered: 'bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-200',
  activated: 'bg-emerald-100 text-emerald-800 dark:bg-emerald-900/30 dark:text-emerald-200',
  revoked: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-200',
  expired: 'bg-slate-200 text-slate-700 dark:bg-slate-800/60 dark:text-slate-300',
  deleted: 'bg-zinc-200 text-zinc-700 dark:bg-zinc-800/60 dark:text-zinc-200',
};

function formatDate(value?: string | null): string {
  if (!value) {
    return '—';
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }
  return date.toLocaleString();
}

function formatMetadata(metadata?: Record<string, string> | null): string {
  if (!metadata) {
    return '';
  }
  const entries = Object.entries(metadata)
    .map<[string, string]>(([key, value]) => [key.trim(), typeof value === 'string' ? value.trim() : String(value ?? '')])
    .filter(([key, value]) => key.length > 0 && value.length > 0)
    .sort(([a], [b]) => a.localeCompare(b));
  if (entries.length === 0) {
    return '';
  }
  const ordered: Record<string, string> = {};
  for (const [key, value] of entries) {
    ordered[key] = value;
  }
  return JSON.stringify(ordered, null, 2);
}

function getMetadataDefaults(defaults: EdgePackageDefaults | null, componentType: EdgeComponentType): Record<string, string> | undefined {
  if (!defaults?.metadata) {
    return undefined;
  }
  const key = componentType && componentType.length > 0 ? componentType : 'poller';
  return defaults.metadata[key] ?? defaults.metadata[componentType] ?? defaults.metadata['poller'];
}

function getStatusBadgeClass(status: string): string {
  const normalised = status?.toLowerCase() ?? '';
  return statusStyles[normalised] ?? 'bg-slate-200 text-slate-700 dark:bg-slate-800/60 dark:text-slate-200';
}

function titleCase(status: string): string {
  if (!status) {
    return status;
  }
  return status
    .split(/[_\s-]/)
    .map((token) => token.charAt(0).toUpperCase() + token.slice(1).toLowerCase())
    .join(' ');
}

function parseDetails(details?: string | null): Record<string, unknown> | null {
  if (!details) {
    return null;
  }
  try {
    const parsed = JSON.parse(details);
    if (parsed && typeof parsed === 'object') {
      return parsed as Record<string, unknown>;
    }
  } catch {
    return null;
  }
  return null;
}

function getAccessToken(): string | null {
  if (typeof document === 'undefined') {
    return null;
  }
  const match = document.cookie
    .split('; ')
    .find((row) => row.startsWith('accessToken='));
  if (!match) {
    return null;
  }
  const [, value] = match.split('=');
  return value ?? null;
}

function buildHeaders(contentType?: string, accept?: string): HeadersInit {
  const headers: Record<string, string> = {};
  if (contentType) {
    headers['Content-Type'] = contentType;
  }
  if (accept) {
    headers.Accept = accept;
  }
  const token = getAccessToken();
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  return headers;
}

function parseContentDisposition(disposition?: string | null): string | null {
  if (!disposition) return null;
  const match = /filename\*?=(?:UTF-8'')?("?)([^";]+)\1/.exec(disposition);
  if (match && match[2]) {
    return decodeURIComponent(match[2]);
  }
  return null;
}

export default function EdgePackagesPage() {
  const [packages, setPackages] = useState<EdgePackage[]>([]);
  const [loading, setLoading] = useState<boolean>(false);
  const [error, setError] = useState<string | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [events, setEvents] = useState<EdgeEvent[]>([]);
  const [eventsLoading, setEventsLoading] = useState<boolean>(false);
  const [eventsError, setEventsError] = useState<string | null>(null);
  const [formState, setFormState] = useState<CreateFormState>(defaultFormState);
  const [formOpen, setFormOpen] = useState<boolean>(false);
  const [formError, setFormError] = useState<string | null>(null);
  const [formSubmitting, setFormSubmitting] = useState<boolean>(false);
  const [actionMessage, setActionMessage] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [actionLoading, setActionLoading] = useState<boolean>(false);
  const [secrets, setSecrets] = useState<Record<string, EdgePackageSecrets>>({});
  const [defaults, setDefaults] = useState<EdgePackageDefaults | null>(null);
  const [metadataTouched, setMetadataTouched] = useState<boolean>(false);
  const [selectorsTouched, setSelectorsTouched] = useState<boolean>(false);
  const [registeredAgents, setRegisteredAgents] = useState<AgentInfo[]>([]);

  const selectedPackage = useMemo(
    () => packages.find((pkg) => pkg.package_id === selectedId) ?? null,
    [packages, selectedId],
  );

  const pollerIds = useMemo(() => {
    const seen = new Set<string>();
    return packages
      .filter((pkg) => (pkg.component_type ?? '') === 'poller')
      .map((pkg) => pkg.component_id || pkg.poller_id)
      .filter((id) => {
        const trimmed = id?.trim();
        if (!trimmed || seen.has(trimmed)) {
          return false;
        }
        seen.add(trimmed);
        return true;
      });
  }, [packages]);

  const agentIds = useMemo(() => {
    const seen = new Set<string>();
    // Combine registered agents with agents from packages
    const fromRegistered = registeredAgents.map((a) => a.agent_id);
    const fromPackages = packages
      .filter((pkg) => (pkg.component_type ?? '') === 'agent')
      .map((pkg) => pkg.component_id || pkg.parent_id || pkg.package_id);

    return [...fromRegistered, ...fromPackages]
      .filter((id) => {
        const trimmed = id?.trim();
        if (!trimmed || seen.has(trimmed)) {
          return false;
        }
        seen.add(trimmed);
        return true;
      });
  }, [packages, registeredAgents]);

  const parentPollerListId = 'edge-parent-poller-options';
  const parentAgentListId = 'edge-parent-agent-options';

  const loadPackages = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await fetch('/api/admin/edge-packages', {
        headers: buildHeaders(),
      });
      if (!response.ok) {
        const message = await response.text();
        throw new Error(message || 'Failed to fetch edge packages');
      }
      const data: EdgePackage[] = await response.json();
      setPackages(data);
      setSelectedId((prev) => {
        if (!prev) {
          return prev;
        }
        return data.some((pkg) => pkg.package_id === prev) ? prev : null;
      });
    } catch (err) {
      console.error('Error loading edge packages', err);
      setPackages([]);
      setError(err instanceof Error ? err.message : 'Failed to load packages');
    } finally {
      setLoading(false);
    }
  }, []);

  const loadEvents = useCallback(async (packageId: string) => {
    setEventsLoading(true);
    setEventsError(null);
    try {
      const response = await fetch(`/api/admin/edge-packages/${packageId}/events`, {
        headers: buildHeaders(),
      });
      if (!response.ok) {
        const message = await response.text();
        throw new Error(message || 'Failed to load events');
      }
      const data: EdgeEvent[] = await response.json();
      setEvents(data ?? []);
    } catch (err) {
      console.error('Failed to load edge package events', err);
      setEvents([]);
      setEventsError(err instanceof Error ? err.message : 'Failed to load events');
    } finally {
      setEventsLoading(false);
    }
  }, []);

  const loadAgents = useCallback(async () => {
    try {
      const response = await fetch('/api/admin/agents', {
        headers: buildHeaders(),
        cache: 'no-store',
      });
      if (!response.ok) {
        console.error('Failed to load registered agents');
        return;
      }
      const data: AgentInfo[] = await response.json();
      setRegisteredAgents(data ?? []);
    } catch (err) {
      console.error('Error loading registered agents', err);
    }
  }, []);

  useEffect(() => {
    void loadPackages();
    void loadAgents();
  }, [loadPackages, loadAgents]);

  useEffect(() => {
    let cancelled = false;
    const fetchDefaults = async () => {
      try {
        const response = await fetch('/api/admin/edge-packages/defaults', {
          headers: buildHeaders(),
          cache: 'no-store',
        });
        if (!response.ok) {
          const message = await response.text();
          throw new Error(message || 'Failed to load defaults');
        }
        const data: EdgePackageDefaults = await response.json();
        if (!cancelled) {
          setDefaults(data);
        }
      } catch (err) {
        console.error('Failed to load edge onboarding defaults', err);
      }
    };

    void fetchDefaults();

    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    if (selectedId) {
      void loadEvents(selectedId);
    } else {
      setEvents([]);
    }
  }, [selectedId, loadEvents]);

  useEffect(() => {
    if (!defaults) {
      return;
    }
    setFormState((prev) => {
      let next = prev;
      let changed = false;

      if (!selectorsTouched && (!prev.selectors || prev.selectors.trim().length === 0)) {
        const defaultSelectors = defaults.selectors ?? [];
        if (defaultSelectors.length > 0) {
          next = changed ? next : { ...prev };
          next.selectors = defaultSelectors.join('\n');
          changed = true;
        }
      }

      if (!metadataTouched && (!prev.metadataJSON || prev.metadataJSON.trim().length === 0)) {
        const metaDefaults = getMetadataDefaults(defaults, prev.componentType);
        const formatted = formatMetadata(metaDefaults);
        if (formatted) {
          next = changed ? next : { ...prev };
          next.metadataJSON = formatted;
          changed = true;
        }
      }

      return changed ? next : prev;
    });
  }, [defaults, metadataTouched, selectorsTouched, formState.componentType]);

  const resetForm = useCallback(() => {
    setFormState(defaultFormState);
    setFormError(null);
    setFormSubmitting(false);
    setMetadataTouched(false);
    setSelectorsTouched(false);
  }, []);

  const openFormFor = useCallback(
    (type: EdgeComponentType) => {
      setFormState({
        ...defaultFormState,
        componentType: type === 'agent' || type === 'checker' ? type : 'poller',
        pollerId: type === 'poller' ? '' : '',
        parentId: '',
        componentId: '',
      });
      setFormError(null);
      setFormSubmitting(false);
       setMetadataTouched(false);
       setSelectorsTouched(false);
      setFormOpen(true);
    },
    [],
  );

  const handleFormChange = (field: keyof CreateFormState, value: string) => {
    if (field === 'metadataJSON') {
      setMetadataTouched(true);
    } else if (field === 'selectors') {
      setSelectorsTouched(true);
    }
    setFormState((prev) => ({ ...prev, [field]: value }));
  };

  const handleComponentTypeChange = (value: EdgeComponentType) => {
    const nextType: EdgeComponentType =
      value === 'poller' || value === 'agent' || value === 'checker' ? value : 'poller';
    setFormState((prev) => ({
      ...prev,
      componentType: nextType,
      parentId: '',
      pollerId: nextType === 'poller' ? prev.pollerId : '',
      metadataJSON: !metadataTouched ? '' : prev.metadataJSON,
    }));
    if (!metadataTouched) {
      setMetadataTouched(false);
    }
  };

  const handleCreate = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    setFormError(null);
    setActionMessage(null);
    setActionError(null);

    const trimmedLabel = formState.label.trim();
    if (!trimmedLabel) {
      setFormError('Label is required');
      return;
    }

    const componentType: EdgeComponentType =
      formState.componentType === 'agent' || formState.componentType === 'checker'
        ? formState.componentType
        : 'poller';
    const componentId = formState.componentId.trim();
    const parentId = formState.parentId.trim();

    if (componentType === 'agent' && !parentId) {
      setFormError('Parent poller is required for agent packages');
      return;
    }
    if (componentType === 'checker' && !parentId) {
      setFormError('Parent agent is required for checker packages');
      return;
    }

    setFormSubmitting(true);
    try {
      const selectors = formState.selectors
        .split(/[\n,]/)
        .map((token) => token.trim())
        .filter((token) => token.length > 0);

      const joinMinutes = formState.joinTTLMinutes.trim();
      const downloadMinutes = formState.downloadTTLMinutes.trim();
      const pollerOverride = formState.pollerId.trim();
      const pollerIdForPayload =
        componentType === 'poller'
          ? pollerOverride || undefined
          : componentType === 'checker' && pollerOverride
            ? pollerOverride
            : undefined;

      const payload: {
        label: string;
        component_type: EdgeComponentType;
        component_id?: string;
        parent_type?: EdgeComponentType;
        parent_id?: string;
        poller_id?: string;
        site?: string;
        selectors?: string[];
        metadata_json?: string;
        notes?: string;
        downstream_spiffe_id?: string;
        join_token_ttl_seconds?: number;
        download_token_ttl_seconds?: number;
      } = {
        label: trimmedLabel,
        component_type: componentType,
        component_id: componentId || undefined,
        parent_id: parentId || undefined,
        poller_id: pollerIdForPayload,
        site: formState.site.trim() || undefined,
        selectors: selectors.length > 0 ? selectors : undefined,
        metadata_json: formState.metadataJSON.trim() || undefined,
        notes: formState.notes.trim() || undefined,
        downstream_spiffe_id: formState.downstreamSPIFFEID.trim() || undefined,
        join_token_ttl_seconds: joinMinutes ? Math.max(0, Math.round(Number(joinMinutes) * 60)) : undefined,
        download_token_ttl_seconds: downloadMinutes ? Math.max(0, Math.round(Number(downloadMinutes) * 60)) : undefined,
      };

      if (componentType === 'agent') {
        payload.parent_type = 'poller';
      } else if (componentType === 'checker') {
        payload.parent_type = 'agent';
      }

      const response = await fetch('/api/admin/edge-packages', {
        method: 'POST',
        headers: buildHeaders('application/json', 'application/json'),
        body: JSON.stringify(payload),
      });
      if (!response.ok) {
        const message = await response.text();
        throw new Error(message || 'Failed to create edge package');
      }

      const result = await response.json();
      const createdPackage: EdgePackage = result.package;

      setPackages((prev) => [createdPackage, ...prev]);
      setSelectedId(createdPackage.package_id);
      setSecrets((prev) => ({
        ...prev,
        [createdPackage.package_id]: {
          joinToken: result.join_token,
          downloadToken: result.download_token,
          bundlePEM: result.bundle_pem,
        },
      }));

      setActionMessage(`Package ${createdPackage.label} issued. Download token expires at ${formatDate(createdPackage.download_token_expires_at)}.`);
      setFormOpen(false);
      resetForm();
    } catch (err) {
      console.error('Failed to create edge package', err);
      setFormError(err instanceof Error ? err.message : 'Failed to create package');
    } finally {
      setFormSubmitting(false);
    }
  };

  const handleSelect = (pkg: EdgePackage) => {
    setSelectedId(pkg.package_id);
  };

  const updatePackageInState = (updated: EdgePackage) => {
    setPackages((prev) =>
      prev.map((pkg) => (pkg.package_id === updated.package_id ? updated : pkg)),
    );
  };

  const handleDownload = async (pkg: EdgePackage, providedToken?: string) => {
    setActionError(null);
    setActionMessage(null);

    let downloadToken = providedToken ?? secrets[pkg.package_id]?.downloadToken ?? '';
    if (!downloadToken) {
      const input = window.prompt(
        `Enter the download token for package "${pkg.label}" (download is single-use).`,
      );
      downloadToken = input?.trim() ?? '';
    }
    if (!downloadToken) {
      return;
    }

    setActionLoading(true);
    try {
      const response = await fetch(`/api/admin/edge-packages/${pkg.package_id}/download`, {
        method: 'POST',
        headers: buildHeaders('application/json', 'application/gzip'),
        body: JSON.stringify({ download_token: downloadToken }),
      });
      if (!response.ok) {
        const message = await response.text();
        throw new Error(message || 'Failed to download package archive');
      }

      const blob = await response.blob();
      const filename =
        parseContentDisposition(response.headers.get('Content-Disposition')) ??
        `edge-package-${pkg.package_id}.tar.gz`;

      const url = URL.createObjectURL(blob);
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = filename;
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();
      URL.revokeObjectURL(url);

      setActionMessage(`Package ${pkg.label} archive downloaded. Token consumed.`);
      setSecrets((prev) => {
        const next = { ...prev };
        if (next[pkg.package_id]) {
          next[pkg.package_id] = {
            ...next[pkg.package_id],
            downloadToken: '',
          };
        }
        return next;
      });

      await loadPackages();
      if (pkg.package_id === selectedId) {
        await loadEvents(pkg.package_id);
      }
    } catch (err) {
      console.error('Failed to download edge package', err);
      setActionError(err instanceof Error ? err.message : 'Failed to download package');
    } finally {
      setActionLoading(false);
    }
  };

  const handleRevoke = async (pkg: EdgePackage) => {
    setActionError(null);
    setActionMessage(null);

    const confirmed = window.confirm(
      `Revoke package "${pkg.label}"? This deletes the downstream SPIRE entry and invalidates outstanding artifacts.`,
    );
    if (!confirmed) {
      return;
    }

    setActionLoading(true);
    try {
      const wasSelected = pkg.package_id === selectedId;
      const response = await fetch(`/api/admin/edge-packages/${pkg.package_id}/revoke`, {
        method: 'POST',
        headers: buildHeaders('application/json', 'application/json'),
        body: JSON.stringify({}),
      });
      if (!response.ok) {
        const message = await response.text();
        throw new Error(message || 'Failed to revoke package');
      }

      const updated: EdgePackage = await response.json();
      updatePackageInState(updated);
      setSecrets((prev) => {
        const next = { ...prev };
        if (next[updated.package_id]) {
          delete next[updated.package_id];
        }
        return next;
      });
      setActionMessage(`Package ${updated.label} revoked.`);

      if (wasSelected) {
        setSelectedId(updated.package_id);
      }

      await loadPackages();

      if (wasSelected) {
        await loadEvents(updated.package_id);
      }
    } catch (err) {
      console.error('Failed to revoke package', err);
      setActionError(err instanceof Error ? err.message : 'Failed to revoke package');
    } finally {
      setActionLoading(false);
    }
  };

  const handleDelete = async (pkg: EdgePackage) => {
    setActionError(null);
    setActionMessage(null);

    const confirmed = window.confirm(
      `Permanently delete package "${pkg.label}"? This removes its audit history and cannot be undone.`,
    );
    if (!confirmed) {
      return;
    }

    setActionLoading(true);
    try {
      const response = await fetch(`/api/admin/edge-packages/${pkg.package_id}`, {
        method: 'DELETE',
        headers: buildHeaders(),
      });
      if (!response.ok) {
        const message = await response.text();
        throw new Error(message || 'Failed to delete package');
      }

      setPackages((prev) => prev.filter((item) => item.package_id !== pkg.package_id));
      setSecrets((prev) => {
        const next = { ...prev };
        delete next[pkg.package_id];
        return next;
      });

      if (selectedId === pkg.package_id) {
        setSelectedId(null);
        setEvents([]);
      }

      setActionMessage(`Package ${pkg.label} deleted.`);
      await loadPackages();
    } catch (err) {
      console.error('Failed to delete edge package', err);
      setActionError(err instanceof Error ? err.message : 'Failed to delete package');
    } finally {
      setActionLoading(false);
    }
  };

  const copyToClipboard = async (text: string, description: string) => {
    try {
      await navigator.clipboard.writeText(text);
      setActionMessage(`${description} copied to clipboard.`);
    } catch (err) {
      console.error('Copy failed', err);
      setActionError(`Unable to copy ${description}.`);
    }
  };

  const selectedSecrets = selectedPackage ? secrets[selectedPackage.package_id] : null;

  return (
    <RoleGuard requiredRoles={['admin']}>
      <div className="flex h-full flex-col p-6 space-y-6 overflow-hidden">
        <header className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-start gap-3">
            <div className="rounded-full bg-blue-100 p-2 dark:bg-blue-900/40">
              <ShieldPlus className="h-6 w-6 text-blue-600 dark:text-blue-200" />
            </div>
            <div>
              <h1 className="text-2xl font-semibold">Edge Onboarding Packages</h1>
              <p className="text-sm text-muted-foreground">
                Issue, download, and revoke poller, agent, and checker installers backed by nested SPIRE.
              </p>
            </div>
          </div>
          <div className="flex flex-wrap items-center gap-3">
            <button
              type="button"
              onClick={() => openFormFor(formState.componentType || 'poller')}
              className="inline-flex items-center gap-2 rounded-md border border-transparent bg-blue-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2"
            >
              <Plus className="h-4 w-4" />
              Issue edge package
            </button>
            <button
              type="button"
              onClick={() => {
                setActionMessage(null);
                setActionError(null);
                void loadPackages();
              }}
              className="inline-flex items-center gap-2 rounded-md border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700 shadow-sm hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 dark:bg-gray-900 dark:text-gray-200 dark:border-gray-700 dark:hover:bg-gray-800"
              disabled={loading}
            >
              {loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />}
              Refresh
            </button>
          </div>
        </header>

        {actionMessage && (
          <div className="rounded-md border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-800 dark:border-emerald-900/40 dark:bg-emerald-900/20 dark:text-emerald-100">
            {actionMessage}
          </div>
        )}
        {actionError && (
          <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900/40 dark:bg-red-900/20 dark:text-red-100">
            {actionError}
          </div>
        )}

        {formOpen && (
          <div className="rounded-lg border border-gray-200 bg-white shadow-sm dark:border-gray-700 dark:bg-gray-900">
            <form onSubmit={handleCreate} className="space-y-6 p-6">
              <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                <div className="flex items-center gap-2">
                  <PackageIcon className="h-5 w-5 text-blue-500" />
                  <h2 className="text-lg font-semibold">Issue new installer</h2>
                </div>
                <button
                  type="submit"
                  className="inline-flex items-center gap-2 self-start rounded-md border border-transparent bg-blue-600 px-3 py-2 text-sm font-medium text-white shadow-sm hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 disabled:opacity-70 sm:self-auto"
                  disabled={formSubmitting}
                >
                  {formSubmitting ? <Loader2 className="h-4 w-4 animate-spin" /> : <Check className="h-4 w-4" />}
                  Issue package
                </button>
              </div>

              <div className="grid gap-4 sm:grid-cols-2">
                <label className="flex flex-col gap-1 text-sm">
                  <span className="font-medium">
                    Label <span className="text-red-500">*</span>
                  </span>
                  <input
                    required
                    className="rounded border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:bg-gray-950 dark:border-gray-700"
                    value={formState.label}
                    onChange={(event) => handleFormChange('label', event.target.value)}
                    placeholder="Edge component label"
                  />
                </label>

                <label className="flex flex-col gap-1 text-sm">
                  <span className="font-medium">
                    Component type <span className="text-red-500">*</span>
                  </span>
                  <select
                    className="rounded border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:bg-gray-950 dark:border-gray-700"
                    value={formState.componentType || 'poller'}
                    onChange={(event) => handleComponentTypeChange(event.target.value as EdgeComponentType)}
                  >
                    <option value="poller">Poller</option>
                    <option value="agent">Agent</option>
                    <option value="checker">Checker</option>
                  </select>
                </label>
              </div>

              <div className="grid gap-4 sm:grid-cols-2">
                <label className="flex flex-col gap-1 text-sm">
                  <span className="font-medium">Component ID (optional)</span>
                  <input
                    className="rounded border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:bg-gray-950 dark:border-gray-700"
                    value={formState.componentId}
                    onChange={(event) => handleFormChange('componentId', event.target.value)}
                    placeholder="Auto-generated from label if omitted"
                  />
                </label>

                {formState.componentType === 'agent' ? (
                  <div className="flex flex-col gap-1 text-sm">
                    <span className="font-medium">Parent poller</span>
                    <p className="rounded border border-dashed border-gray-300 px-3 py-2 text-sm text-gray-600 dark:border-gray-700 dark:text-gray-300">
                      Select or enter the poller identifier this agent will attach to.
                    </p>
                  </div>
                ) : (
                  <label className="flex flex-col gap-1 text-sm">
                    <span className="font-medium">
                      Poller ID {formState.componentType === 'checker' ? '(optional override)' : '(optional)'}
                    </span>
                    <input
                      className="rounded border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:bg-gray-950 dark:border-gray-700"
                      value={formState.pollerId}
                      onChange={(event) => handleFormChange('pollerId', event.target.value)}
                      placeholder="Will be generated if omitted"
                    />
                  </label>
                )}
              </div>

              {formState.componentType !== 'poller' && (
                <div className="grid gap-4 sm:grid-cols-2">
                  <label className="flex flex-col gap-1 text-sm">
                    <span className="font-medium">
                      {formState.componentType === 'checker' ? 'Parent agent ID' : 'Parent poller ID'}{' '}
                      <span className="text-red-500">*</span>
                    </span>
                    <input
                      required
                      className="rounded border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:bg-gray-950 dark:border-gray-700"
                      value={formState.parentId}
                      onChange={(event) => handleFormChange('parentId', event.target.value)}
                      placeholder={
                        formState.componentType === 'checker'
                          ? 'Select or enter the agent that will own this checker'
                          : 'Select or enter the poller this agent belongs to'
                      }
                      list={formState.componentType === 'checker' ? parentAgentListId : parentPollerListId}
                    />
                    {formState.componentType === 'checker' && (
                      <datalist id={parentAgentListId}>
                        {agentIds.map((id) => (
                          <option value={id} key={`parent-agent-${id}`} />
                        ))}
                      </datalist>
                    )}
                    {formState.componentType === 'agent' && (
                      <datalist id={parentPollerListId}>
                        {pollerIds.map((id) => (
                          <option value={id} key={`parent-poller-${id}`} />
                        ))}
                      </datalist>
                    )}
                  </label>
                  <div className="flex flex-col gap-1 text-xs text-gray-600 dark:text-gray-300">
                    <span className="font-medium">Parent lookup</span>
                    <p>
                      Start typing to search existing {formState.componentType === 'checker' ? 'agents' : 'pollers'} or
                      paste an identifier to reference a component that has not been onboarded yet.
                    </p>
                  </div>
                </div>
              )}

              <div className="grid gap-4 sm:grid-cols-2">
                <label className="flex flex-col gap-1 text-sm">
                  <span className="font-medium">Site (optional)</span>
                  <input
                    className="rounded border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:bg-gray-950 dark:border-gray-700"
                    value={formState.site}
                    onChange={(event) => handleFormChange('site', event.target.value)}
                    placeholder="Edge location or facility"
                  />
                </label>

                <label className="flex flex-col gap-1 text-sm">
                  <span className="font-medium">Downstream SPIFFE ID (optional)</span>
                  <input
                    className="rounded border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:bg-gray-950 dark:border-gray-700"
                    value={formState.downstreamSPIFFEID}
                    onChange={(event) => handleFormChange('downstreamSPIFFEID', event.target.value)}
                    placeholder="Override default template"
                  />
                </label>
              </div>

              <div className="grid gap-4 sm:grid-cols-2">
                <label className="flex flex-col gap-1 text-sm">
                  <span className="font-medium">Join token TTL (minutes)</span>
                  <input
                    type="number"
                    min="0"
                    className="rounded border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:bg-gray-950 dark:border-gray-700"
                    value={formState.joinTTLMinutes}
                    onChange={(event) => handleFormChange('joinTTLMinutes', event.target.value)}
                  />
                </label>

                <label className="flex flex-col gap-1 text-sm">
                  <span className="font-medium">Download token TTL (minutes)</span>
                  <input
                    type="number"
                    min="0"
                    className="rounded border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:bg-gray-950 dark:border-gray-700"
                    value={formState.downloadTTLMinutes}
                    onChange={(event) => handleFormChange('downloadTTLMinutes', event.target.value)}
                  />
                </label>
              </div>

              <label className="flex flex-col gap-1 text-sm">
                <span className="font-medium">SPIRE selectors (newline or comma separated)</span>
                <textarea
                  rows={3}
                  className="rounded border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:bg-gray-950 dark:border-gray-700"
                  value={formState.selectors}
                  onChange={(event) => handleFormChange('selectors', event.target.value)}
                  placeholder="k8s_psat:cluster:demo&#10;unix:group:root"
                />
              </label>

              <label className="flex flex-col gap-1 text-sm">
                <span className="font-medium">Metadata JSON (optional)</span>
                <textarea
                  rows={3}
                  className="rounded border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:bg-gray-950 dark:border-gray-700"
                  value={formState.metadataJSON}
                  onChange={(event) => handleFormChange('metadataJSON', event.target.value)}
                  placeholder='{"asset_id": "edge-01"}'
                />
              </label>

              <label className="flex flex-col gap-1 text-sm">
                <span className="font-medium">Notes (optional)</span>
                <textarea
                  rows={2}
                  className="rounded border border-gray-300 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:bg-gray-950 dark:border-gray-700"
                  value={formState.notes}
                  onChange={(event) => handleFormChange('notes', event.target.value)}
                  placeholder="Additional operator guidance"
                />
              </label>

              {formError && (
                <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-700 dark:border-red-900/40 dark:bg-red-900/20 dark:text-red-100">
                  {formError}
                </div>
              )}

              <div className="flex justify-end gap-3">
                <button
                  type="button"
                  className="rounded-md border border-gray-300 px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
                  onClick={() => {
                    setFormOpen(false);
                    resetForm();
                  }}
                  disabled={formSubmitting}
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  className="inline-flex items-center gap-2 rounded-md border border-transparent bg-blue-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 disabled:opacity-70"
                  disabled={formSubmitting}
                >
                  {formSubmitting ? <Loader2 className="h-4 w-4 animate-spin" /> : <Check className="h-4 w-4" />}
                  Issue package
                </button>
              </div>
            </form>
          </div>
        )}

        {error && (
          <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900/40 dark:bg-red-900/20 dark:text-red-100">
            {error}
          </div>
        )}

        <div className="flex flex-1 flex-col gap-6 overflow-hidden">
          <div className="flex-1 overflow-hidden rounded-lg border border-gray-200 bg-white shadow-sm dark:border-gray-700 dark:bg-gray-900">
            <div className="max-h-96 overflow-auto">
              <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-800">
                <thead className="bg-gray-50 dark:bg-gray-950">
                  <tr>
                    <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400">
                      Label
                    </th>
                    <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400">
                      Component
                    </th>
                    <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400">
                      Poller ID
                    </th>
                    <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400">
                      Status
                    </th>
                    <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400">
                      Site
                    </th>
                    <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400">
                      Updated
                    </th>
                    <th className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400">
                      Actions
                    </th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-gray-200 bg-white dark:divide-gray-800 dark:bg-gray-900">
                  {!loading && packages.length === 0 && (
                    <tr>
                      <td colSpan={7} className="px-4 py-6 text-center text-sm text-gray-500 dark:text-gray-400">
                        No edge packages yet. Issue one to bootstrap your first edge component.
                      </td>
                    </tr>
                  )}

                  {packages.map((pkg) => {
                    const statusClass = getStatusBadgeClass(pkg.status);
                    const isSelected = selectedId === pkg.package_id;
                    const parentLabel =
                      pkg.component_type === 'checker'
                        ? 'Parent agent'
                        : pkg.component_type === 'agent'
                        ? 'Parent poller'
                        : '';
                    const relationship =
                      pkg.component_type === 'checker'
                        ? `Poller: ${pkg.poller_id || '—'}`
                        : pkg.component_type === 'agent'
                        ? `Poller: ${pkg.parent_id || pkg.poller_id || '—'}`
                        : '';
                    return (
                      <tr
                        key={pkg.package_id}
                        className={`cursor-pointer hover:bg-blue-50/60 dark:hover:bg-blue-900/20 ${
                          isSelected ? 'bg-blue-50 dark:bg-blue-900/20' : ''
                        }`}
                        onClick={() => handleSelect(pkg)}
                      >
                        <td className="whitespace-nowrap px-4 py-3 text-sm font-medium text-gray-900 dark:text-gray-100">
                          {pkg.label}
                        </td>
                        <td className="px-4 py-3 text-sm text-gray-600 dark:text-gray-300">
                          <div className="flex flex-col gap-1">
                            <span className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">
                              {titleCase(pkg.component_type || 'poller')}
                            </span>
                            <code className="inline-flex w-fit items-center rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-700 dark:bg-slate-800 dark:text-slate-200">
                              {pkg.component_id || '—'}
                            </code>
                            {pkg.parent_id && parentLabel ? (
                              <span className="text-xs text-gray-500 dark:text-gray-400">
                                {parentLabel}:{' '}
                                <code className="rounded bg-slate-100 px-1 py-0.5 text-[11px] text-slate-700 dark:bg-slate-800 dark:text-slate-200">
                                  {pkg.parent_id}
                                </code>
                              </span>
                            ) : null}
                            {relationship && (
                              <span className="text-xs text-gray-500 dark:text-gray-400">{relationship}</span>
                            )}
                          </div>
                        </td>
                        <td className="px-4 py-3 text-sm text-gray-600 dark:text-gray-300">
                          <code className="rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-700 dark:bg-slate-800 dark:text-slate-200">
                            {pkg.poller_id}
                          </code>
                        </td>
                        <td className="px-4 py-3 text-sm text-gray-600 dark:text-gray-300">
                          <span className={`inline-flex items-center rounded-full px-2.5 py-1 text-xs font-semibold ${statusClass}`}>
                            {titleCase(pkg.status)}
                          </span>
                        </td>
                        <td className="px-4 py-3 text-sm text-gray-600 dark:text-gray-300">
                          {pkg.site || '—'}
                        </td>
                        <td className="px-4 py-3 text-sm text-gray-600 dark:text-gray-300">
                          {formatDate(pkg.updated_at)}
                        </td>
                        <td className="px-4 py-3 text-sm text-gray-600 dark:text-gray-300">
                          <div className="flex gap-2">
                            <button
                              type="button"
                              className="inline-flex items-center gap-1 rounded border border-gray-300 px-2 py-1 text-xs text-gray-700 hover:bg-gray-100 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
                              onClick={(event) => {
                                event.stopPropagation();
                                void handleDownload(pkg);
                              }}
                              disabled={
                                actionLoading || pkg.status !== 'issued'
                              }
                              title={
                                pkg.status !== 'issued'
                                  ? 'Download token already consumed'
                                  : 'Download installer (single-use)'
                              }
                            >
                              {actionLoading ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Download className="h-3.5 w-3.5" />}
                              Download
                            </button>
                            <button
                              type="button"
                              className="inline-flex items-center gap-1 rounded border border-red-200 px-2 py-1 text-xs text-red-600 hover:bg-red-50 dark:border-red-900/40 dark:text-red-300 dark:hover:bg-red-900/10"
                              onClick={(event) => {
                                event.stopPropagation();
                                void handleRevoke(pkg);
                              }}
                              disabled={
                                actionLoading ||
                                pkg.status === 'revoked' ||
                                pkg.status === 'expired'
                              }
                              title="Revoke package"
                            >
                              <Ban className="h-3.5 w-3.5" />
                              Revoke
                            </button>
                            {pkg.status === 'revoked' && (
                              <button
                                type="button"
                                className="inline-flex items-center gap-1 rounded border border-red-300 px-2 py-1 text-xs text-red-600 hover:bg-red-50 dark:border-red-900/40 dark:text-red-300 dark:hover:bg-red-900/10"
                                onClick={(event) => {
                                  event.stopPropagation();
                                  void handleDelete(pkg);
                                }}
                                disabled={actionLoading}
                                title="Delete package"
                              >
                                <Trash2 className="h-3.5 w-3.5" />
                                Delete
                              </button>
                            )}
                          </div>
                        </td>
                      </tr>
                    );
                  })}

                  {loading && (
                    <tr>
                      <td colSpan={7} className="px-4 py-6 text-center text-sm text-gray-500 dark:text-gray-400">
                        <div className="flex items-center justify-center gap-2">
                          <Loader2 className="h-4 w-4 animate-spin" />
                          Loading packages…
                        </div>
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
          </div>

          <div className="grid flex-1 grid-cols-1 gap-6 lg:grid-cols-3">
            <div className="space-y-6 lg:col-span-2">
              <div className="rounded-lg border border-gray-200 bg-white p-5 shadow-sm dark:border-gray-700 dark:bg-gray-900">
                {!selectedPackage ? (
                  <div className="flex flex-col items-center justify-center gap-3 py-10 text-center text-gray-500 dark:text-gray-400">
                    <Network className="h-8 w-8" />
                    <p>Select a package to view details, download artifacts, and inspect the audit log.</p>
                  </div>
                ) : (
                  <div className="space-y-5">
                    <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                      <div>
                        <h2 className="text-xl font-semibold">{selectedPackage.label}</h2>
                        <p className="text-sm text-muted-foreground">
                          Package ID{' '}
                          <code className="rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-700 dark:bg-slate-800 dark:text-slate-200">
                            {selectedPackage.package_id}
                          </code>
                        </p>
                      </div>
                      <span className={`inline-flex items-center rounded-full px-3 py-1 text-xs font-semibold ${getStatusBadgeClass(selectedPackage.status)}`}>
                        {titleCase(selectedPackage.status)}
                      </span>
                    </div>

                    <div className="flex flex-wrap items-center gap-2">
                      <button
                        type="button"
                        className="inline-flex items-center gap-2 rounded border border-gray-300 px-3 py-1.5 text-xs font-medium text-gray-700 hover:bg-gray-100 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
                        onClick={() => setSelectedId(null)}
                      >
                        Back to list
                      </button>
                      {selectedPackage.status === 'revoked' && (
                        <button
                          type="button"
                          className="inline-flex items-center gap-2 rounded border border-red-300 px-3 py-1.5 text-xs font-medium text-red-600 hover:bg-red-50 focus:outline-none focus:ring-2 focus:ring-red-500 focus:ring-offset-2 dark:border-red-900/40 dark:text-red-300 dark:hover:bg-red-900/10"
                          onClick={() => void handleDelete(selectedPackage)}
                          disabled={actionLoading}
                        >
                          <Trash2 className="h-3.5 w-3.5" />
                          Delete package
                        </button>
                      )}
                    </div>

                    <dl className="grid gap-4 sm:grid-cols-2">
                      <div>
                        <dt className="text-xs uppercase text-gray-500 dark:text-gray-400">Component type</dt>
                        <dd className="mt-1 text-sm text-gray-900 dark:text-gray-100">
                          {titleCase(selectedPackage.component_type || 'poller')}
                        </dd>
                      </div>
                      <div>
                        <dt className="text-xs uppercase text-gray-500 dark:text-gray-400">Component ID</dt>
                        <dd className="mt-1 text-sm text-gray-900 dark:text-gray-100">
                          <code className="rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-700 dark:bg-slate-800 dark:text-slate-200">
                            {selectedPackage.component_id}
                          </code>
                        </dd>
                      </div>
                      {selectedPackage.parent_id ? (
                        <div>
                          <dt className="text-xs uppercase text-gray-500 dark:text-gray-400">Parent component</dt>
                          <dd className="mt-1 text-sm text-gray-900 dark:text-gray-100">
                            <div className="flex flex-col gap-1">
                              <span>{titleCase(selectedPackage.parent_type || '') || 'Unknown'}</span>
                              <code className="w-fit rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-700 dark:bg-slate-800 dark:text-slate-200">
                                {selectedPackage.parent_id}
                              </code>
                            </div>
                          </dd>
                        </div>
                      ) : null}
                      <div className="sm:col-span-2">
                        <dt className="text-xs uppercase text-gray-500 dark:text-gray-400">Relationship</dt>
                        <dd className="mt-1 text-sm text-gray-900 dark:text-gray-100">
                          {selectedPackage.component_type === 'checker'
                            ? `Checker → Agent (${selectedPackage.parent_id || '—'}) → Poller (${
                                selectedPackage.poller_id || '—'
                              })`
                            : selectedPackage.component_type === 'agent'
                            ? `Agent → Poller (${selectedPackage.parent_id || selectedPackage.poller_id || '—'})`
                            : 'Poller (no parent component)'}
                        </dd>
                      </div>
                      <div>
                        <dt className="text-xs uppercase text-gray-500 dark:text-gray-400">Poller ID</dt>
                        <dd className="mt-1 text-sm text-gray-900 dark:text-gray-100">
                          <code className="rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-700 dark:bg-slate-800 dark:text-slate-200">
                            {selectedPackage.poller_id}
                          </code>
                        </dd>
                      </div>
                      <div>
                        <dt className="text-xs uppercase text-gray-500 dark:text-gray-400">Site</dt>
                        <dd className="mt-1 text-sm text-gray-900 dark:text-gray-100">{selectedPackage.site || '—'}</dd>
                      </div>
                      <div>
                        <dt className="text-xs uppercase text-gray-500 dark:text-gray-400">Downstream SPIFFE ID</dt>
                        <dd className="mt-1 text-sm text-gray-900 dark:text-gray-100 break-all">{selectedPackage.downstream_spiffe_id}</dd>
                      </div>
                      <div>
                        <dt className="text-xs uppercase text-gray-500 dark:text-gray-400">Join token expires</dt>
                        <dd className="mt-1 text-sm text-gray-900 dark:text-gray-100">{formatDate(selectedPackage.join_token_expires_at)}</dd>
                      </div>
                      <div>
                        <dt className="text-xs uppercase text-gray-500 dark:text-gray-400">Download token expires</dt>
                        <dd className="mt-1 text-sm text-gray-900 dark:text-gray-100">{formatDate(selectedPackage.download_token_expires_at)}</dd>
                      </div>
                      <div>
                        <dt className="text-xs uppercase text-gray-500 dark:text-gray-400">Created by</dt>
                        <dd className="mt-1 text-sm text-gray-900 dark:text-gray-100">{selectedPackage.created_by || '—'}</dd>
                      </div>
                      <div>
                        <dt className="text-xs uppercase text-gray-500 dark:text-gray-400">Delivered at</dt>
                        <dd className="mt-1 text-sm text-gray-900 dark:text-gray-100">{formatDate(selectedPackage.delivered_at)}</dd>
                      </div>
                      <div>
                        <dt className="text-xs uppercase text-gray-500 dark:text-gray-400">Activated at</dt>
                        <dd className="mt-1 text-sm text-gray-900 dark:text-gray-100">{formatDate(selectedPackage.activated_at)}</dd>
                      </div>
                      <div>
                        <dt className="text-xs uppercase text-gray-500 dark:text-gray-400">Revoked at</dt>
                        <dd className="mt-1 text-sm text-gray-900 dark:text-gray-100">{formatDate(selectedPackage.revoked_at)}</dd>
                      </div>
                      <div>
                        <dt className="text-xs uppercase text-gray-500 dark:text-gray-400">Deleted at</dt>
                        <dd className="mt-1 text-sm text-gray-900 dark:text-gray-100">{formatDate(selectedPackage.deleted_at)}</dd>
                      </div>
                      <div>
                        <dt className="text-xs uppercase text-gray-500 dark:text-gray-400">Activated from IP</dt>
                        <dd className="mt-1 text-sm text-gray-900 dark:text-gray-100">{selectedPackage.activated_from_ip || '—'}</dd>
                      </div>
                      <div>
                        <dt className="text-xs uppercase text-gray-500 dark:text-gray-400">Last seen SPIFFE ID</dt>
                        <dd className="mt-1 text-sm text-gray-900 dark:text-gray-100 break-all">{selectedPackage.last_seen_spiffe_id || '—'}</dd>
                      </div>
                      <div>
                        <dt className="text-xs uppercase text-gray-500 dark:text-gray-400">Notes</dt>
                        <dd className="mt-1 text-sm text-gray-900 dark:text-gray-100 whitespace-pre-wrap">{selectedPackage.notes || '—'}</dd>
                      </div>
                      <div>
                        <dt className="text-xs uppercase text-gray-500 dark:text-gray-400">Selectors</dt>
                        <dd className="mt-1 flex flex-wrap gap-2">
                          {selectedPackage.selectors?.length
                            ? selectedPackage.selectors.map((selector) => (
                                <span key={selector} className="rounded bg-slate-100 px-2 py-0.5 text-xs text-slate-700 dark:bg-slate-800 dark:text-slate-200">
                                  {selector}
                                </span>
                              ))
                            : '—'}
                        </dd>
                      </div>
                    </dl>

                    {selectedPackage.metadata_json && (
                      <div className="rounded-md border border-gray-200 bg-gray-50 p-3 text-sm text-gray-700 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-200">
                        <span className="block text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">
                          Metadata JSON
                        </span>
                        <pre className="mt-2 overflow-auto whitespace-pre-wrap text-xs">
                          {selectedPackage.metadata_json}
                        </pre>
                      </div>
                    )}
                  </div>
                )}
              </div>

              <div className="rounded-lg border border-gray-200 bg-white shadow-sm dark:border-gray-700 dark:bg-gray-900">
                <div className="flex items-center justify-between border-b border-gray-200 px-5 py-3 dark:border-gray-800">
                  <h3 className="flex items-center gap-2 text-sm font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300">
                    <CalendarClock className="h-4 w-4" />
                    Audit log
                  </h3>
                  {selectedPackage && (
                    <button
                      type="button"
                      className="inline-flex items-center gap-1 rounded border border-gray-300 px-3 py-1 text-xs text-gray-700 hover:bg-gray-100 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
                      onClick={() => {
                        if (selectedPackage) {
                          void loadEvents(selectedPackage.package_id);
                        }
                      }}
                    >
                      <RefreshCw className="h-3.5 w-3.5" />
                      Refresh
                    </button>
                  )}
                </div>
                <div className="max-h-64 overflow-auto px-5 py-4">
                  {!selectedPackage ? (
                    <p className="text-sm text-gray-500 dark:text-gray-400">Select a package to inspect its audit history.</p>
                  ) : eventsLoading ? (
                    <div className="flex items-center gap-2 text-sm text-gray-500 dark:text-gray-400">
                      <Loader2 className="h-4 w-4 animate-spin" />
                      Loading events…
                    </div>
                  ) : eventsError ? (
                    <p className="text-sm text-red-600 dark:text-red-400">{eventsError}</p>
                  ) : events.length === 0 ? (
                    <p className="text-sm text-gray-500 dark:text-gray-400">No events recorded yet.</p>
                  ) : (
                    <ul className="space-y-4 text-sm text-gray-700 dark:text-gray-200">
                      {events.map((event, index) => {
                        const detailObject = parseDetails(event.details_json);
                        return (
                          <li key={`${event.event_time}-${index}`} className="rounded border border-gray-200 p-3 dark:border-gray-800">
                            <div className="flex items-center justify-between">
                              <span className="font-medium">{titleCase(event.event_type)}</span>
                              <span className="text-xs text-gray-500 dark:text-gray-400">
                                {formatDate(event.event_time)}
                              </span>
                            </div>
                            <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">
                              Actor: {event.actor || 'unknown'}
                              {event.source_ip ? ` · IP ${event.source_ip}` : ''}
                            </div>
                            {detailObject && (
                              <pre className="mt-2 rounded bg-slate-100 p-2 text-xs text-slate-700 dark:bg-slate-800 dark:text-slate-200">
                                {JSON.stringify(detailObject, null, 2)}
                              </pre>
                            )}
                          </li>
                        );
                      })}
                    </ul>
                  )}
                </div>
              </div>
            </div>

            <div className="space-y-6">
              <div className="rounded-lg border border-gray-200 bg-white p-5 shadow-sm dark:border-gray-700 dark:bg-gray-900">
                <h3 className="flex items-center gap-2 text-sm font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300">
                  <Link2 className="h-4 w-4" />
                  Installer artifacts
                </h3>

                {!selectedPackage ? (
                  <p className="mt-3 text-sm text-gray-500 dark:text-gray-400">
                    Select a package to access join tokens and bundles.
                  </p>
                ) : (
                  <div className="mt-4 space-y-4 text-sm text-gray-700 dark:text-gray-200">
                    {selectedSecrets ? (
                      <>
                        <div>
                          <div className="flex items-center justify-between">
                            <span className="font-medium">Join token</span>
                            <button
                              type="button"
                              className="inline-flex items-center gap-1 rounded border border-gray-300 px-2 py-1 text-xs text-gray-700 hover:bg-gray-100 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
                              onClick={() => copyToClipboard(selectedSecrets.joinToken, 'Join token')}
                            >
                              <Copy className="h-3.5 w-3.5" />
                              Copy
                            </button>
                          </div>
                          <p className="mt-1 break-all rounded bg-slate-100 px-2 py-1 text-xs text-slate-700 dark:bg-slate-800 dark:text-slate-200">
                            {selectedSecrets.joinToken || 'Unavailable (token already used)'}
                          </p>
                        </div>

                        <div>
                          <div className="flex items-center justify-between">
                            <span className="font-medium">Download token</span>
                            <button
                              type="button"
                              className="inline-flex items-center gap-1 rounded border border-gray-300 px-2 py-1 text-xs text-gray-700 hover:bg-gray-100 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
                              onClick={() => copyToClipboard(selectedSecrets.downloadToken, 'Download token')}
                              disabled={!selectedSecrets.downloadToken}
                            >
                              <Copy className="h-3.5 w-3.5" />
                              Copy
                            </button>
                          </div>
                          <p className="mt-1 break-all rounded bg-slate-100 px-2 py-1 text-xs text-slate-700 dark:bg-slate-800 dark:text-slate-200">
                            {selectedSecrets.downloadToken || 'Token already consumed.'}
                          </p>
                        </div>

                        <div>
                          <div className="flex items-center justify-between">
                            <span className="font-medium">SPIRE bundle (PEM)</span>
                            <button
                              type="button"
                              className="inline-flex items-center gap-1 rounded border border-gray-300 px-2 py-1 text-xs text-gray-700 hover:bg-gray-100 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
                              onClick={() => copyToClipboard(selectedSecrets.bundlePEM, 'SPIRE bundle')}
                            >
                              <Copy className="h-3.5 w-3.5" />
                              Copy
                            </button>
                          </div>
                          <pre className="mt-1 max-h-40 overflow-auto whitespace-pre-wrap rounded bg-slate-100 px-2 py-1 text-xs text-slate-700 dark:bg-slate-800 dark:text-slate-200">
                            {selectedSecrets.bundlePEM}
                          </pre>
                        </div>
                      </>
                    ) : (
                      <div className="flex items-start gap-2 rounded-md border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800 dark:border-amber-900/40 dark:bg-amber-900/20 dark:text-amber-100">
                        <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
                        <p>
                          This package was created outside the current session or its secrets have been cleared. Use{' '}
                          <code>serviceradar-cli edge package download</code> with the original download token to retrieve the archive.
                        </p>
                      </div>
                    )}

                    {selectedPackage.status === 'issued' && (
                      <button
                        type="button"
                        className="inline-flex w-full items-center justify-center gap-2 rounded-md border border-transparent bg-blue-600 px-3 py-2 text-sm font-medium text-white shadow-sm hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 disabled:opacity-70"
                        onClick={() => void handleDownload(selectedPackage, selectedSecrets?.downloadToken)}
                        disabled={actionLoading}
                      >
                        {actionLoading ? <Loader2 className="h-4 w-4 animate-spin" /> : <Download className="h-4 w-4" />}
                        Download archive
                      </button>
                    )}
                  </div>
                )}
              </div>

              <div className="rounded-lg border border-gray-200 bg-white p-5 shadow-sm dark:border-gray-700 dark:bg-gray-900">
                <h3 className="flex items-center gap-2 text-sm font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300">
                  <AlertTriangle className="h-4 w-4" />
                  Operational notes
                </h3>
                <ul className="mt-3 space-y-2 text-xs text-gray-600 dark:text-gray-300">
                  <li>
                    • Download tokens are single-use. Once consumed, regenerate a new package to refresh credentials.
                  </li>
                  <li>
                    • Join tokens expire quickly; ensure installers run immediately after retrieving the archive.
                  </li>
                  <li>
                    • Revoking a package deletes the downstream SPIRE entry and blocks the poller until a new install runs.
                  </li>
                </ul>
              </div>
            </div>
          </div>
        </div>
      </div>
    </RoleGuard>
  );
}
