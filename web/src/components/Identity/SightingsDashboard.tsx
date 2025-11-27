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

"use client";

import React, { useCallback, useEffect, useMemo, useState } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useAuth } from "@/components/AuthProvider";
import {
  AlertTriangle,
  CheckCircle2,
  Clock,
  ChevronLeft,
  ChevronRight,
  Fingerprint,
  GitMerge,
  Info,
  ListChecks,
  MapPin,
  RefreshCcw,
  ShieldCheck,
  XCircle,
} from "lucide-react";
import {
  NetworkSighting,
  SubnetPolicy,
  SightingEvent,
  SightingsResponse,
  MergeAuditEvent,
  SightingEventsResponse,
  IdentityConfigMeta,
} from "@/types/identity";

interface ActionMessage {
  type: "success" | "error";
  text: string;
}

const formatTimestamp = (value?: string | null) => {
  if (!value) return "Unknown";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "Unknown";
  return date.toLocaleString();
};

const relativeTime = (value?: string | null) => {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  const diffMs = Date.now() - date.getTime();
  const diffMinutes = Math.floor(diffMs / 60000);
  if (diffMinutes < 1) return "Just now";
  if (diffMinutes < 60) return `${diffMinutes}m ago`;
  const diffHours = Math.floor(diffMinutes / 60);
  if (diffHours < 24) return `${diffHours}h ago`;
  return `${Math.floor(diffHours / 24)}d ago`;
};

const timeUntil = (value?: string | null) => {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  const diffMs = date.getTime() - Date.now();
  if (diffMs <= 0) return "expired";
  const minutes = Math.floor(diffMs / 60000);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return `${hours}h`;
  return `${Math.floor(hours / 24)}d`;
  };

const hasStrongIdentifiers = (sighting: NetworkSighting) =>
  Boolean(
    sighting?.metadata?.mac ||
      sighting?.metadata?.hostname ||
      sighting?.metadata?.fingerprint_hash ||
      sighting.fingerprint_id ||
      sighting?.metadata?.fingerprint_id,
  );

const formatRange = (start: number, end: number, total: number) => {
  if (total === 0) return "0 of 0";
  return `${start}–${end} of ${total}`;
};

const StatCard = ({
  label,
  value,
  icon,
  tone = "default",
}: {
  label: string;
  value: string | number;
  icon: React.ReactNode;
  tone?: "default" | "warning" | "success";
}) => {
  const toneClasses: Record<typeof tone, string> = {
    default: "bg-blue-50 text-blue-700 dark:bg-blue-900/30 dark:text-blue-200",
    warning: "bg-amber-50 text-amber-700 dark:bg-amber-900/30 dark:text-amber-200",
    success: "bg-emerald-50 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-200",
  };
  return (
    <div className="flex items-center gap-3 rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 px-4 py-3 shadow-sm">
      <div className={`p-2 rounded-full ${toneClasses[tone]}`}>{icon}</div>
      <div>
        <p className="text-xs text-gray-500 dark:text-gray-400">{label}</p>
        <p className="text-xl font-semibold text-gray-900 dark:text-white">{value}</p>
      </div>
    </div>
  );
};

const SightingsDashboard: React.FC<{
  prefillSightingId?: string;
  historyActorDefault?: string;
  historyPartitionDefault?: string;
}> = ({ prefillSightingId, historyActorDefault, historyPartitionDefault }) => {
  const { token } = useAuth();
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [sightings, setSightings] = useState<NetworkSighting[]>([]);
  const [events, setEvents] = useState<SightingEvent[]>([]);
  const [selected, setSelected] = useState<NetworkSighting | null>(null);
  const [highlightedId, setHighlightedId] = useState<string | null>(prefillSightingId ?? null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [reconciling, setReconciling] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [actionMessage, setActionMessage] = useState<ActionMessage | null>(null);
  const [busySighting, setBusySighting] = useState<string | null>(null);
  const [dismissReason, setDismissReason] = useState("");
  const [policies, setPolicies] = useState<SubnetPolicy[]>([]);
  const [policiesLoading, setPoliciesLoading] = useState(true);
  const [policyError, setPolicyError] = useState<string | null>(null);
  const [mergeEvents, setMergeEvents] = useState<MergeAuditEvent[]>([]);
  const [mergeLoading, setMergeLoading] = useState(true);
  const [mergeError, setMergeError] = useState<string | null>(null);
  const [mergeDeviceFilter, setMergeDeviceFilter] = useState("");
  const [identityMeta, setIdentityMeta] = useState<IdentityConfigMeta | null>(null);
  const [pagination, setPagination] = useState({ limit: 50, offset: 0, total: 0 });
  const [prefillMissing, setPrefillMissing] = useState(false);
  const [prefillEvents, setPrefillEvents] = useState<SightingEvent[]>([]);
  const [prefillEventsLoading, setPrefillEventsLoading] = useState(false);
  const [prefillEventsError, setPrefillEventsError] = useState<string | null>(null);
  const [historyLookupId, setHistoryLookupId] = useState(
    typeof (searchParams.get("history_id") ?? "") === "string" ? (searchParams.get("history_id") ?? "") : "",
  );
  const [historyEvents, setHistoryEvents] = useState<SightingEvent[]>([]);
  const [historyLoading, setHistoryLoading] = useState(false);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const [historyActorFilter, setHistoryActorFilter] = useState(historyActorDefault ?? "");
  const [historyPartitionFilter, setHistoryPartitionFilter] = useState(historyPartitionDefault ?? "");
  const [filters, setFilters] = useState({
    partition: "",
    source: "all",
    search: "",
  });

  const headers: HeadersInit = useMemo(
    () => ({
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    }),
    [token],
  );

  const fetchSightings = useCallback(async () => {
    setRefreshing(true);
    setError(null);
    setActionMessage(null);
    setHistoryEvents([]);
    setHistoryError(null);

    const params = new URLSearchParams();
    if (filters.partition.trim()) {
      params.set("partition", filters.partition.trim());
    }
    params.set("limit", pagination.limit.toString());
    params.set("offset", pagination.offset.toString());

    try {
      const response = await fetch(`/api/identity/sightings?${params.toString()}`, {
        method: "GET",
        headers,
        cache: "no-store",
      });

      if (!response.ok) {
        const detail = await response.text();
        throw new Error(detail || `Failed to fetch sightings (${response.status})`);
      }

      const data: SightingsResponse = await response.json();
      const items = Array.isArray(data?.items) ? data.items : [];
      setIdentityMeta(data?.identity ?? null);
      setPagination((prev) => ({
        limit: data?.limit ?? prev.limit,
        offset: data?.offset ?? prev.offset,
        total: typeof data?.total === "number" ? data.total : items.length,
      }));
      setSightings(items);
      setPrefillMissing(false);

      setSelected((prev) => {
        if (prefillSightingId) {
          const match = items.find((s) => s.sighting_id === prefillSightingId);
          if (match) {
            setHighlightedId(prefillSightingId);
            return match;
          }
      setPrefillMissing(true);
      setPrefillEvents([]);
    }
    if (prev && items.find((s) => s.sighting_id === prev.sighting_id)) {
      return prev;
    }
    return items[0] ?? null;
      });

      if (items.length === 0) {
        setEvents([]);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to load sightings");
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [filters.partition, headers, pagination.limit, pagination.offset, prefillSightingId]);

  const fetchEvents = useCallback(
    async (sightingID: string) => {
      if (!sightingID) {
        setEvents([]);
        return;
      }
      try {
        const response = await fetch(`/api/identity/sightings/${sightingID}/events?limit=50`, {
          method: "GET",
          headers,
          cache: "no-store",
        });
        if (!response.ok) {
          throw new Error(`Failed to fetch events (${response.status})`);
        }
        const data: SightingEventsResponse = await response.json();
        setEvents(Array.isArray(data?.items) ? data.items : []);
      } catch (err) {
        setActionMessage({
          type: "error",
          text: err instanceof Error ? err.message : "Failed to load audit events",
        });
      }
    },
    [headers],
  );

  const fetchPolicies = useCallback(async () => {
    setPoliciesLoading(true);
    setPolicyError(null);
    try {
      const response = await fetch("/api/identity/policies?limit=200", {
        method: "GET",
        headers,
        cache: "no-store",
      });
      if (!response.ok) {
        const detail = await response.text();
        throw new Error(detail || `Failed to fetch policies (${response.status})`);
      }
      const data = await response.json();
      const items: SubnetPolicy[] = Array.isArray(data?.items) ? data.items : [];
      setPolicies(items);
    } catch (err) {
      setPolicyError(err instanceof Error ? err.message : "Failed to load policies");
    } finally {
      setPoliciesLoading(false);
    }
  }, [headers]);

  const fetchMergeHistory = useCallback(
    async (deviceFilter?: string) => {
      setMergeLoading(true);
      setMergeError(null);
      try {
        const params = new URLSearchParams();
        params.set("limit", "100");
        if (deviceFilter && deviceFilter.trim()) {
          params.set("device_id", deviceFilter.trim());
        }
        const response = await fetch(`/api/identity/merge-audit?${params.toString()}`, {
          method: "GET",
          headers,
          cache: "no-store",
        });
        if (!response.ok) {
          const detail = await response.text();
          throw new Error(detail || `Failed to fetch merge history (${response.status})`);
        }
        const data = await response.json();
        const items: MergeAuditEvent[] = Array.isArray(data?.items) ? data.items : [];
        setMergeEvents(items);
      } catch (err) {
        setMergeError(err instanceof Error ? err.message : "Failed to load merge history");
      } finally {
        setMergeLoading(false);
      }
    },
    [headers],
  );

  const buildReasonHints = useCallback(
    (s: NetworkSighting | null) => {
      if (!s) return [];
      const hints: string[] = [];
      const seen = new Set<string>();
      const addHint = (hint?: string) => {
        const value = hint?.trim();
        if (!value || seen.has(value)) return;
        seen.add(value);
        hints.push(value);
      };

      const promo = s.promotion;

      if (promo) {
        if (promo.eligible) {
          addHint("Meets promotion policy and is eligible for auto-promotion.");
        }
        if (promo.shadow_mode && promo.meets_policy) {
          addHint("Promotion is in shadow mode; decisions are simulated without auto-attaching devices.");
        }
        promo.blockers?.forEach(addHint);
        if (promo.next_eligible_at) {
          addHint(`Expected to become eligible in ${timeUntil(promo.next_eligible_at)} (policy persistence window).`);
        }
      } else {
        if (identityMeta?.sightings_only_mode || identityMeta?.promotion?.enabled === false) {
          addHint(
            "Auto-promotion is disabled (sightings-only/disabled promotion), so sightings stay here until reviewed.",
          );
        }
        if (hasStrongIdentifiers(s)) {
          addHint("Strong identifiers (hostname/MAC/fingerprint) detected; awaiting manual promotion or policy gate.");
        } else {
          addHint("No strong identifiers yet; waiting for hostname/fingerprint or policy thresholds.");
        }
      }

      if (s.ttl_expires_at) {
        addHint(`Will expire in ${timeUntil(s.ttl_expires_at)} unless promoted or updated.`);
      }

      return hints;
    },
    [identityMeta],
  );

  useEffect(() => {
    fetchSightings();
  }, [fetchSightings]);

  const filterEventsByMeta = useCallback(
    (events: SightingEvent[]) =>
      events.filter((event) => {
        const actorMatch = historyActorFilter.trim()
          ? (event.actor || "").toLowerCase().includes(historyActorFilter.trim().toLowerCase())
          : true;
        const partition = event.details?.partition || event.details?.Partition || "";
        const partitionMatch = historyPartitionFilter.trim()
          ? partition.toLowerCase().includes(historyPartitionFilter.trim().toLowerCase())
          : true;
        return actorMatch && partitionMatch;
      }),
    [historyActorFilter, historyPartitionFilter],
  );

  const filteredPrefillEvents = useMemo(
    () => filterEventsByMeta(prefillEvents),
    [filterEventsByMeta, prefillEvents],
  );

  const filteredHistoryEvents = useMemo(
    () => filterEventsByMeta(historyEvents),
    [filterEventsByMeta, historyEvents],
  );

  useEffect(() => {
    const params = new URLSearchParams(searchParams.toString());
    if (historyLookupId.trim()) {
      params.set("history_id", historyLookupId.trim());
    } else {
      params.delete("history_id");
    }
    if (historyActorFilter.trim()) {
      params.set("history_actor", historyActorFilter.trim());
    } else {
      params.delete("history_actor");
    }
    if (historyPartitionFilter.trim()) {
      params.set("history_partition", historyPartitionFilter.trim());
    } else {
      params.delete("history_partition");
    }
    const next = params.toString();
    router.replace(next ? `${pathname}?${next}` : pathname, { scroll: false });
  }, [historyActorFilter, historyLookupId, historyPartitionFilter, pathname, router, searchParams]);

  const copyDeepLink = useCallback(async () => {
    try {
      const qs = searchParams.toString();
      const link = typeof window !== "undefined" ? `${window.location.origin}${pathname}${qs ? `?${qs}` : ""}` : "";
      await navigator.clipboard.writeText(link);
      setActionMessage({ type: "success", text: "Deep link copied to clipboard." });
    } catch {
      setActionMessage({
        type: "error",
        text: "Unable to copy link automatically. Copy the address bar manually.",
      });
    }
  }, [pathname, searchParams]);

  const fetchHistoryEvents = useCallback(
    async (sightingID: string) => {
      const trimmed = sightingID.trim();
      if (!trimmed) {
        setHistoryEvents([]);
        setHistoryError(null);
        return;
      }
      setHistoryLoading(true);
      setHistoryError(null);
      try {
        const response = await fetch(`/api/identity/sightings/${encodeURIComponent(trimmed)}/events?limit=50`, {
          method: "GET",
          headers,
          cache: "no-store",
        });
        if (!response.ok) {
          const detail = await response.text();
          throw new Error(detail || `Failed to fetch sighting history (${response.status})`);
        }
        const data: SightingEventsResponse = await response.json();
        setHistoryEvents(Array.isArray(data.items) ? data.items : []);
      } catch (err) {
        setHistoryEvents([]);
        setHistoryError(err instanceof Error ? err.message : "Failed to load sighting history");
      } finally {
        setHistoryLoading(false);
      }
    },
    [headers],
  );

  useEffect(() => {
    const fetchPrefillEvents = async () => {
      if (!prefillMissing || !prefillSightingId) {
        setPrefillEvents([]);
        setPrefillEventsError(null);
        setPrefillEventsLoading(false);
        return;
      }
      setPrefillEventsLoading(true);
      setPrefillEventsError(null);
      try {
        const response = await fetch(`/api/identity/sightings/${prefillSightingId}/events?limit=50`, {
          method: "GET",
          headers,
          cache: "no-store",
        });
        if (!response.ok) {
          const detail = await response.text();
          throw new Error(detail || `Failed to fetch sighting history (${response.status})`);
        }
        const data: SightingEventsResponse = await response.json();
        setPrefillEvents(Array.isArray(data.items) ? data.items : []);
      } catch (err) {
        setPrefillEventsError(err instanceof Error ? err.message : "Failed to load sighting history");
        setPrefillEvents([]);
      } finally {
        setPrefillEventsLoading(false);
      }
    };

    void fetchPrefillEvents();
  }, [headers, prefillMissing, prefillSightingId]);

  useEffect(() => {
    setPagination((prev) => ({ ...prev, offset: 0 }));
  }, [filters.partition, filters.search, filters.source]);

  useEffect(() => {
    if (selected?.sighting_id) {
      fetchEvents(selected.sighting_id);
    }
  }, [fetchEvents, selected]);

  useEffect(() => {
    fetchPolicies();
    fetchMergeHistory();
  }, [fetchMergeHistory, fetchPolicies]);

  const handleReconcile = async () => {
    setReconciling(true);
    setActionMessage(null);
    try {
      const response = await fetch("/api/identity/reconcile", {
        method: "POST",
        headers,
        cache: "no-store",
      });
      if (!response.ok) {
        const detail = await response.text();
        throw new Error(detail || `Reconciliation failed (${response.status})`);
      }
      setActionMessage({ type: "success", text: "Reconciliation triggered. Refreshing sightings..." });
      await fetchSightings();
    } catch (err) {
      setActionMessage({
        type: "error",
        text: err instanceof Error ? err.message : "Failed to trigger reconciliation",
      });
    } finally {
      setReconciling(false);
    }
  };

  const handlePromote = async (sightingID: string) => {
    setBusySighting(sightingID);
    setActionMessage(null);
    try {
      const response = await fetch(`/api/identity/sightings/${sightingID}/promote`, {
        method: "POST",
        headers,
        cache: "no-store",
      });
      if (!response.ok) {
        const detail = await response.text();
        throw new Error(detail || `Promotion failed (${response.status})`);
      }
      setActionMessage({ type: "success", text: "Sighting promoted successfully" });
      await fetchSightings();
      if (selected?.sighting_id === sightingID) {
        setDismissReason("");
      }
    } catch (err) {
      setActionMessage({
        type: "error",
        text: err instanceof Error ? err.message : "Failed to promote sighting",
      });
    } finally {
      setBusySighting(null);
    }
  };

  const handleDismiss = async (sightingID: string) => {
    setBusySighting(sightingID);
    setActionMessage(null);
    try {
      const response = await fetch(`/api/identity/sightings/${sightingID}/dismiss`, {
        method: "POST",
        headers,
        cache: "no-store",
        body: JSON.stringify({ reason: dismissReason }),
      });
      if (!response.ok) {
        const detail = await response.text();
        throw new Error(detail || `Dismissal failed (${response.status})`);
      }
      setActionMessage({ type: "success", text: "Sighting dismissed" });
      await fetchSightings();
      if (selected?.sighting_id === sightingID) {
        setDismissReason("");
      }
    } catch (err) {
      setActionMessage({
        type: "error",
        text: err instanceof Error ? err.message : "Failed to dismiss sighting",
      });
    } finally {
      setBusySighting(null);
    }
  };

  const filteredSightings = useMemo(() => {
    return sightings.filter((s) => {
      const matchesSource = filters.source === "all" || s.source === filters.source;
      const search = filters.search.trim().toLowerCase();
      if (!matchesSource) return false;
      if (!search) return true;
      const hostname = s.metadata?.hostname?.toLowerCase?.() ?? "";
      const mac = s.metadata?.mac?.toLowerCase?.() ?? "";
      return (
        s.ip.toLowerCase().includes(search) ||
        hostname.includes(search) ||
        mac.includes(search) ||
        (s.partition ?? "").toLowerCase().includes(search)
      );
    });
  }, [filters.search, filters.source, sightings]);

  const uniqueSources = useMemo(() => {
    const set = new Set<string>();
    sightings.forEach((s) => set.add(s.source || "unknown"));
    return Array.from(set);
  }, [sightings]);

  const fingerprinted = useMemo(
    () =>
      sightings.filter(
        (s) =>
          Boolean(s.fingerprint_id) ||
          Boolean(s.metadata?.fingerprint_hash) ||
          Boolean(s.metadata?.fingerprint_id),
      ).length,
    [sightings],
  );

  const promotionReady = useMemo(
    () => sightings.filter((s) => s.promotion?.eligible).length,
    [sightings],
  );

  const promotionShadowReady = useMemo(
    () => sightings.filter((s) => s.promotion?.meets_policy && s.promotion?.shadow_mode).length,
    [sightings],
  );

  const promotionBlocked = useMemo(
    () => sightings.filter((s) => s.promotion && s.promotion.meets_policy === false).length,
    [sightings],
  );

  const expiringSoon = useMemo(
    () =>
      sightings.filter((s) => {
        if (!s.ttl_expires_at) return false;
        const expires = new Date(s.ttl_expires_at).getTime();
        if (Number.isNaN(expires)) return false;
        const diff = expires - Date.now();
        return diff > 0 && diff <= 60 * 60 * 1000;
      }).length,
    [sightings],
  );

  const reasonHints = useMemo(() => buildReasonHints(selected), [buildReasonHints, selected]);

  const totalSightings = pagination.total || sightings.length;
  const pageStart = sightings.length > 0 ? pagination.offset + 1 : 0;
  const pageEnd = pagination.offset + sightings.length;
  const pageEndDisplay = totalSightings === 0 ? 0 : Math.min(totalSightings, pageEnd);
  const totalPages = pagination.limit ? Math.max(1, Math.ceil(totalSightings / pagination.limit)) : 1;
  const currentPage = pagination.limit ? Math.floor(pagination.offset / pagination.limit) + 1 : 1;
  const canPrev = pagination.offset > 0;
  const canNext = pagination.offset + pagination.limit < totalSightings;

  const handlePageChange = (direction: "prev" | "next") => {
    setPagination((prev) => {
      const nextOffset =
        direction === "next"
          ? Math.min(prev.offset + prev.limit, Math.max(0, (prev.total || 0) - 1))
          : Math.max(0, prev.offset - prev.limit);
      return { ...prev, offset: nextOffset };
    });
  };

  const handlePageSizeChange = (value: number) => {
    setPagination((prev) => ({
      ...prev,
      limit: value,
      offset: 0,
    }));
  };

  const renderEventDetails = (details?: Record<string, string>) => {
    if (!details) return null;
    const entries = Object.entries(details).filter(([, v]) => v !== "");
    if (!entries.length) return null;
    return (
      <div className="text-xs text-gray-500 dark:text-gray-400 space-x-2">
        {entries.map(([key, value]) => (
          <span key={`${key}-${value}`} className="inline-flex items-center gap-1">
            <span className="uppercase tracking-wide text-[10px] text-gray-400 dark:text-gray-500">{key}</span>
            <span className="text-gray-700 dark:text-gray-200">{value}</span>
          </span>
        ))}
      </div>
    );
  };

  const summarizePromotionRules = (rules?: Record<string, unknown>) => {
    if (!rules || Object.keys(rules).length === 0) {
      return "default policy";
    }
    const parts: string[] = [];
    const minPersistence = rules.min_persistence_duration || rules.min_persistence || rules.min_persistence_minutes;
    if (typeof minPersistence === "number") {
      parts.push(`persist ${minPersistence}m`);
    }
    if (rules.require_hostname === true) {
      parts.push("hostname");
    }
    if (rules.require_fingerprint === true) {
      parts.push("fingerprint");
    }
    if (rules.require_agent === true) {
      parts.push("agent");
    }
    if (parts.length === 0) {
      return "simple allow";
    }
    return parts.join(" · ");
  };

  const promotionDisplay = (s: NetworkSighting | null) => {
    const fallback = { label: "Pending", tone: "default", detail: "Awaiting policy evaluation" };
    if (!s) return fallback;
    const p = s.promotion;
    if (!p) return fallback;
    if (p.eligible) {
      return { label: "Eligible", tone: "success", detail: "Meets policy; auto-promotion enabled" };
    }
    if (p.meets_policy && p.shadow_mode) {
      return { label: "Policy ready", tone: "warning", detail: "Shadow mode; promotion is simulated only" };
    }
    if (!p.meets_policy) {
      return { label: "Blocked", tone: "warning", detail: p.blockers?.[0] || "Policy requirements not met" };
    }
    return { label: "Disabled", tone: "warning", detail: "Promotion disabled or sightings-only mode" };
  };

  const selectedMetadata = selected?.metadata ?? {};

  const selectedPromotion = promotionDisplay(selected);

  return (
    <div className="space-y-4">
      <div className="flex flex-col gap-3 xl:flex-row xl:items-center xl:justify-between">
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-6 gap-3">
          <StatCard
            label="Active sightings"
            value={totalSightings}
            icon={<ListChecks className="h-5 w-5" />}
          />
          <StatCard
            label="Distinct sources"
            value={uniqueSources.length}
            icon={<ShieldCheck className="h-5 w-5" />}
          />
          <StatCard
            label="With fingerprints"
            value={fingerprinted}
            icon={<Fingerprint className="h-5 w-5" />}
            tone="success"
          />
          <StatCard
            label="Promotion-ready"
            value={promotionReady}
            icon={<CheckCircle2 className="h-5 w-5" />}
            tone="success"
          />
          <StatCard
            label="Policy-ready (shadow)"
            value={promotionShadowReady}
            icon={<ShieldCheck className="h-5 w-5" />}
            tone="warning"
          />
          <StatCard
            label="Policy blockers"
            value={promotionBlocked}
            icon={<AlertTriangle className="h-5 w-5" />}
            tone="warning"
          />
          <StatCard
            label="Expiring soon (<1h)"
            value={expiringSoon}
            icon={<Clock className="h-5 w-5" />}
            tone="warning"
          />
        </div>
        <div className="flex flex-wrap gap-2">
          <button
            type="button"
            onClick={fetchSightings}
            disabled={refreshing || loading}
            className="inline-flex items-center gap-2 rounded-md border border-gray-300 dark:border-gray-700 px-4 py-2 text-sm font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-800 disabled:opacity-50"
          >
            <RefreshCcw className={`h-4 w-4 ${refreshing ? "animate-spin" : ""}`} />
            Refresh
          </button>
          <button
            type="button"
            onClick={handleReconcile}
            disabled={reconciling}
            className="inline-flex items-center gap-2 rounded-md bg-blue-600 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-blue-700 disabled:opacity-60"
          >
            <ShieldCheck className={`h-4 w-4 ${reconciling ? "animate-pulse" : ""}`} />
            Trigger reconcile
          </button>
        </div>
      </div>

      {actionMessage ? (
        <div
          className={`flex items-center gap-2 rounded-md px-4 py-3 text-sm ${
            actionMessage.type === "success"
              ? "bg-emerald-50 text-emerald-800 dark:bg-emerald-900/30 dark:text-emerald-200"
            : "bg-red-50 text-red-800 dark:bg-red-900/30 dark:text-red-200"
          }`}
        >
          {actionMessage.type === "success" ? (
            <CheckCircle2 className="h-4 w-4" />
          ) : (
            <AlertTriangle className="h-4 w-4" />
          )}
          <span>{actionMessage.text}</span>
        </div>
      ) : null}

      {prefillMissing ? (
        <div className="flex items-center gap-2 rounded-md bg-amber-50 px-4 py-3 text-sm text-amber-800 dark:bg-amber-900/30 dark:text-amber-200">
          <AlertTriangle className="h-4 w-4" />
          <span>
            Linked sighting {prefillSightingId} is not active (may be promoted, dismissed, or expired). Showing latest
            sightings instead.
          </span>
        </div>
      ) : null}

      {prefillMissing ? (
        <div className="rounded-lg border border-amber-200 dark:border-amber-800 bg-white dark:bg-gray-800 shadow-sm">
          <div className="flex items-center justify-between border-b border-amber-100 dark:border-amber-800 px-4 py-3">
            <div>
              <h3 className="text-sm font-semibold text-gray-900 dark:text-white">Linked sighting history</h3>
              <p className="text-xs text-gray-600 dark:text-gray-400">
                Audit trail for sighting {prefillSightingId} (may have been promoted or dismissed).
              </p>
            </div>
            <button
              type="button"
              onClick={() => setPrefillMissing(false)}
              className="text-xs font-medium text-amber-700 dark:text-amber-300 hover:underline"
            >
              Hide
            </button>
          </div>
          <div className="px-4 py-3 space-y-2">
            {prefillEventsLoading ? (
              <div className="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-300">
                <RefreshCcw className="h-4 w-4 animate-spin" />
                Loading audit events…
              </div>
            ) : prefillEventsError ? (
              <div className="rounded-md border border-dashed border-red-300 dark:border-red-700 bg-red-50/60 dark:bg-red-900/20 p-3 text-sm text-red-700 dark:text-red-300">
                {prefillEventsError}
              </div>
          ) : filteredPrefillEvents.length === 0 ? (
            <div className="text-sm text-gray-600 dark:text-gray-300">No audit events recorded for this sighting.</div>
          ) : (
            <div className="divide-y divide-gray-200 dark:divide-gray-700">
              {filteredPrefillEvents.map((event) => (
                  <div key={event.event_id ?? `${event.sighting_id}-${event.created_at}`} className="py-2 space-y-1">
                    <div className="flex items-center justify-between">
                      <span className="text-sm font-semibold text-gray-900 dark:text-white capitalize">
                        {event.event_type}
                      </span>
                      <span className="text-xs text-gray-500 dark:text-gray-400">{formatTimestamp(event.created_at)}</span>
                    </div>
                    <div className="text-xs text-gray-600 dark:text-gray-300">Actor: {event.actor || "system"}</div>
                    {event.details && Object.keys(event.details).length > 0 ? (
                      <div className="text-xs text-gray-600 dark:text-gray-300">
                        {Object.entries(event.details)
                          .map(([k, v]) => `${k}: ${v}`)
                          .join(" • ")}
                      </div>
                    ) : null}
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      ) : null}

      <div className="rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 shadow-sm">
        <div className="flex items-center justify-between border-b border-gray-200 dark:border-gray-700 px-4 py-3">
          <div>
            <h3 className="text-sm font-semibold text-gray-900 dark:text-white">Historical sighting lookup</h3>
            <p className="text-xs text-gray-600 dark:text-gray-400">
              Fetch audit events for a sighting ID (promoted, dismissed, or expired).
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <input
              type="text"
              value={historyLookupId}
              onChange={(e) => setHistoryLookupId(e.target.value)}
              placeholder="sighting UUID"
              className="w-48 rounded-md border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-900 px-3 py-1.5 text-sm text-gray-900 dark:text-gray-100 placeholder-gray-400 dark:placeholder-gray-500 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
            />
            <button
              type="button"
              onClick={() => fetchHistoryEvents(historyLookupId)}
              className="inline-flex items-center gap-2 rounded-md border border-gray-300 dark:border-gray-700 px-3 py-1.5 text-xs font-semibold text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-800"
            >
              <RefreshCcw className={`h-3.5 w-3.5 ${historyLoading ? "animate-spin" : ""}`} />
              Load
            </button>
            <input
              type="text"
              value={historyActorFilter}
              onChange={(e) => setHistoryActorFilter(e.target.value)}
              placeholder="actor filter"
              className="w-40 rounded-md border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-900 px-3 py-1.5 text-sm text-gray-900 dark:text-gray-100 placeholder-gray-400 dark:placeholder-gray-500 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
            />
            <input
              type="text"
              value={historyPartitionFilter}
              onChange={(e) => setHistoryPartitionFilter(e.target.value)}
              placeholder="partition filter"
              className="w-40 rounded-md border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-900 px-3 py-1.5 text-sm text-gray-900 dark:text-gray-100 placeholder-gray-400 dark:placeholder-gray-500 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
            />
            <button
              type="button"
              onClick={copyDeepLink}
              className="inline-flex items-center gap-2 rounded-md border border-gray-300 dark:border-gray-700 px-3 py-1.5 text-xs font-semibold text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-800"
            >
              Copy link
            </button>
          </div>
        </div>
        <div className="px-4 py-3 space-y-2">
          {historyLoading ? (
            <div className="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-300">
              <RefreshCcw className="h-4 w-4 animate-spin" />
              Loading audit events…
            </div>
          ) : historyError ? (
            <div className="rounded-md border border-dashed border-red-300 dark:border-red-700 bg-red-50/60 dark:bg-red-900/20 p-3 text-sm text-red-700 dark:text-red-300">
              {historyError}
            </div>
          ) : filteredHistoryEvents.length === 0 ? (
            <div className="text-sm text-gray-600 dark:text-gray-300">
              Enter a sighting ID (and optional filters) to see promotion/dismissal history.
            </div>
          ) : (
            <div className="divide-y divide-gray-200 dark:divide-gray-700">
              {filteredHistoryEvents.map((event) => (
                <div key={event.event_id ?? `${event.sighting_id}-${event.created_at}`} className="py-2 space-y-1">
                  <div className="flex items-center justify-between">
                    <span className="text-sm font-semibold text-gray-900 dark:text-white capitalize">
                      {event.event_type}
                    </span>
                    <span className="text-xs text-gray-500 dark:text-gray-400">{formatTimestamp(event.created_at)}</span>
                  </div>
                  <div className="text-xs text-gray-600 dark:text-gray-300">Actor: {event.actor || "system"}</div>
                  {event.details && Object.keys(event.details).length > 0 ? (
                    <div className="text-xs text-gray-600 dark:text-gray-300">
                      {Object.entries(event.details)
                        .map(([k, v]) => `${k}: ${v}`)
                        .join(" • ")}
                    </div>
                  ) : null}
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      {error ? (
        <div className="rounded-md border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800 dark:border-red-800 dark:bg-red-900/30 dark:text-red-200">
          {error}
        </div>
      ) : null}

      {identityMeta ? (
        <div className="flex items-start gap-3 rounded-md border border-blue-200 bg-blue-50 px-4 py-3 text-sm text-blue-800 dark:border-blue-900/40 dark:bg-blue-900/20 dark:text-blue-100">
          <div className="mt-0.5 rounded-full bg-white/70 p-1 text-blue-600 dark:bg-blue-900/60 dark:text-blue-100">
            <Info className="h-4 w-4" />
          </div>
          <div className="space-y-1">
            <p className="font-semibold text-blue-900 dark:text-blue-100">
              Sightings are held for review{identityMeta.sightings_only_mode ? " (sightings-only mode)" : ""}.
            </p>
            <p className="text-xs text-blue-900/80 dark:text-blue-100/80">
              {identityMeta.sightings_only_mode || identityMeta.promotion?.enabled === false
                ? "Auto-promotion is disabled, so even strong identifiers from sources like Armis stay in the sightings queue until you promote them."
                : "Sightings remain here until promotion policy thresholds are met or you manually promote/dismiss them."}
            </p>
          </div>
        </div>
      ) : null}

      <div className="grid grid-cols-1 xl:grid-cols-3 gap-4">
        <div className="xl:col-span-2 space-y-3">
          <div className="rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 shadow-sm">
            <div className="flex flex-wrap items-center gap-3 border-b border-gray-200 dark:border-gray-700 px-4 py-3">
              <div className="flex flex-1 flex-wrap gap-3">
                <input
                  type="text"
                  value={filters.search}
                  onChange={(e) => setFilters((prev) => ({ ...prev, search: e.target.value }))}
                  placeholder="Search IP, hostname, MAC, or partition"
                  className="w-full sm:w-64 rounded-md border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-gray-100 placeholder-gray-400 dark:placeholder-gray-500 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
                />
                <input
                  type="text"
                  value={filters.partition}
                  onChange={(e) => setFilters((prev) => ({ ...prev, partition: e.target.value }))}
                  placeholder="Partition filter"
                  className="w-full sm:w-48 rounded-md border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-gray-100 placeholder-gray-400 dark:placeholder-gray-500 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
                />
                <select
                  value={filters.source}
                  onChange={(e) => setFilters((prev) => ({ ...prev, source: e.target.value }))}
                  className="w-full sm:w-44 rounded-md border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-gray-100 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
                >
                  <option value="all">All sources</option>
                  {uniqueSources.map((src) => (
                    <option key={src} value={src}>
                      {src}
                    </option>
                  ))}
                </select>
              </div>
            </div>

            <div className="overflow-x-auto">
              {loading ? (
                <div className="p-6 text-center text-gray-600 dark:text-gray-300">Loading sightings…</div>
              ) : filteredSightings.length === 0 ? (
                <div className="p-6 text-center text-gray-500 dark:text-gray-400">
                  No active sightings match the current filters.
                </div>
              ) : (
                <div>
                  <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                    <thead className="bg-gray-50 dark:bg-gray-900/60">
                      <tr>
                        <th className="px-4 py-2 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-300">
                          IP / Hostname
                        </th>
                        <th className="px-4 py-2 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-300">
                          Partition
                        </th>
                        <th className="px-4 py-2 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-300">
                          Source
                        </th>
                        <th className="px-4 py-2 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-300">
                          Signals
                        </th>
                        <th className="px-4 py-2 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-300">
                          Last seen
                        </th>
                        <th className="px-4 py-2 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-300">
                          TTL
                        </th>
                        <th className="px-4 py-2 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-300">
                          Promotion
                        </th>
                        <th className="px-4 py-2 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-300">
                          Actions
                        </th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-gray-200 dark:divide-gray-700 bg-white dark:bg-gray-800">
                      {filteredSightings.map((sighting) => {
                        const isSelected = selected?.sighting_id === sighting.sighting_id;
                        const hostname = sighting.metadata?.hostname;
                        const mac = sighting.metadata?.mac;
                        const strong = hasStrongIdentifiers(sighting);
                        const fingerprint = sighting.fingerprint_id || sighting.metadata?.fingerprint_hash;
                        const promo = promotionDisplay(sighting);
                        const promoBadgeTone: Record<string, string> = {
                          success: "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-200",
                          warning: "bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-200",
                          default: "bg-gray-100 text-gray-700 dark:bg-gray-900/40 dark:text-gray-200",
                        };
                        return (
                          <tr
                            key={sighting.sighting_id}
                            className={`cursor-pointer ${
                              isSelected
                                ? "bg-blue-50 dark:bg-blue-900/20"
                                : "hover:bg-gray-50 dark:hover:bg-gray-900/40"
                            } ${highlightedId === sighting.sighting_id ? "ring-2 ring-blue-400 dark:ring-blue-500" : ""}`}
                            onClick={() => setSelected(sighting)}
                          >
                            <td className="px-4 py-3">
                              <div className="text-sm font-semibold text-gray-900 dark:text-white">{hostname || sighting.ip}</div>
                              <div className="text-xs text-gray-500 dark:text-gray-400 font-mono">{sighting.ip}</div>
                              {mac ? (
                                <div className="text-xs text-gray-500 dark:text-gray-400 font-mono">MAC: {mac}</div>
                              ) : null}
                            </td>
                            <td className="px-4 py-3 text-sm text-gray-700 dark:text-gray-200">{sighting.partition}</td>
                            <td className="px-4 py-3 text-sm text-gray-700 dark:text-gray-200 capitalize">{sighting.source}</td>
                            <td className="px-4 py-3 text-sm text-gray-700 dark:text-gray-200">
                              <div className="flex flex-wrap gap-1.5">
                                {strong ? (
                                  <span className="inline-flex items-center gap-1 rounded-full bg-emerald-100 px-2 py-1 text-[11px] font-semibold text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-200">
                                    <ShieldCheck className="h-3 w-3" />
                                    Strong ID
                                  </span>
                                ) : (
                                  <span className="inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-1 text-[11px] font-semibold text-amber-700 dark:bg-amber-900/30 dark:text-amber-200">
                                    <AlertTriangle className="h-3 w-3" />
                                    Weak signals
                                  </span>
                                )}
                                {fingerprint ? (
                                  <span className="inline-flex items-center gap-1 rounded-full bg-blue-100 px-2 py-1 text-[11px] font-semibold text-blue-700 dark:bg-blue-900/30 dark:text-blue-200">
                                    <Fingerprint className="h-3 w-3" />
                                    Fingerprint
                                  </span>
                                ) : null}
                                {sighting.metadata?.hostname ? (
                                  <span className="inline-flex items-center gap-1 rounded-full bg-gray-100 px-2 py-1 text-[11px] font-semibold text-gray-700 dark:bg-gray-900/40 dark:text-gray-200">
                                    Hostname
                                  </span>
                                ) : null}
                              </div>
                            </td>
                            <td className="px-4 py-3 text-sm text-gray-700 dark:text-gray-200">
                              <div>{relativeTime(sighting.last_seen)}</div>
                              <div className="text-xs text-gray-500 dark:text-gray-400">{formatTimestamp(sighting.last_seen)}</div>
                            </td>
                            <td className="px-4 py-3 text-sm text-gray-700 dark:text-gray-200">
                              <span
                                className={`inline-flex items-center rounded-full px-2 py-1 text-xs font-medium ${
                                  timeUntil(sighting.ttl_expires_at) === "expired"
                                    ? "bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-200"
                                    : "bg-gray-100 text-gray-700 dark:bg-gray-900/40 dark:text-gray-200"
                                }`}
                              >
                                <Clock className="h-3 w-3 mr-1" />
                                {timeUntil(sighting.ttl_expires_at)}
                              </span>
                            </td>
                            <td className="px-4 py-3 text-sm text-gray-700 dark:text-gray-200">
                              <div className="flex flex-col gap-1">
                                <span
                                  className={`inline-flex w-fit items-center gap-1 rounded-full px-2 py-1 text-xs font-semibold ${promoBadgeTone[promo.tone]}`}
                                >
                                  <Info className="h-3 w-3" />
                                  {promo.label}
                                </span>
                                <span className="text-xs text-gray-500 dark:text-gray-400">{promo.detail}</span>
                                {sighting.promotion?.next_eligible_at ? (
                                  <span className="text-[11px] text-gray-500 dark:text-gray-400">
                                    Eligible in {timeUntil(sighting.promotion.next_eligible_at)}
                                  </span>
                                ) : null}
                              </div>
                            </td>
                            <td className="px-4 py-3">
                              <div className="flex items-center gap-2">
                                <button
                                  type="button"
                                  disabled={busySighting === sighting.sighting_id}
                                  onClick={(e) => {
                                    e.stopPropagation();
                                    handlePromote(sighting.sighting_id);
                                  }}
                                  className="inline-flex items-center gap-1 rounded-md bg-emerald-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
                                >
                                  <CheckCircle2 className="h-3.5 w-3.5" />
                                  Promote
                                </button>
                                <button
                                  type="button"
                                  disabled={busySighting === sighting.sighting_id}
                                  onClick={(e) => {
                                    e.stopPropagation();
                                    handleDismiss(sighting.sighting_id);
                                  }}
                                  className="inline-flex items-center gap-1 rounded-md bg-gray-200 px-3 py-1.5 text-xs font-semibold text-gray-800 hover:bg-gray-300 dark:bg-gray-700 dark:text-gray-100 dark:hover:bg-gray-600 disabled:opacity-50"
                                >
                                  <XCircle className="h-3.5 w-3.5" />
                                  Dismiss
                                </button>
                              </div>
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                  <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between border-t border-gray-200 dark:border-gray-700 px-4 py-3 text-sm text-gray-700 dark:text-gray-200">
                    <div>
                      {formatRange(pageStart, pageEndDisplay, totalSightings)} (page {currentPage} of {totalPages})
                    </div>
                    <div className="flex flex-wrap items-center gap-3">
                      <label className="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">
                        Page size
                        <select
                          className="ml-2 rounded-md border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-900 px-2 py-1 text-sm text-gray-900 dark:text-gray-100"
                          value={pagination.limit}
                          onChange={(e) => handlePageSizeChange(Number(e.target.value))}
                        >
                          {[25, 50, 100, 200].map((size) => (
                            <option key={size} value={size}>
                              {size}
                            </option>
                          ))}
                        </select>
                      </label>
                      <div className="flex items-center gap-2">
                        <button
                          type="button"
                          disabled={!canPrev}
                          onClick={() => handlePageChange("prev")}
                          className="inline-flex items-center gap-1 rounded-md border border-gray-300 dark:border-gray-700 px-2.5 py-1 text-xs font-semibold text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-800 disabled:opacity-50"
                        >
                          <ChevronLeft className="h-4 w-4" />
                          Prev
                        </button>
                        <button
                          type="button"
                          disabled={!canNext}
                          onClick={() => handlePageChange("next")}
                          className="inline-flex items-center gap-1 rounded-md border border-gray-300 dark:border-gray-700 px-2.5 py-1 text-xs font-semibold text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-800 disabled:opacity-50"
                        >
                          Next
                          <ChevronRight className="h-4 w-4" />
                        </button>
                      </div>
                    </div>
                  </div>
                </div>
              )}
            </div>
          </div>
        </div>

        <div className="space-y-3">
          <div className="rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 shadow-sm">
            <div className="border-b border-gray-200 dark:border-gray-700 px-4 py-3">
              <div className="flex items-center justify-between">
                <div>
                  <h3 className="text-sm font-semibold text-gray-900 dark:text-white">Sighting details</h3>
                  <p className="text-xs text-gray-500 dark:text-gray-400">
                    Promote or dismiss a single sighting and review its metadata.
                  </p>
                </div>
                {selected ? (
                  <span className="inline-flex items-center gap-2 rounded-full bg-blue-50 px-3 py-1 text-xs font-semibold text-blue-700 dark:bg-blue-900/30 dark:text-blue-200">
                    <ShieldCheck className="h-3.5 w-3.5" />
                    Ready for override
                  </span>
                ) : null}
              </div>
            </div>
            {selected ? (
              <div className="space-y-4 px-4 py-3">
                <div className="flex flex-col gap-2">
                  <div className="text-sm font-semibold text-gray-900 dark:text-white">{selected.metadata?.hostname || selected.ip}</div>
                  <div className="flex flex-wrap gap-2 text-xs text-gray-500 dark:text-gray-400">
                    <span className="inline-flex items-center gap-1 rounded-full bg-gray-100 px-2 py-1 dark:bg-gray-900/40">
                      <Clock className="h-3 w-3" />
                      Last seen {relativeTime(selected.last_seen)}
                    </span>
                    <span className="inline-flex items-center gap-1 rounded-full bg-gray-100 px-2 py-1 dark:bg-gray-900/40">
                      Source: {selected.source}
                    </span>
                    <span className="inline-flex items-center gap-1 rounded-full bg-gray-100 px-2 py-1 dark:bg-gray-900/40">
                      Partition: {selected.partition}
                    </span>
                  </div>
                </div>

                <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                  <div className="rounded-md border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-900/40 p-3">
                    <div className="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">Identifiers</div>
                    <div className="mt-2 space-y-1 text-sm text-gray-900 dark:text-gray-100">
                      <div>IP: {selected.ip}</div>
                      <div>Hostname: {selectedMetadata.hostname || "—"}</div>
                      <div>MAC: {selectedMetadata.mac || "—"}</div>
                      <div>Fingerprint: {selected.fingerprint_id || selectedMetadata.fingerprint_hash || selectedMetadata.fingerprint_id || "—"}</div>
                    </div>
                  </div>
                  <div className="rounded-md border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-900/40 p-3">
                    <div className="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">Timing</div>
                    <div className="mt-2 space-y-1 text-sm text-gray-900 dark:text-gray-100">
                      <div>First seen: {formatTimestamp(selected.first_seen)}</div>
                      <div>TTL expires: {formatTimestamp(selected.ttl_expires_at)}</div>
                      <div>Time left: {timeUntil(selected.ttl_expires_at)}</div>
                    </div>
                  </div>
                </div>

                <div className="rounded-md border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-900/40 p-3">
                  <div className="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">Promotion status</div>
                  <div className="mt-2 flex flex-wrap items-center gap-2 text-sm text-gray-900 dark:text-gray-100">
                    <span
                      className={`inline-flex items-center gap-1 rounded-full px-2 py-1 text-xs font-semibold ${
                        selectedPromotion.tone === "success"
                          ? "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-200"
                          : selectedPromotion.tone === "warning"
                            ? "bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-200"
                            : "bg-gray-100 text-gray-700 dark:bg-gray-900/40 dark:text-gray-200"
                      }`}
                    >
                      <Info className="h-3 w-3" />
                      {selectedPromotion.label}
                    </span>
                    <span className="text-xs text-gray-500 dark:text-gray-400">{selectedPromotion.detail}</span>
                    {highlightedId === selected?.sighting_id ? (
                      <span className="inline-flex items-center gap-1 rounded-full bg-blue-100 px-2 py-1 text-[11px] font-semibold text-blue-700 dark:bg-blue-900/30 dark:text-blue-200">
                        Deep-linked from device
                      </span>
                    ) : null}
                  </div>
                  <div className="mt-2 text-xs text-gray-600 dark:text-gray-300 space-y-1">
                    {selected?.promotion?.satisfied?.length ? (
                      <div>
                        <span className="font-semibold text-gray-800 dark:text-gray-100">Satisfied: </span>
                        {selected.promotion.satisfied.join(", ")}
                      </div>
                    ) : null}
                    {selected?.promotion?.blockers?.length ? (
                      <div>
                        <span className="font-semibold text-gray-800 dark:text-gray-100">Blockers: </span>
                        {selected.promotion.blockers.join(", ")}
                      </div>
                    ) : null}
                    {selected?.promotion?.next_eligible_at ? (
                      <div>Eligible in {timeUntil(selected.promotion.next_eligible_at)}.</div>
                    ) : null}
                  </div>
                </div>

                <div className="rounded-md border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-900/40 p-3">
                  <div className="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">Why this is a sighting</div>
                  {reasonHints.length === 0 ? (
                    <div className="mt-2 text-sm text-gray-600 dark:text-gray-300">No additional context.</div>
                  ) : (
                    <ul className="mt-2 space-y-1 text-sm text-gray-900 dark:text-gray-100 list-disc list-inside">
                      {reasonHints.map((hint) => (
                        <li key={hint}>{hint}</li>
                      ))}
                    </ul>
                  )}
                </div>

                <div className="space-y-2">
                  <label htmlFor="dismiss-reason" className="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">
                    Override reason (optional)
                  </label>
                  <textarea
                    id="dismiss-reason"
                    value={dismissReason}
                    onChange={(e) => setDismissReason(e.target.value)}
                    rows={2}
                    className="w-full rounded-md border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-gray-100 placeholder-gray-400 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
                    placeholder="Why are you promoting or dismissing this sighting?"
                  />
                  <div className="flex flex-wrap gap-2">
                    <button
                      type="button"
                      disabled={busySighting === selected.sighting_id}
                      onClick={() => handlePromote(selected.sighting_id)}
                      className="inline-flex items-center gap-2 rounded-md bg-emerald-600 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
                    >
                      <CheckCircle2 className="h-4 w-4" />
                      Promote &amp; attach
                    </button>
                    <button
                      type="button"
                      disabled={busySighting === selected.sighting_id}
                      onClick={() => handleDismiss(selected.sighting_id)}
                      className="inline-flex items-center gap-2 rounded-md bg-gray-200 px-4 py-2 text-sm font-semibold text-gray-800 hover:bg-gray-300 dark:bg-gray-700 dark:text-gray-100 dark:hover:bg-gray-600 disabled:opacity-50"
                    >
                      <XCircle className="h-4 w-4" />
                      Dismiss sighting
                    </button>
                  </div>
                </div>
              </div>
            ) : (
              <div className="p-4 text-sm text-gray-500 dark:text-gray-300">Select a sighting to view details.</div>
            )}
          </div>

          <div className="rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 shadow-sm">
            <div className="flex items-center justify-between border-b border-gray-200 dark:border-gray-700 px-4 py-3">
              <div>
                <h3 className="text-sm font-semibold text-gray-900 dark:text-white">Audit trail</h3>
                <p className="text-xs text-gray-500 dark:text-gray-400">
                  Recent promotion, dismissal, or expiry events for the selected sighting.
                </p>
              </div>
              <button
                type="button"
                onClick={() => selected?.sighting_id && fetchEvents(selected.sighting_id)}
                className="inline-flex items-center gap-2 rounded-md border border-gray-300 dark:border-gray-700 px-3 py-1.5 text-xs font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-800"
              >
                <RefreshCcw className="h-3.5 w-3.5" />
                Refresh events
              </button>
            </div>
            {selected ? (
              events.length === 0 ? (
                <div className="p-4 text-sm text-gray-500 dark:text-gray-300">No audit events recorded yet.</div>
              ) : (
                <div className="divide-y divide-gray-200 dark:divide-gray-700">
                  {events.map((event) => (
                    <div key={event.event_id || `${event.created_at}-${event.event_type}`} className="px-4 py-3 space-y-1">
                      <div className="flex items-center justify-between">
                        <div className="flex items-center gap-2">
                          {event.event_type === "promoted" ? (
                            <CheckCircle2 className="h-4 w-4 text-emerald-500" />
                          ) : event.event_type === "dismissed" ? (
                            <XCircle className="h-4 w-4 text-gray-500" />
                          ) : (
                            <AlertTriangle className="h-4 w-4 text-amber-500" />
                          )}
                          <span className="text-sm font-semibold text-gray-900 dark:text-white capitalize">
                            {event.event_type}
                          </span>
                        </div>
                        <span className="text-xs text-gray-500 dark:text-gray-400">{relativeTime(event.created_at)}</span>
                      </div>
                      <div className="text-sm text-gray-700 dark:text-gray-200">
                        Actor: <span className="font-medium">{event.actor || "system"}</span>
                        {event.device_id ? ` • Device ${event.device_id}` : ""}
                      </div>
                      {renderEventDetails(event.details)}
                    </div>
                  ))}
                </div>
              )
            ) : (
              <div className="p-4 text-sm text-gray-500 dark:text-gray-300">Select a sighting to see audit history.</div>
            )}
          </div>
        </div>

        <div className="space-y-3">
          <div className="rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 shadow-sm">
            <div className="flex items-center justify-between border-b border-gray-200 dark:border-gray-700 px-4 py-3">
              <div>
                <h3 className="text-sm font-semibold text-gray-900 dark:text-white">Subnet policies</h3>
                <p className="text-xs text-gray-500 dark:text-gray-400">
                  Classification, promotion rules, and IP-as-ID exceptions by subnet.
                </p>
              </div>
              <button
                type="button"
                onClick={fetchPolicies}
                className="inline-flex items-center gap-2 rounded-md border border-gray-300 dark:border-gray-700 px-3 py-1.5 text-xs font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-800"
              >
                <RefreshCcw className="h-3.5 w-3.5" />
                Refresh
              </button>
            </div>
            {policyError ? (
              <div className="p-4 text-sm text-red-700 dark:text-red-200 bg-red-50 dark:bg-red-900/30 border-b border-red-200 dark:border-red-800">
                {policyError}
              </div>
            ) : null}
            <div className="overflow-x-auto">
              {policiesLoading ? (
                <div className="p-4 text-sm text-gray-600 dark:text-gray-300">Loading policies…</div>
              ) : policies.length === 0 ? (
                <div className="p-4 text-sm text-gray-600 dark:text-gray-300">No subnet policies configured.</div>
              ) : (
                <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                  <thead className="bg-gray-50 dark:bg-gray-900/60">
                    <tr>
                      <th className="px-4 py-2 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-300">
                        Subnet
                      </th>
                      <th className="px-4 py-2 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-300">
                        Class
                      </th>
                      <th className="px-4 py-2 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-300">
                        Promotion
                      </th>
                      <th className="px-4 py-2 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-300">
                        IP-as-ID
                      </th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-gray-200 dark:divide-gray-700 bg-white dark:bg-gray-800">
                    {policies.map((policy) => (
                      <tr key={policy.subnet_id} className="hover:bg-gray-50 dark:hover:bg-gray-900/40">
                        <td className="px-4 py-3 text-sm text-gray-900 dark:text-white font-mono flex items-center gap-2">
                          <MapPin className="h-4 w-4 text-blue-500" />
                          {policy.cidr}
                        </td>
                        <td className="px-4 py-3 text-sm text-gray-700 dark:text-gray-200 capitalize">
                          {policy.classification || "unknown"}
                        </td>
                        <td className="px-4 py-3 text-sm text-gray-700 dark:text-gray-200">
                          {summarizePromotionRules(policy.promotion_rules as Record<string, unknown>)}
                        </td>
                        <td className="px-4 py-3 text-sm">
                          <span
                            className={`inline-flex items-center rounded-full px-2 py-1 text-xs font-semibold ${
                              policy.allow_ip_as_id
                                ? "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-200"
                                : "bg-gray-100 text-gray-700 dark:bg-gray-900/40 dark:text-gray-200"
                            }`}
                          >
                            {policy.allow_ip_as_id ? "Allowed" : "Blocked"}
                          </span>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </div>
          </div>

          <div className="rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 shadow-sm">
            <div className="flex items-center justify-between border-b border-gray-200 dark:border-gray-700 px-4 py-3">
              <div>
                <h3 className="text-sm font-semibold text-gray-900 dark:text-white">Merge history</h3>
                <p className="text-xs text-gray-500 dark:text-gray-400">
                  Recent device merges and reasons. Filter by device when investigating overrides.
                </p>
              </div>
              <div className="flex items-center gap-2">
                <input
                  type="text"
                  value={mergeDeviceFilter}
                  onChange={(e) => setMergeDeviceFilter(e.target.value)}
                  placeholder="Filter by device ID"
                  className="w-44 rounded-md border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-900 px-3 py-1.5 text-xs text-gray-900 dark:text-gray-100 placeholder-gray-400 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
                />
                <button
                  type="button"
                  onClick={() => fetchMergeHistory(mergeDeviceFilter)}
                  className="inline-flex items-center gap-2 rounded-md border border-gray-300 dark:border-gray-700 px-3 py-1.5 text-xs font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-800"
                >
                  <GitMerge className="h-3.5 w-3.5" />
                  Apply
                </button>
              </div>
            </div>
            {mergeError ? (
              <div className="p-4 text-sm text-red-700 dark:text-red-200 bg-red-50 dark:bg-red-900/30 border-b border-red-200 dark:border-red-800">
                {mergeError}
              </div>
            ) : null}
            <div className="overflow-x-auto">
              {mergeLoading ? (
                <div className="p-4 text-sm text-gray-600 dark:text-gray-300">Loading merge history…</div>
              ) : mergeEvents.length === 0 ? (
                <div className="p-4 text-sm text-gray-600 dark:text-gray-300">No merge audit records found.</div>
              ) : (
                <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
                  <thead className="bg-gray-50 dark:bg-gray-900/60">
                    <tr>
                      <th className="px-4 py-2 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-300">
                        From → To
                      </th>
                      <th className="px-4 py-2 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-300">
                        Reason
                      </th>
                      <th className="px-4 py-2 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-300">
                        Score
                      </th>
                      <th className="px-4 py-2 text-left text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-300">
                        When
                      </th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-gray-200 dark:divide-gray-700 bg-white dark:bg-gray-800">
                    {mergeEvents.map((event) => (
                      <tr key={event.event_id} className="hover:bg-gray-50 dark:hover:bg-gray-900/40">
                        <td className="px-4 py-3 text-sm text-gray-900 dark:text-white">
                          <div className="font-mono text-xs text-gray-700 dark:text-gray-200">
                            {event.from_device_id} → {event.to_device_id}
                          </div>
                          <div className="text-xs text-gray-500 dark:text-gray-400">Source: {event.source || "unknown"}</div>
                        </td>
                        <td className="px-4 py-3 text-sm text-gray-700 dark:text-gray-200">
                          {event.reason || "merge"}
                          {event.details && Object.keys(event.details).length ? (
                            <div className="text-xs text-gray-500 dark:text-gray-400">
                              {Object.entries(event.details)
                                .map(([k, v]) => `${k}: ${v}`)
                                .join(" · ")}
                            </div>
                          ) : null}
                        </td>
                        <td className="px-4 py-3 text-sm text-gray-700 dark:text-gray-200">
                          {typeof event.confidence_score === "number" ? event.confidence_score.toFixed(2) : "—"}
                        </td>
                        <td className="px-4 py-3 text-sm text-gray-700 dark:text-gray-200">
                          {relativeTime(event.created_at)}
                          <div className="text-xs text-gray-500 dark:text-gray-400">{formatTimestamp(event.created_at)}</div>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default SightingsDashboard;
