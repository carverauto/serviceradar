"use client";

import React, { useEffect, useMemo, useState } from 'react';
import { ChevronRight, ChevronDown, Server, Cpu, Package, Settings } from 'lucide-react';
import KvInfoBadge from './KvInfoBadge';

export interface ServiceTreeService {
  name: string;
  type: string;
  agent_id: string;
  kv_store_id?: string;
}

export interface ServiceTreeAgent {
  agent_id: string;
  kv_store_ids?: string[];
  services: ServiceTreeService[];
}

export interface ServiceTreePoller {
  poller_id: string;
  is_healthy: boolean;
  kv_store_ids?: string[];
  agents: ServiceTreeAgent[];
}

export interface SelectedServiceInfo {
  id: string;
  name: string;
  type: string; // 'poller' | 'agent' | service type
  kvStore?: string; // kv_store_id
  pollerId?: string;
  agentId?: string;
}

type ConfigDescriptor = {
  name: string;
  display_name?: string;
  service_type: string;
  scope: string;
  kv_key?: string;
  kv_key_template?: string;
  format: string;
  requires_agent?: boolean;
};

const toTitleCase = (value: string) =>
  value
    .replace(/[-_]/g, ' ')
    .replace(/\b\w/g, (letter) => letter.toUpperCase());

interface Props {
  pollers?: ServiceTreePoller[];
  selected?: SelectedServiceInfo | null;
  onSelect: (s: SelectedServiceInfo) => void;
  filterPoller?: string;
  filterAgent?: string;
  filterService?: string;
  pageSize?: number; // services per agent page
}

export default function ServicesTreeNavigation({ pollers, selected, onSelect, filterPoller = '', filterAgent = '', filterService = '', pageSize = 200 }: Props) {
  const [expandedPollers, setExpandedPollers] = useState<Set<string>>(new Set());
  const [expandedAgents, setExpandedAgents] = useState<Set<string>>(new Set());
  const [loadingPollers, setLoadingPollers] = useState(false);
  const [tree, setTree] = useState<Record<string, ServiceTreePoller>>({});
  const [configDescriptors, setConfigDescriptors] = useState<ConfigDescriptor[]>([]);
  const globalServiceTypes = React.useMemo(
    () =>
      new Set(
        configDescriptors
          .filter((desc) => desc.scope === 'global')
          .map((desc) => desc.service_type),
      ),
    [configDescriptors],
  );
  const descriptorByType = React.useMemo(() => {
    const map = new Map<string, ConfigDescriptor>();
    configDescriptors.forEach((desc) => {
      map.set(desc.service_type, desc);
    });
    return map;
  }, [configDescriptors]);
  const getServiceLabel = React.useCallback(
    (serviceType: string) => {
      const desc = descriptorByType.get(serviceType);
      if (!desc) {
        return toTitleCase(serviceType);
      }
      if (desc.display_name) {
        return desc.display_name;
      }
      switch (desc.name) {
        case 'otel':
          return 'OTEL Collector';
        case 'db-event-writer':
          return 'DB Event Writer';
        case 'zen-consumer':
          return 'Zen Consumer';
        default:
          return toTitleCase(desc.name);
      }
    },
    [descriptorByType],
  );
  const filterGlobalServices = React.useCallback(
    (services: ServiceTreeService[] = []) => services.filter((svc) => !globalServiceTypes.has(svc.type)),
    [globalServiceTypes],
  );

  useEffect(() => {
    let cancelled = false;
    const fetchDescriptors = async () => {
      try {
        const token = document.cookie
          .split("; ")
          .find((row) => row.startsWith("accessToken="))
          ?.split("=")[1];
        const resp = await fetch('/api/admin/config', { headers: token ? { 'Authorization': `Bearer ${token}` } : {} });
        if (!resp.ok) return;
        const data = await resp.json();
        if (!cancelled) {
          setConfigDescriptors(Array.isArray(data) ? data : []);
        }
      } catch {
        // ignore
      }
    };
    fetchDescriptors();
    return () => { cancelled = true; };
  }, []);

  const [globalServices, setGlobalServices] = useState<string[]>([]);
  useEffect(() => {
    setGlobalServices(Array.from(globalServiceTypes));
  }, [globalServiceTypes]);

  // Global services (not scoped to agents/pollers)
  const [globalOpen, setGlobalOpen] = useState<boolean>(false);
  const [globalStatus, setGlobalStatus] = useState<Record<string, 'unknown' | 'configured' | 'missing'>>({});

  useEffect(() => {
    if (globalServices.length === 0) {
      return;
    }
    setGlobalStatus(prev => {
      const next = { ...prev };
      let mutated = false;
      globalServices.forEach((svc) => {
        if (!next[svc]) {
          next[svc] = 'unknown';
          mutated = true;
        }
      });
      return mutated ? next : prev;
    });
  }, [globalServices]);

  useEffect(() => {
    const loadStatus = async () => {
      try {
        const token = document.cookie
          .split("; ")
          .find((row) => row.startsWith("accessToken="))
          ?.split("=")[1];
        const headers: Record<string, string> = token ? { 'Authorization': `Bearer ${token}` } : {};
        const results: Record<string, 'configured' | 'missing' | 'unknown'> = {};
        await Promise.all(globalServices.map(async (svc) => {
          try {
            const resp = await fetch(`/api/admin/config/${svc}`, { headers });
            results[svc] = resp.ok ? 'configured' : 'missing';
          } catch {
            results[svc] = 'unknown';
          }
        }));
        setGlobalStatus(prev => ({ ...prev, ...results }));
      } catch {
        // ignore
      }
    };
    if (!globalOpen || globalServices.length === 0) {
      return;
    }
    const anyUnknown = globalServices.some((svc) => (globalStatus[svc] ?? 'unknown') === 'unknown');
    if (anyUnknown) loadStatus();
  }, [globalOpen, globalServices, globalStatus]);

  // Listen for config saves to update global status indicator immediately
  useEffect(() => {
    const onSaved = (e: Event) => {
      // @ts-expect-error Custom event with detail
      const detail = e.detail || {};
      const t = detail.serviceType as string | undefined;
      if (!t || !globalServiceTypes.has(t)) {
        return;
      }
      setGlobalStatus(prev => ({ ...prev, [t]: 'configured' }));
    };
    window.addEventListener('sr:config-saved', onSaved);
    return () => window.removeEventListener('sr:config-saved', onSaved);
  }, [globalServiceTypes]);
  // Track pagination offsets per agent
  const [agentOffsets, setAgentOffsets] = useState<Record<string, number>>({});
  const [agentHasMore, setAgentHasMore] = useState<Record<string, boolean>>({});
  const [openAddMenuFor, setOpenAddMenuFor] = useState<string | null>(null);
  // Measured available height with debounced resize
  const [listHeight, setListHeight] = useState(560);
  const containerRef = React.useRef<HTMLDivElement | null>(null);

  const debounce = <T extends unknown[]>(fn: (...args: T) => void, delay: number) => {
    let t: NodeJS.Timeout;
    return (...args: T) => { clearTimeout(t); t = setTimeout(() => fn(...args), delay); };
  };

  useEffect(() => {
    const update = () => {
      if (containerRef.current) {
        const h = containerRef.current.clientHeight;
        if (h && h !== listHeight) setListHeight(h);
      }
    };
    const debounced = debounce(update, 150);
    update();
    window.addEventListener('resize', debounced);
    let ro: ResizeObserver | null = null;
    if (typeof window !== 'undefined' && containerRef.current && 'ResizeObserver' in window) {
      ro = new ResizeObserver(() => debounced());
      ro.observe(containerRef.current);
    }
    return () => {
      window.removeEventListener('resize', debounced);
      if (ro) ro.disconnect();
    };
  }, [listHeight]);

  // Initial load: if no pollers provided, fetch pollers list
  useEffect(() => {
    if (pollers && pollers.length > 0) {
      const map: Record<string, ServiceTreePoller> = {};
      pollers.forEach(p => {
        map[p.poller_id] = {
          ...p,
          agents: (p.agents || []).map(agent => ({
            ...agent,
            services: filterGlobalServices(agent.services),
          })),
        };
      });
      setTree(map);
      return;
    }
    let cancelled = false;
    const fetchPollers = async () => {
      try {
        setLoadingPollers(true);
        const token = document.cookie
          .split("; ")
          .find((row) => row.startsWith("accessToken="))
          ?.split("=")[1];
        const resp = await fetch('/api/pollers', { headers: token ? { 'Authorization': `Bearer ${token}` } : {} });
        const data = resp.ok ? await resp.json() : [];
        if (cancelled) return;
        const map: Record<string, ServiceTreePoller> = {};
        (data || []).forEach((p: ServiceTreePoller) => { map[p.poller_id] = { poller_id: p.poller_id, is_healthy: p.is_healthy, agents: [] } });
        setTree(map);
      } finally { setLoadingPollers(false); }
    };
    fetchPollers();
    return () => { cancelled = true; };
  }, [pollers, filterGlobalServices]);

  // No domain selection here; global services target the default KV (hub) unless overridden in editor.

  const togglePoller = async (id: string) => {
    const s = new Set(expandedPollers);
    if (s.has(id)) {
      s.delete(id);
    } else {
      s.add(id);
    }
    setExpandedPollers(s);
    // Lazy-load agents/services for this poller if not already loaded
    if (!tree[id] || (tree[id].agents && tree[id].agents.length > 0)) return;
    const qp = new URLSearchParams({ poller: id });
    const token = document.cookie
      .split("; ")
      .find((row) => row.startsWith("accessToken="))
      ?.split("=")[1];
    const resp = await fetch(`/api/services/tree?${qp.toString()}`, { headers: token ? { 'Authorization': `Bearer ${token}` } : {} });
    if (!resp.ok) return;
    const arr = await resp.json();
    const node = (arr && arr.length) ? arr[0] : null;
    if (!node) return;
    setTree(prev => ({
      ...prev,
      [id]: {
        ...node,
        agents: (node.agents || []).map((agent: ServiceTreeAgent) => ({
          ...agent,
          services: filterGlobalServices(agent.services),
        })),
      },
    }));
  };

  const toggleAgent = async (pollerId: string, agentId: string) => {
    const key = `${pollerId}:${agentId}`;
    const s = new Set(expandedAgents);
    if (s.has(key)) {
      s.delete(key);
    } else {
      s.add(key);
    }
    setExpandedAgents(s);
    // If agent services are empty, fetch first page
    const poller = tree[pollerId];
    if (!poller) return;
    const agent = (poller.agents || []).find(a => a.agent_id === agentId);
    if (agent && agent.services && agent.services.length > 0) return;
    await loadMoreServices(pollerId, agentId);
  };

  const loadMoreServices = async (pollerId: string, agentId: string) => {
    const k = `${pollerId}:${agentId}`;
    const currentOffset = agentOffsets[k] || 0;
    const qp = new URLSearchParams({ poller: pollerId, agent: agentId, limit: String(pageSize), offset: String(currentOffset), configured: 'only' });
    const token = document.cookie
      .split("; ")
      .find((row) => row.startsWith("accessToken="))
      ?.split("=")[1];
    const resp = await fetch(`/api/services/tree?${qp.toString()}`, { headers: token ? { 'Authorization': `Bearer ${token}` } : {} });
    if (!resp.ok) return;
    const arr = await resp.json();
    const node = (arr && arr.length) ? arr[0] : null;
    if (!node) return;
    const freshAgent = (node.agents || []).find((a: ServiceTreeAgent) => a.agent_id === agentId);
    if (!freshAgent) return;
    // Mark hasMore for this agent based on returned page size
    const rawServices = freshAgent.services || [];
    const filteredServices = filterGlobalServices(rawServices);
    const pageCount = rawServices.length;
    setAgentHasMore(prev => ({ ...prev, [k]: pageCount >= pageSize }));
    setTree(prev => {
      const p = prev[pollerId] || { poller_id: pollerId, is_healthy: true, agents: [] };
      const agents = [...(p.agents || [])];
      const idx = agents.findIndex(a => a.agent_id === agentId);
      if (idx >= 0) {
        const merged = { ...agents[idx] } as ServiceTreeAgent;
        // Append while de-duplicating by type+name
        const existing = new Set((merged.services || []).map(s => `${s.type}:${s.name}`));
        const toAdd = filteredServices.filter((s: ServiceTreeService) => {
          const key = `${s.type}:${s.name}`;
          if (existing.has(key)) return false;
          existing.add(key);
          return true;
        });
        merged.services = [...(merged.services || []), ...toAdd];
        merged.kv_store_ids = freshAgent.kv_store_ids || merged.kv_store_ids;
        agents[idx] = merged;
      } else {
        agents.push({
          ...freshAgent,
          services: filteredServices,
        });
      }
      return { ...prev, [pollerId]: { ...p, agents } };
    });
    setAgentOffsets(prev => ({ ...prev, [k]: currentOffset + pageSize }));
  };

  const iconForType = (t: string) => {
    switch (t) {
      case 'poller': return <Cpu className="h-4 w-4" />;
      case 'agent': return <Package className="h-4 w-4" />;
      default: return <Settings className="h-4 w-4" />;
    }
  };

  // Highlight helper for search terms
  const highlight = (text: string, term: string) => {
    if (!term) return <>{text}</>;
    const idx = text.toLowerCase().indexOf(term.toLowerCase());
    if (idx === -1) return <>{text}</>;
    const before = text.slice(0, idx);
    const match = text.slice(idx, idx + term.length);
    const after = text.slice(idx + term.length);
    return (
      <>
        {before}
        <span className="bg-yellow-200 dark:bg-yellow-700 rounded px-0.5">{match}</span>
        {after}
      </>
    );
  };

  // Simple virtualization for service lists
  const ServiceList: React.FC<{ items: ServiceTreeService[]; render: (svc: ServiceTreeService) => React.ReactNode; height?: number; itemHeight?: number; }>
    = ({ items, render, height = 320, itemHeight = 28 }) => {
    const [scrollTop, setScrollTop] = useState(0);
    const total = items.length;
    const visibleCount = Math.ceil(height / itemHeight) + 4; // overscan
    const startIndex = Math.max(0, Math.floor(scrollTop / itemHeight) - 2);
    const endIndex = Math.min(total, startIndex + visibleCount);
    const offsetY = startIndex * itemHeight;

    return (
      <div
        className="relative overflow-y-auto"
        style={{ height }}
        onScroll={(e) => setScrollTop((e.target as HTMLDivElement).scrollTop)}
      >
        <div style={{ height: total * itemHeight, position: 'relative' }}>
          <div style={{ transform: `translateY(${offsetY}px)` }}>
            {items.slice(startIndex, endIndex).map(render)}
          </div>
        </div>
      </div>
    );
  };

  // Simple virtualization for agent lists
  const AgentList: React.FC<{ items: ServiceTreeAgent[]; render: (a: ServiceTreeAgent) => React.ReactNode; height?: number; itemHeight?: number; }>
    = ({ items, render, height = 300, itemHeight = 26 }) => {
    const [scrollTop, setScrollTop] = useState(0);
    const total = items.length;
    const visibleCount = Math.ceil(height / itemHeight) + 4;
    const startIndex = Math.max(0, Math.floor(scrollTop / itemHeight) - 2);
    const endIndex = Math.min(total, startIndex + visibleCount);
    const offsetY = startIndex * itemHeight;

    return (
      <div
        className="relative overflow-y-auto"
        style={{ height }}
        onScroll={(e) => setScrollTop((e.target as HTMLDivElement).scrollTop)}
      >
        <div style={{ height: total * itemHeight, position: 'relative' }}>
          <div style={{ transform: `translateY(${offsetY}px)` }}>
            {items.slice(startIndex, endIndex).map(render)}
          </div>
        </div>
      </div>
    );
  };

  const filteredPollers = useMemo(() => {
    const arr = Object.values(tree);
    return filterPoller ? arr.filter(p => p.poller_id.includes(filterPoller)) : arr;
  }, [tree, filterPoller]);

  // Expansion-aware virtualization for pollers
  const collapsedHeight = 40; // px
  const expandedHeight = 420; // px (includes agents virtual list area)

  const getPollerItemHeight = (id: string) => expandedPollers.has(id) ? expandedHeight : collapsedHeight;

  const PollerList: React.FC<{ items: ServiceTreePoller[]; render: (p: ServiceTreePoller) => React.ReactNode; height?: number; }>
    = ({ items, render, height = 560 }) => {
    const [scrollTop, setScrollTop] = useState(0);
    const [heightMap, setHeightMap] = useState<Record<string, number>>({});
    const elMapRef = React.useRef<Record<string, HTMLElement | null>>({});
    const roRef = React.useRef<ResizeObserver | null>(null);

    const itemSpacing = 8; // px (Tailwind mb-2)

    React.useEffect(() => {
      if (typeof window === 'undefined') return;
      roRef.current = new ResizeObserver((entries) => {
        const updates: Record<string, number> = {};
        for (const entry of entries) {
          for (const [id, node] of Object.entries(elMapRef.current)) {
            if (node === entry.target) {
              updates[id] = Math.ceil(entry.contentRect.height) + itemSpacing;
            }
          }
        }
        if (Object.keys(updates).length > 0) {
          setHeightMap((prev) => ({ ...prev, ...updates }));
        }
      });
      for (const node of Object.values(elMapRef.current)) {
        if (node) roRef.current.observe(node);
      }
      return () => { if (roRef.current) roRef.current.disconnect(); roRef.current = null; };
    }, []);

    const register = (id: string) => (el: HTMLElement | null) => {
      const prev = elMapRef.current[id];
      if (prev && roRef.current) roRef.current.unobserve(prev);
      elMapRef.current[id] = el;
      if (el && roRef.current) {
        roRef.current.observe(el);
        const h = Math.ceil(el.clientHeight) + itemSpacing;
        setHeightMap((prev) => (prev[id] === h ? prev : { ...prev, [id]: h }));
      }
    };

    const heights = items.map((p) => heightMap[p.poller_id] ?? getPollerItemHeight(p.poller_id));
    const totalHeight = heights.reduce((a, b) => a + b, 0);

    let acc = 0;
    let startIndex = 0;
    const overscan = 2;
    for (let i = 0; i < heights.length; i++) {
      if (acc + heights[i] > scrollTop) { startIndex = Math.max(0, i - overscan); break; }
      acc += heights[i];
      if (i === heights.length - 1) startIndex = i;
    }
    let view = 0; let endIndex = startIndex;
    const maxView = height + overscan * collapsedHeight;
    for (let i = startIndex; i < heights.length; i++) {
      view += heights[i];
      endIndex = i;
      if (view > maxView) break;
    }
    const offsetY = heights.slice(0, startIndex).reduce((a, b) => a + b, 0);

    return (
      <div className="relative overflow-y-auto" style={{ height }} onScroll={(e) => setScrollTop((e.target as HTMLDivElement).scrollTop)}>
        <div style={{ height: totalHeight, position: 'relative' }}>
          <div style={{ transform: `translateY(${offsetY}px)` }}>
            {items.slice(startIndex, endIndex + 1).map((p) => (
              <div key={p.poller_id} ref={register(p.poller_id)}>
                {render(p)}
              </div>
            ))}
          </div>
        </div>
      </div>
    );
  };

  return (
    <div className="p-2 h-full" ref={containerRef}>
      {/* Global services section (not scoped to agents/pollers) */}
      <div className="mb-2">
        <div className="flex items-center gap-2 p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded cursor-pointer" onClick={() => setGlobalOpen(!globalOpen)}>
          {globalOpen ? <ChevronDown className="h-4 w-4" /> : <ChevronRight className="h-4 w-4" />}
          <Settings className="h-4 w-4" />
          <span className="font-medium">Global Services</span>
        </div>
        {globalOpen && (
          <div className="ml-4 text-sm">
            {globalServices.length === 0 && (
              <div className="p-1 text-xs text-gray-500">No global services registered.</div>
            )}
            {globalServices.map((svc) => {
              const desc = descriptorByType.get(svc);
              const label = getServiceLabel(svc);
              const rowId = `global::${desc?.name ?? svc}`;
              const status = globalStatus[svc] ?? 'unknown';
              const statusClass = status === 'configured' ? 'bg-green-500' : status === 'missing' ? 'bg-gray-400' : 'bg-yellow-400';
              const statusTitle = status === 'configured' ? 'Configured' : status === 'missing' ? 'Not configured' : 'Checking…';
              return (
                <div
                  key={svc}
                  className={`flex items-center gap-2 p-1 hover:bg-gray-100 dark:hover:bg-gray-700 rounded cursor-pointer ${selected?.id === rowId ? 'bg-blue-100 dark:bg-blue-900' : ''}`}
                  onClick={() => onSelect({ id: rowId, name: label, type: svc, kvStore: '' })}
                >
                  <span className="w-3" />
                  <span>{label}</span>
                  {desc?.kv_key && (
                    <span className="text-xs text-gray-500 dark:text-gray-400">{desc.kv_key}</span>
                  )}
                  <span className={`ml-2 w-2 h-2 rounded-full ${statusClass}`} title={statusTitle} />
                </div>
              );
            })}
          </div>
        )}
      </div>
      {loadingPollers && (
        <div className="p-2 text-sm text-gray-500">Loading pollers…</div>
      )}
      <PollerList
        items={filteredPollers}
        render={(p) => (
        <div key={p.poller_id} className="mb-2">
          <div className="flex items-center gap-2 p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded cursor-pointer" onClick={() => togglePoller(p.poller_id)}>
            {expandedPollers.has(p.poller_id) ? <ChevronDown className="h-4 w-4" /> : <ChevronRight className="h-4 w-4" />}
            <Server className="h-4 w-4" />
            <span className="font-medium">{highlight(p.poller_id, filterPoller)}</span>
            <span className={`w-2 h-2 rounded-full ${p.is_healthy ? 'bg-green-500' : 'bg-red-500'}`} />
            {p.kv_store_ids && p.kv_store_ids.length > 0 && (
              <span className="ml-2"><KvInfoBadge kvId={p.kv_store_ids[0]} hoverTrigger /></span>
            )}
          </div>
          {expandedPollers.has(p.poller_id) && (
            <div className="ml-4">
              {/* Poller-level selection */}
              <div
                className={`flex items-center gap-2 p-1.5 text-sm hover:bg-gray-100 dark:hover:bg-gray-700 rounded cursor-pointer ${selected?.id === `poller:${p.poller_id}` ? 'bg-blue-100 dark:bg-blue-900' : ''}`}
                onClick={() => onSelect({ id: `poller:${p.poller_id}`, name: p.poller_id, type: 'poller', kvStore: p.kv_store_ids?.[0], pollerId: p.poller_id })}
              >
                {iconForType('poller')}
                <span>Configure poller</span>
              </div>
              {(p.agents || []).filter(a => !filterAgent || a.agent_id.includes(filterAgent)).map((a) => (
                <div key={`${p.poller_id}:${a.agent_id}`} className="mb-1">
                  <div className="flex items-center gap-2 p-1.5 hover:bg-gray-100 dark:hover:bg-gray-700 rounded cursor-pointer" onClick={() => toggleAgent(p.poller_id, a.agent_id)}>
                    {expandedAgents.has(`${p.poller_id}:${a.agent_id}`) ? <ChevronDown className="h-3 w-3" /> : <ChevronRight className="h-3 w-3" />}
                    {iconForType('agent')}
                    <span className="text-sm">{highlight(a.agent_id, filterAgent)}</span>
                    {a.kv_store_ids && a.kv_store_ids.length > 0 && (
                      <span className="ml-2"><KvInfoBadge kvId={a.kv_store_ids[0]} hoverTrigger /></span>
                    )}
                  </div>
                  {expandedAgents.has(`${p.poller_id}:${a.agent_id}`) && (
                    <div className="ml-6">
                      {/* Agent-level selection */}
                      <div
                        className={`flex items-center gap-2 p-1.5 text-sm hover:bg-gray-100 dark:hover:bg-gray-700 rounded cursor-pointer ${selected?.id === `agent:${p.poller_id}:${a.agent_id}` ? 'bg-blue-100 dark:bg-blue-900' : ''}`}
                        onClick={() => onSelect({ id: `agent:${p.poller_id}:${a.agent_id}`, name: a.agent_id, type: 'agent', kvStore: a.kv_store_ids?.[0], pollerId: p.poller_id, agentId: a.agent_id })}
                      >
                        {iconForType('agent')}
                        <span>Configure agent</span>
                      </div>
                      {(() => {
                        const services = (a.services || []).filter(s => !filterService || s.name.toLowerCase().includes(filterService.toLowerCase()));
                        if (services.length === 0) {
                          const key = `${p.poller_id}:${a.agent_id}`;
                          const supported = [
                            { label: 'SNMP', type: 'snmp' },
                            { label: 'Sweep', type: 'sweep' },
                            { label: 'SysMon', type: 'sysmon' },
                            { label: 'rPerf', type: 'rperf' },
                            { label: 'Trapd', type: 'trapd' },
                            { label: 'Mapper', type: 'mapper' },
                          ];
                          return (
                            <div className="mt-2 ml-2 text-xs text-gray-600 dark:text-gray-400">
                              <div className="mb-1">No configured services yet.</div>
                              <div className="relative inline-block">
                                <button
                                  className="px-2 py-1 bg-blue-600 text-white rounded hover:bg-blue-700"
                                  onClick={(e) => { e.stopPropagation(); setOpenAddMenuFor(openAddMenuFor === key ? null : key); }}
                                >
                                  Add service
                                </button>
                                {openAddMenuFor === key && (
                                  <div className="absolute z-20 mt-1 w-40 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 shadow">
                                    {supported.map(s => (
                                      <button
                                        key={s.type}
                                        className="w-full text-left px-3 py-1 text-xs hover:bg-gray-100 dark:hover:bg-gray-700"
                                        onClick={(e) => {
                                          e.stopPropagation();
                                          setOpenAddMenuFor(null);
                                          onSelect({ id: `newsvc:${p.poller_id}:${a.agent_id}:${s.type}`, name: s.type, type: s.type, kvStore: a.kv_store_ids?.[0], pollerId: p.poller_id, agentId: a.agent_id });
                                        }}
                                      >{s.label}</button>
                                    ))}
                                  </div>
                                )}
                              </div>
                            </div>
                          );
                        }
                        return services.map((svc) => (
                        <div
                          key={`${p.poller_id}:${a.agent_id}:${svc.name}:${svc.type}`}
                          className={`ml-3 flex items-center gap-2 p-1.5 text-sm hover:bg-gray-100 dark:hover:bg-gray-700 rounded cursor-pointer ${selected?.id === `svc:${p.poller_id}:${a.agent_id}:${svc.type}:${svc.name}` ? 'bg-blue-100 dark:bg-blue-900' : ''}`}
                          onClick={() => onSelect({ id: `svc:${p.poller_id}:${a.agent_id}:${svc.type}:${svc.name}`, name: svc.name, type: svc.type, kvStore: svc.kv_store_id, pollerId: p.poller_id, agentId: a.agent_id })}
                        >
                          <span className="w-3" />
                          {iconForType('service')}
                          <span>{highlight(svc.name, filterService)}</span>
                          <span className="text-xs text-gray-500">({svc.type})</span>
                          {svc.kv_store_id && (
                            <span className="ml-2"><KvInfoBadge kvId={svc.kv_store_id} hoverTrigger /></span>
                          )}
                        </div>
                        ));
                      })()}
                      {agentHasMore[`${p.poller_id}:${a.agent_id}`] && (
                        <div className="ml-6">
                          <button className="text-xs text-blue-600 hover:underline" onClick={() => loadMoreServices(p.poller_id, a.agent_id)}>Load more…</button>
                        </div>
                      )}
                    </div>
                  )}
                </div>
              ))}
            </div>
          )}
        </div>
        )}
      />
    </div>
  );
}
