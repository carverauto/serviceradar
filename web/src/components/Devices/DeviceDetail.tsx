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

import React, { useState, useEffect, useCallback, useMemo } from "react";
import Link from "next/link";
import {
  Server,
  CheckCircle,
  XCircle,
  Activity,
  BarChart3,
  Clock,
  MapPin,
  Loader2,
  AlertTriangle,
  ArrowLeft,
  TrendingUp,
} from "lucide-react";

import { useAuth } from "@/components/AuthProvider";
import { fetchAPI } from "@/lib/client-api";
import { escapeSrqlValue } from "@/lib/srql";
import { formatTimestampForDisplay } from "@/utils/traceTimestamp";
import {
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  Legend,
} from "recharts";
import ServiceRegistryPanel from "./ServiceRegistryPanel";
import DeleteDeviceButton from "./DeleteDeviceButton";
import type { DeviceAliasHistory, DeviceAliasRecord } from "@/types/devices";
import { buildAliasHistoryFromMetadata } from "@/lib/alias";

interface SrqlResponse<T> {
  results?: T[];
  pagination?: unknown;
  error?: string;
}

interface DeviceRecord {
  device_id: string;
  agent_id?: string;
  poller_id?: string;
  discovery_sources?: string[] | string;
  ip?: string;
  mac?: string;
  hostname?: string;
  first_seen?: string;
  last_seen?: string;
  is_available?: boolean;
  metadata?: Record<string, unknown>;
  device_type?: string;
  service_type?: string;
  service_status?: string;
  last_heartbeat?: string | null;
  os_info?: string | null;
  version_info?: string | null;
}

interface DeviceAvailabilityRow {
  timestamp: string;
  available?: boolean;
  discovery_source?: string;
  poller_id?: string;
  agent_id?: string;
}

interface AvailabilitySegment {
  start: number;
  end: number;
  available: boolean;
}

interface TimeseriesMetric {
  name: string;
  type: string;
  value: string;
  timestamp: string;
  target_device_ip?: string;
  device_id?: string;
  partition?: string;
  poller_id?: string;
  metadata?: string;
}

interface CpuMetricRow {
  timestamp: string;
  usage_percent?: number;
  usage?: number;
}

interface MemoryMetricRow {
  timestamp: string;
  used_bytes?: number;
  total_bytes?: number;
  used?: number;
  total?: number;
}

interface DiskMetricRow {
  timestamp: string;
  mount_point?: string;
  used_bytes?: number;
  total_bytes?: number;
  used?: number;
  total?: number;
}

interface SysmonSummary {
  cpu?: {
    averageUsage: number;
    coreCount: number;
    timestamp: string;
  };
  memory?: {
    usedBytes: number;
    totalBytes: number;
    percent: number;
    timestamp: string;
  };
  disks?: Array<{
    mountPoint: string;
    usedBytes: number;
    totalBytes: number;
    percent: number;
    timestamp: string;
  }>;
}

const COLOR_VARIANTS: Record<string, { bg: string; text: string }> = {
  blue: {
    bg: "bg-blue-100 dark:bg-blue-900/30",
    text: "text-blue-600 dark:text-blue-400",
  },
  green: {
    bg: "bg-emerald-100 dark:bg-emerald-900/30",
    text: "text-emerald-600 dark:text-emerald-400",
  },
  purple: {
    bg: "bg-purple-100 dark:bg-purple-900/30",
    text: "text-purple-600 dark:text-purple-400",
  },
  orange: {
    bg: "bg-orange-100 dark:bg-orange-900/30",
    text: "text-orange-600 dark:text-orange-400",
  },
  red: {
    bg: "bg-rose-100 dark:bg-rose-900/30",
    text: "text-rose-600 dark:text-rose-400",
  },
};

const TIME_RANGE_CONFIG: Record<string, { label: string; durationMs: number }> =
  {
    "1h": { label: "Last Hour", durationMs: 60 * 60 * 1000 },
    "6h": { label: "Last 6 Hours", durationMs: 6 * 60 * 60 * 1000 },
    "24h": { label: "Last 24 Hours", durationMs: 24 * 60 * 60 * 1000 },
    "7d": { label: "Last 7 Days", durationMs: 7 * 24 * 60 * 60 * 1000 },
  };

const DEFAULT_TIME_RANGE = "24h";

const ensureArray = (value: string[] | string | undefined): string[] => {
  if (!value) return [];
  if (Array.isArray(value)) return value;
  return value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
};

const normalizeMetricValue = (metric: TimeseriesMetric): number => {
  const rawValue = parseFloat(metric.value);
  if (!Number.isFinite(rawValue)) {
    return NaN;
  }
  if (metric.type?.toLowerCase() === "icmp") {
    return rawValue / 1_000_000;
  }
  return rawValue;
};

const safeNumber = (value: unknown): number | null => {
  if (value === null || value === undefined) return null;
  const num = Number(value);
  return Number.isFinite(num) ? num : null;
};

const formatDuration = (ms: number): string => {
  if (ms <= 0) return "0s";

  const totalSeconds = Math.floor(ms / 1000);
  const days = Math.floor(totalSeconds / 86400);
  const hours = Math.floor((totalSeconds % 86400) / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;

  const parts: string[] = [];
  if (days) parts.push(`${days}d`);
  if (hours) parts.push(`${hours}h`);
  if (minutes) parts.push(`${minutes}m`);
  if (!parts.length && seconds) parts.push(`${seconds}s`);
  if (!parts.length) parts.push("0s");

  return parts.slice(0, 2).join(" ");
};

const formatRelativeTime = (date: Date | null | undefined): string => {
  if (!date || Number.isNaN(date.getTime())) return "—";
  const diffMs = Date.now() - date.getTime();
  if (!Number.isFinite(diffMs)) return "—";
  const diffMinutes = Math.floor(diffMs / 60000);
  if (diffMinutes < 1) return "just now";
  if (diffMinutes < 60) return `${diffMinutes}m ago`;
  const diffHours = Math.floor(diffMinutes / 60);
  if (diffHours < 24) return `${diffHours}h ago`;
  const diffDays = Math.floor(diffHours / 24);
  if (diffDays < 7) return `${diffDays}d ago`;
  const diffWeeks = Math.floor(diffDays / 7);
  return `${diffWeeks}w ago`;
};

const formatBytes = (bytes: number): string => {
  if (!Number.isFinite(bytes)) return "—";
  if (bytes === 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB", "PB"];
  const idx = Math.floor(Math.log(bytes) / Math.log(1024));
  const value = bytes / Math.pow(1024, idx);
  return `${value.toFixed(value < 10 ? 1 : 0)} ${units[idx]}`;
};

const buildTimelineSegments = (
  events: DeviceAvailabilityRow[],
  windowStart: Date,
  windowEnd: Date,
): {
  segments: AvailabilitySegment[];
  totalMs: number;
  uptimeMs: number;
  latestEvent?: DeviceAvailabilityRow;
  initialState: boolean;
} => {
  if (!events.length) {
    const totalMs = Math.max(windowEnd.getTime() - windowStart.getTime(), 0);
    return {
      segments: [],
      totalMs,
      uptimeMs: 0,
      latestEvent: undefined,
      initialState: false,
    };
  }

  const sorted = [...events].sort(
    (a, b) => new Date(a.timestamp).getTime() - new Date(b.timestamp).getTime(),
  );

  let currentState = sorted[0]?.available ?? false;
  const startMs = windowStart.getTime();
  const endMs = windowEnd.getTime();

  for (const event of sorted) {
    const ts = new Date(event.timestamp).getTime();
    if (ts <= startMs) {
      currentState = event.available ?? currentState;
    } else {
      break;
    }
  }

  let cursor = startMs;
  let uptimeMs = 0;
  const segments: AvailabilitySegment[] = [];

  for (const event of sorted) {
    const eventTime = new Date(event.timestamp).getTime();
    if (eventTime <= startMs) {
      currentState = event.available ?? currentState;
      continue;
    }
    if (eventTime > endMs) break;

    const clampedStart = Math.max(cursor, startMs);
    const clampedEnd = Math.min(eventTime, endMs);

    if (clampedEnd > clampedStart) {
      segments.push({
        start: clampedStart,
        end: clampedEnd,
        available: currentState,
      });
      if (currentState) uptimeMs += clampedEnd - clampedStart;
    }

    currentState = event.available ?? currentState;
    cursor = eventTime;
  }

  if (cursor < endMs) {
    const clampedStart = Math.max(cursor, startMs);
    if (endMs > clampedStart) {
      segments.push({
        start: clampedStart,
        end: endMs,
        available: currentState,
      });
      if (currentState) uptimeMs += endMs - clampedStart;
    }
  }

  if (!segments.length) {
    segments.push({
      start: startMs,
      end: endMs,
      available: currentState,
    });
    if (currentState) uptimeMs = endMs - startMs;
  }

  return {
    segments,
    totalMs: Math.max(endMs - startMs, 0),
    uptimeMs,
    latestEvent: sorted[sorted.length - 1],
    initialState: segments[0]?.available ?? currentState,
  };
};

const AvailabilityTimeline: React.FC<{
  segments: AvailabilitySegment[];
  totalMs: number;
  start: Date;
  end: Date;
}> = ({ segments, totalMs, start, end }) => {
  if (!segments.length || totalMs <= 0) {
    return (
      <div className="rounded-lg border border-dashed border-gray-300 dark:border-gray-700 p-6 text-center text-sm text-gray-500 dark:text-gray-400">
        No availability changes captured for this period.
      </div>
    );
  }

  return (
    <div className="space-y-3">
      <div className="flex text-xs text-gray-500 dark:text-gray-400">
        <span>{start.toLocaleString()}</span>
        <span className="ml-auto">{end.toLocaleString()}</span>
      </div>
      <div className="flex h-4 overflow-hidden rounded-full border border-gray-200 dark:border-gray-700 bg-gray-200 dark:bg-gray-800">
        {segments.map((segment, idx) => {
          const duration = segment.end - segment.start;
          const percent = Math.max((duration / totalMs) * 100, 0.5);
          return (
            <div
              key={`${segment.start}-${idx}`}
              className={`transition-all ${
                segment.available ? "bg-emerald-500" : "bg-rose-500"
              }`}
              style={{ width: `${percent}%` }}
              title={`${segment.available ? "Available" : "Unavailable"} • ${formatDuration(duration)}`}
            />
          );
        })}
      </div>
      <div className="flex items-center gap-4 text-xs">
        <div className="flex items-center gap-2 text-emerald-500">
          <span className="h-2 w-2 rounded-full bg-emerald-500" />
          Available
        </div>
        <div className="flex items-center gap-2 text-rose-500">
          <span className="h-2 w-2 rounded-full bg-rose-500" />
          Unavailable
        </div>
      </div>
    </div>
  );
};

const MetricCard: React.FC<{
  title: string;
  value: string | number;
  icon: React.ReactNode;
  color?: keyof typeof COLOR_VARIANTS;
  subtitle?: string;
}> = ({ title, value, icon, color = "blue", subtitle }) => {
  const colors = COLOR_VARIANTS[color] ?? COLOR_VARIANTS.blue;

  return (
    <div className="rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 p-4">
      <div className="flex items-center">
        <div className={`mr-4 rounded-md p-2 ${colors.bg}`}>
          <div className={`flex items-center justify-center ${colors.text}`}>
            {icon}
          </div>
        </div>
        <div className="flex-1">
          <p className="text-sm text-gray-600 dark:text-gray-400">{title}</p>
          <p className="text-2xl font-semibold text-gray-900 dark:text-white">
            {value}
          </p>
          {subtitle && (
            <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
              {subtitle}
            </p>
          )}
        </div>
      </div>
    </div>
  );
};

interface DeviceDetailProps {
  deviceId: string;
}

const DeviceDetail: React.FC<DeviceDetailProps> = ({ deviceId }) => {
  const { token } = useAuth();

  const [device, setDevice] = useState<DeviceRecord | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [metrics, setMetrics] = useState<TimeseriesMetric[]>([]);
  const [metricsLoading, setMetricsLoading] = useState(false);
  const [selectedMetricType, setSelectedMetricType] = useState<string>("all");

  const [timeRange, setTimeRange] = useState<string>(DEFAULT_TIME_RANGE);

  const [availabilityRows, setAvailabilityRows] = useState<
    DeviceAvailabilityRow[]
  >([]);
  const [availabilityLoading, setAvailabilityLoading] = useState(false);
  const [availabilityError, setAvailabilityError] = useState<string | null>(
    null,
  );

  const [sysmonSummary, setSysmonSummary] = useState<SysmonSummary | null>(
    null,
  );
  const [sysmonLoading, setSysmonLoading] = useState(false);
  const [sysmonError, setSysmonError] = useState<string | null>(null);

  const [aliasHistory, setAliasHistory] = useState<DeviceAliasHistory | null>(
    null,
  );
  const [aliasLoading, setAliasLoading] = useState(false);
  const [aliasError, setAliasError] = useState<string | null>(null);

  const timeWindow = useMemo(() => {
    const config =
      TIME_RANGE_CONFIG[timeRange] ?? TIME_RANGE_CONFIG[DEFAULT_TIME_RANGE];
    const end = new Date();
    const start = new Date(end.getTime() - config.durationMs);
    return {
      label: config.label,
      start,
      end,
    };
  }, [timeRange]);

  const runSrqlQuery = useCallback(
    async (query: string, limit?: number) => {
      const body: Record<string, unknown> = { query };
      if (typeof limit === "number") {
        body.limit = limit;
      }

      return fetchAPI<SrqlResponse<unknown>>("/api/query", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(token && { Authorization: `Bearer ${token}` }),
        },
        body: JSON.stringify(body),
      });
    },
    [token],
  );

  const normalizeDevice = (record: DeviceRecord): DeviceRecord => {
    const normalized: DeviceRecord = {
      ...record,
    };

    if (record.metadata && typeof record.metadata === "string") {
      try {
        normalized.metadata = JSON.parse(record.metadata) as Record<
          string,
          unknown
        >;
      } catch {
        normalized.metadata = { raw: record.metadata };
      }
    }

    if (record.discovery_sources) {
      normalized.discovery_sources = ensureArray(record.discovery_sources);
    }

    return normalized;
  };

  const fetchDevice = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const escapedId = escapeSrqlValue(deviceId);
      const query = `in:devices device_id:"${escapedId}" limit:1`;
      const response = (await runSrqlQuery(
        query,
        1,
      )) as SrqlResponse<DeviceRecord>;
      const record = response.results?.[0];
      if (!record) {
        setError("Device not found");
        setDevice(null);
        return;
      }
      setDevice(normalizeDevice(record));
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to load device";
      setError(message);
      setDevice(null);
    } finally {
      setLoading(false);
    }
  }, [deviceId, runSrqlQuery]);

  const fetchAvailability = useCallback(async () => {
    setAvailabilityLoading(true);
    setAvailabilityError(null);
    try {
      const escapedId = escapeSrqlValue(deviceId);
      const { start, end } = timeWindow;
      const queryParts = [
        "in:device_updates",
        `device_id:"${escapedId}"`,
        `time:[${start.toISOString()},${end.toISOString()}]`,
        "sort:timestamp:asc",
      ];
      const query = queryParts.join(" ");
      const response = (await runSrqlQuery(
        query,
        1000,
      )) as SrqlResponse<DeviceAvailabilityRow>;
      setAvailabilityRows(response.results ?? []);
    } catch (err) {
      const message =
        err instanceof Error
          ? err.message
          : "Failed to load availability history";
      setAvailabilityError(message);
      setAvailabilityRows([]);
    } finally {
      setAvailabilityLoading(false);
    }
  }, [deviceId, runSrqlQuery, timeWindow]);

  const fetchMetrics = useCallback(async () => {
    setMetricsLoading(true);
    try {
      const escapedId = escapeSrqlValue(deviceId);
      const { start, end } = timeWindow;
      const clauses = [
        "in:timeseries_metrics",
        `device_id:"${escapedId}"`,
        `time:[${start.toISOString()},${end.toISOString()}]`,
        "sort:timestamp:asc",
      ];

      if (selectedMetricType !== "all") {
        clauses.push(`metric_type:"${escapeSrqlValue(selectedMetricType)}"`);
      }

      const limit = selectedMetricType === "all" ? 2000 : 1500;
      const query = clauses.join(" ");
      const response = (await runSrqlQuery(query, limit)) as SrqlResponse<
        Record<string, unknown>
      >;

      const mapped = (response.results ?? []).map((row) => {
        const metricName =
          (row.metric_name as string | undefined) ??
          (row.name as string | undefined) ??
          (row.metric as string | undefined) ??
          "metric";
        const metricType =
          (row.metric_type as string | undefined) ??
          (row.type as string | undefined) ??
          "unknown";
        const value =
          safeNumber(row.value) ??
          safeNumber(row.metric_value) ??
          safeNumber(row.numeric_value) ??
          0;
        const metadata =
          typeof row.metadata === "string"
            ? row.metadata
            : row.metadata
              ? JSON.stringify(row.metadata)
              : undefined;

        return {
          name: metricName,
          type: metricType,
          value: String(value),
          timestamp: (row.timestamp as string) ?? new Date().toISOString(),
          target_device_ip: row.target_device_ip as string | undefined,
          device_id: row.device_id as string | undefined,
          partition: row.partition as string | undefined,
          poller_id: row.poller_id as string | undefined,
          metadata,
        } as TimeseriesMetric;
      });

      setMetrics(mapped);
    } catch (err) {
      console.error("Failed to fetch metrics:", err);
      setMetrics([]);
    } finally {
      setMetricsLoading(false);
    }
  }, [deviceId, runSrqlQuery, selectedMetricType, timeWindow]);

  const fetchSysmonSummary = useCallback(async () => {
    setSysmonLoading(true);
    setSysmonError(null);
    try {
      const escapedId = escapeSrqlValue(deviceId);

      const [cpuResp, memoryResp, diskResp] = await Promise.all([
        runSrqlQuery(
          `in:cpu_metrics device_id:"${escapedId}" sort:timestamp:desc`,
          64,
        ) as Promise<SrqlResponse<CpuMetricRow>>,
        runSrqlQuery(
          `in:memory_metrics device_id:"${escapedId}" sort:timestamp:desc`,
          4,
        ) as Promise<SrqlResponse<MemoryMetricRow>>,
        runSrqlQuery(
          `in:disk_metrics device_id:"${escapedId}" sort:timestamp:desc`,
          24,
        ) as Promise<SrqlResponse<DiskMetricRow>>,
      ]);

      const summary: SysmonSummary = {};

      const cpuRows = cpuResp.results ?? [];
      if (cpuRows.length) {
        const latestTs = cpuRows.reduce((latest, row) => {
          const ts = new Date(row.timestamp).getTime();
          return ts > latest ? ts : latest;
        }, new Date(cpuRows[0].timestamp).getTime());

        const latestRows = cpuRows.filter(
          (row) => new Date(row.timestamp).getTime() === latestTs,
        );

        const usageValues = latestRows
          .map((row) => safeNumber(row.usage_percent ?? row.usage))
          .filter((value): value is number => value !== null);

        if (usageValues.length) {
          const avg =
            usageValues.reduce((acc, value) => acc + value, 0) /
            usageValues.length;
          summary.cpu = {
            averageUsage: avg,
            coreCount: usageValues.length,
            timestamp: new Date(latestTs).toISOString(),
          };
        }
      }

      const memoryRow = (memoryResp.results ?? [])[0];
      if (memoryRow) {
        const used = safeNumber(memoryRow.used_bytes ?? memoryRow.used);
        const total = safeNumber(memoryRow.total_bytes ?? memoryRow.total);
        if (used !== null && total !== null && total > 0) {
          summary.memory = {
            usedBytes: used,
            totalBytes: total,
            percent: (used / total) * 100,
            timestamp: memoryRow.timestamp,
          };
        }
      }

      const diskRows = diskResp.results ?? [];
      if (diskRows.length) {
        const disks = diskRows
          .map((row) => {
            const used = safeNumber(row.used_bytes ?? row.used);
            const total = safeNumber(row.total_bytes ?? row.total);
            if (used === null || total === null || total <= 0) return null;
            return {
              mountPoint: row.mount_point ?? "unknown",
              usedBytes: used,
              totalBytes: total,
              percent: (used / total) * 100,
              timestamp: row.timestamp,
            };
          })
          .filter((entry): entry is NonNullable<typeof entry> => entry !== null)
          .sort((a, b) => b.percent - a.percent)
          .slice(0, 3);

        if (disks.length) {
          summary.disks = disks;
        }
      }

      setSysmonSummary(summary);
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to load system metrics";
      setSysmonError(message);
      setSysmonSummary(null);
    } finally {
      setSysmonLoading(false);
    }
  }, [deviceId, runSrqlQuery]);

  useEffect(() => {
    void fetchDevice();
  }, [fetchDevice]);

  useEffect(() => {
    void fetchAvailability();
  }, [fetchAvailability]);

  useEffect(() => {
    void fetchMetrics();
  }, [fetchMetrics]);

  useEffect(() => {
    void fetchSysmonSummary();
  }, [fetchSysmonSummary]);

  useEffect(() => {
    setAliasLoading(true);
    try {
      if (device && device.metadata && typeof device.metadata === "object") {
        const history = buildAliasHistoryFromMetadata(
          device.metadata as Record<string, unknown>,
        );
        setAliasHistory(history);
        setAliasError(null);
      } else {
        setAliasHistory(null);
        setAliasError(null);
      }
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to process alias history";
      setAliasError(message);
      setAliasHistory(null);
    } finally {
      setAliasLoading(false);
    }
  }, [device]);

  const availabilityInfo = useMemo(() => {
    const { segments, totalMs, uptimeMs, latestEvent, initialState } =
      buildTimelineSegments(availabilityRows, timeWindow.start, timeWindow.end);
    const uptimePct = totalMs > 0 ? (uptimeMs / totalMs) * 100 : 0;

    return {
      segments,
      totalMs,
      uptimeMs,
      uptimePct,
      downtimeMs: Math.max(totalMs - uptimeMs, 0),
      latestEvent,
      initialState,
    };
  }, [availabilityRows, timeWindow]);

  const metricTypes = useMemo(() => {
    const types = Array.from(
      new Set(metrics.map((metric) => metric.type)),
    ).sort();
    return types;
  }, [metrics]);

  const metricStats = useMemo(
    () => ({
      total: metrics.length,
      types: metricTypes.length,
      latestTimestamp:
        metrics.length > 0
          ? new Date(
              Math.max(
                ...metrics.map((metric) =>
                  new Date(metric.timestamp).getTime(),
                ),
              ),
            )
          : null,
      oldestTimestamp:
        metrics.length > 0
          ? new Date(
              Math.min(
                ...metrics.map((metric) =>
                  new Date(metric.timestamp).getTime(),
                ),
              ),
            )
          : null,
      activeCollectors: new Set(
        metrics.map((metric) => metric.poller_id).filter(Boolean),
      ).size,
    }),
    [metricTypes.length, metrics],
  );

  const icmpSnapshot = useMemo(() => {
    const icmpMetrics = metrics.filter(
      (metric) => metric.type.toLowerCase() === "icmp",
    );
    if (!icmpMetrics.length) return null;
    const latest = icmpMetrics.reduce((latestMetric, metric) => {
      const ts = new Date(metric.timestamp).getTime();
      const latestTs = new Date(latestMetric.timestamp).getTime();
      return ts > latestTs ? metric : latestMetric;
    }, icmpMetrics[0]);
    const numericValue = normalizeMetricValue(latest);
    if (!Number.isFinite(numericValue)) return null;
    return {
      value: numericValue,
      timestamp: latest.timestamp,
      name: latest.name,
    };
  }, [metrics]);

  const metadataEntries = useMemo(() => {
    if (!device || !device.metadata) return [];
    const ALIAS_PREFIXES = ["_alias_", "service_alias:", "ip_alias:"];
    return Object.entries(device.metadata)
      .filter(
        ([key]) => !ALIAS_PREFIXES.some((prefix) => key.startsWith(prefix)),
      )
      .map(
        ([key, value]) =>
          [
            key,
            typeof value === "object" ? JSON.stringify(value) : String(value),
          ] as [string, string],
      )
      .sort((a, b) => a[0].localeCompare(b[0]));
  }, [device]);

  const chartData = useMemo(() => {
    if (!metrics.length) return [];
    const grouped = new Map<number, Record<string, number | string>>();
    metrics.forEach((metric) => {
      const timestamp = new Date(metric.timestamp).getTime();
      const key = `${metric.type}_${metric.name}`;
      const value = normalizeMetricValue(metric);
      const existing = grouped.get(timestamp) ?? {
        timestamp,
        time: new Date(timestamp).toLocaleString(),
      };
      if (Number.isFinite(value)) {
        existing[key] = value;
      }
      grouped.set(timestamp, existing);
    });
    return Array.from(grouped.values()).sort(
      (a, b) => (a.timestamp as number) - (b.timestamp as number),
    );
  }, [metrics]);

  const chartSeriesKeys = useMemo(() => {
    const keys = Array.from(
      new Set(
        metrics
          .map((metric) => `${metric.type}_${metric.name}`)
          .filter((key) => !!key),
      ),
    );
    return keys.slice(0, 10);
  }, [metrics]);

  if (loading) {
    return (
      <div className="flex items-center justify-center p-12">
        <Loader2 className="h-8 w-8 animate-spin text-gray-400" />
      </div>
    );
  }

  if (error || !device) {
    return (
      <div className="text-center p-8">
        <AlertTriangle className="mx-auto h-12 w-12 text-red-400 mb-4" />
        <p className="text-red-400 text-lg">{error ?? "Device not found"}</p>
        <Link
          href="/devices"
          className="mt-4 inline-flex items-center text-blue-600 hover:text-blue-800"
        >
          <ArrowLeft className="h-4 w-4 mr-2" />
          Back to Devices
        </Link>
      </div>
    );
  }

  const metadata =
    device.metadata && typeof device.metadata === "object"
      ? (device.metadata as Record<string, unknown>)
      : {};

  const metadataFlag = (keys: string[]): boolean =>
    keys.some((key) => {
      const value = metadata[key];
      if (typeof value === "string") {
        return value.toLowerCase() === "true";
      }
      if (typeof value === "boolean") {
        return value;
      }
      return false;
    });

  const metadataValue = (keys: string[]): string | undefined => {
    for (const key of keys) {
      const value = metadata[key];
      if (typeof value === "string" && value.trim() !== "") {
        return value;
      }
    }
    return undefined;
  };

  const isDeleted = metadataFlag(["_deleted", "deleted"]);
  const deletedAtRaw = metadataValue(["_deleted_at", "deleted_at"]);
  const deletedBy = metadataValue(["_deleted_by", "deleted_by"]);
  const discoverySources = ensureArray(device.discovery_sources);

  let deviceAttributes: Array<{ label: string; value: string | null }> = [
    { label: "IP Address", value: device.ip ?? null },
    { label: "MAC Address", value: device.mac ?? null },
    { label: "Device Type", value: device.device_type ?? null },
    { label: "Service Type", value: device.service_type ?? null },
    { label: "Agent", value: device.agent_id ?? null },
    { label: "Poller", value: device.poller_id ?? null },
    {
      label: "First Seen",
      value: device.first_seen
        ? formatTimestampForDisplay(device.first_seen)
        : null,
    },
    {
      label: "Last Seen",
      value: device.last_seen
        ? formatTimestampForDisplay(device.last_seen)
        : null,
    },
    { label: "OS Info", value: device.os_info ?? null },
    { label: "Version", value: device.version_info ?? null },
  ];

  if (isDeleted) {
    if (deletedBy) {
      deviceAttributes.unshift({
        label: "Deleted By",
        value: deletedBy,
      });
    }
    deviceAttributes.unshift({
      label: "Deleted At",
      value: deletedAtRaw
        ? formatTimestampForDisplay(deletedAtRaw)
        : "Marked as deleted",
    });
  }

  deviceAttributes = deviceAttributes.filter((item) => item.value);
  const isDeviceOnline = !isDeleted && !!device.is_available;

  return (
    <div className="space-y-6">
      <Link
        href="/devices"
        className="inline-flex items-center text-blue-600 hover:text-blue-800 dark:text-blue-400 dark:hover:text-blue-300"
      >
        <ArrowLeft className="h-4 w-4 mr-2" />
        Back to Devices
      </Link>

      <div className="rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 p-6">
        <div className="flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
          <div className="flex items-start gap-4">
            <div className="rounded-lg bg-blue-100 dark:bg-blue-900/30 p-3 text-blue-600 dark:text-blue-300">
              <Server className="h-8 w-8" />
            </div>
            <div>
              <h2 className="text-2xl font-bold text-gray-900 dark:text-white">
                {device.hostname || device.ip || device.device_id}
              </h2>
              <p className="text-sm text-gray-600 dark:text-gray-400">
                {device.device_id}
              </p>
              <div className="mt-3 flex flex-wrap gap-4 text-sm text-gray-500 dark:text-gray-400">
                {device.poller_id && (
                  <span className="inline-flex items-center gap-1">
                    <MapPin className="h-4 w-4" />
                    {device.poller_id}
                  </span>
                )}
                {device.last_seen && (
                  <span className="inline-flex items-center gap-1">
                    <Clock className="h-4 w-4" />
                    Last seen {formatTimestampForDisplay(device.last_seen)}
                  </span>
                )}
              </div>
            </div>
          </div>
          <div className="flex items-center gap-2">
            {isDeleted ? (
              <span className="inline-flex items-center rounded-full bg-rose-100 dark:bg-rose-900/30 px-3 py-1 text-sm font-medium text-rose-700 dark:text-rose-300">
                <AlertTriangle className="mr-2 h-4 w-4" />
                Deleted
              </span>
            ) : isDeviceOnline ? (
              <span className="inline-flex items-center rounded-full bg-emerald-100 dark:bg-emerald-900/30 px-3 py-1 text-sm font-medium text-emerald-700 dark:text-emerald-300">
                <CheckCircle className="mr-2 h-4 w-4" />
                Online
              </span>
            ) : (
              <span className="inline-flex items-center rounded-full bg-rose-100 dark:bg-rose-900/30 px-3 py-1 text-sm font-medium text-rose-700 dark:text-rose-300">
                <XCircle className="mr-2 h-4 w-4" />
                Offline
              </span>
            )}
          </div>
        </div>

        {isDeleted && (
          <div className="mt-4 rounded-lg border border-rose-200 dark:border-rose-800 bg-rose-50/70 dark:bg-rose-900/20 p-4 text-sm text-rose-700 dark:text-rose-200">
            <div className="flex items-start gap-3">
              <AlertTriangle className="h-5 w-5 mt-0.5" />
              <div>
                <p className="font-medium">Device marked as deleted</p>
                <p className="mt-1">
                  New telemetry for this device ID will re-activate it
                  automatically. Use this badge to confirm whether subsequent
                  updates have resurrected the device.
                </p>
              </div>
            </div>
          </div>
        )}

        {discoverySources.length > 0 && (
          <div className="mt-4">
            <p className="text-sm text-gray-600 dark:text-gray-400 mb-2">
              Discovery Sources
            </p>
            <div className="flex flex-wrap gap-2">
              {discoverySources.map((source) => (
                <span
                  key={source}
                  className="rounded-full bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-300 px-2 py-1 text-xs font-medium"
                >
                  {source}
                </span>
              ))}
            </div>
          </div>
        )}

        {deviceAttributes.length > 0 && (
          <div className="mt-6 grid grid-cols-1 gap-4 md:grid-cols-2">
            {deviceAttributes.map((attribute) => (
              <div
                key={attribute.label}
                className="rounded-md bg-gray-50 dark:bg-gray-900/40 px-3 py-2"
              >
                <p className="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">
                  {attribute.label}
                </p>
                <p className="text-sm font-medium text-gray-900 dark:text-gray-100">
                  {attribute.value}
                </p>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Service Registry Panel - only shows for pollers, agents, and checkers */}
      <ServiceRegistryPanel deviceId={deviceId} />

      {/* Delete Device Button */}
      <DeleteDeviceButton
        deviceId={deviceId}
        deviceName={device.hostname || device.ip}
      />

      <div className="rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 p-6">
        <div className="mb-4 flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
          <div>
            <h3 className="text-lg font-semibold text-gray-900 dark:text-white">
              Availability
            </h3>
            <p className="text-sm text-gray-500 dark:text-gray-400">
              {timeWindow.label} window • tracking transitions from device
              updates
            </p>
          </div>
          <div className="flex flex-wrap gap-2">
            {Object.entries(TIME_RANGE_CONFIG).map(([key, config]) => (
              <button
                key={key}
                type="button"
                onClick={() => setTimeRange(key)}
                className={`rounded-md border px-3 py-1 text-sm transition ${
                  timeRange === key
                    ? "border-blue-500 bg-blue-50 text-blue-600 dark:border-blue-400 dark:bg-blue-900/40 dark:text-blue-200"
                    : "border-gray-300 text-gray-600 hover:border-gray-400 dark:border-gray-700 dark:text-gray-300"
                }`}
              >
                {config.label}
              </button>
            ))}
          </div>
        </div>

        {availabilityLoading ? (
          <div className="flex items-center justify-center py-10 text-gray-500 dark:text-gray-400">
            <Loader2 className="mr-2 h-5 w-5 animate-spin" />
            Loading availability history…
          </div>
        ) : availabilityError ? (
          <div className="rounded-lg border border-dashed border-red-300 dark:border-red-700 bg-red-50/60 dark:bg-red-900/20 p-4 text-sm text-red-600 dark:text-red-300">
            {availabilityError}
          </div>
        ) : (
          <>
            <AvailabilityTimeline
              segments={availabilityInfo.segments}
              totalMs={availabilityInfo.totalMs}
              start={timeWindow.start}
              end={timeWindow.end}
            />

            <div className="mt-6 grid grid-cols-1 gap-4 md:grid-cols-3">
              <MetricCard
                title={`Uptime (${timeWindow.label})`}
                value={`${availabilityInfo.uptimePct.toFixed(1)}%`}
                subtitle={`${formatDuration(availabilityInfo.uptimeMs)} available`}
                icon={<TrendingUp className="h-6 w-6" />}
                color="green"
              />
              <MetricCard
                title="Observed Downtime"
                value={formatDuration(availabilityInfo.downtimeMs)}
                subtitle="Based on collected device update events"
                icon={<AlertTriangle className="h-6 w-6" />}
                color="red"
              />
              <MetricCard
                title="Last Status Change"
                value={
                  availabilityInfo.latestEvent
                    ? formatRelativeTime(
                        new Date(availabilityInfo.latestEvent.timestamp),
                      )
                    : "No change recorded"
                }
                subtitle={
                  availabilityInfo.latestEvent
                    ? formatTimestampForDisplay(
                        availabilityInfo.latestEvent.timestamp,
                      )
                    : undefined
                }
                icon={<Clock className="h-6 w-6" />}
                color="blue"
              />
            </div>
          </>
        )}
      </div>

      <div className="grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-4">
        <MetricCard
          title="Total Metrics"
          value={metricStats.total.toLocaleString()}
          icon={<TrendingUp className="h-6 w-6" />}
          color="blue"
        />
        <MetricCard
          title="Metric Types"
          value={metricStats.types}
          icon={<BarChart3 className="h-6 w-6" />}
          color="green"
        />
        <MetricCard
          title="Latest Sample"
          value={
            metricStats.latestTimestamp
              ? metricStats.latestTimestamp.toLocaleTimeString()
              : "N/A"
          }
          subtitle={
            metricStats.latestTimestamp
              ? metricStats.latestTimestamp.toLocaleDateString()
              : undefined
          }
          icon={<Clock className="h-6 w-6" />}
          color="purple"
        />
        <MetricCard
          title="Active Collectors"
          value={metricStats.activeCollectors}
          icon={<Activity className="h-6 w-6" />}
          color="orange"
        />
      </div>

      {(sysmonLoading || sysmonSummary) && (
        <div className="rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 p-6">
          <div className="mb-4">
            <h3 className="text-lg font-semibold text-gray-900 dark:text-white">
              System Metrics Overview
            </h3>
            <p className="text-sm text-gray-500 dark:text-gray-400">
              Latest Sysmon telemetry captured for this device
            </p>
          </div>
          {sysmonLoading ? (
            <div className="flex items-center justify-center py-8 text-gray-500 dark:text-gray-400">
              <Loader2 className="mr-2 h-5 w-5 animate-spin" />
              Loading system metrics…
            </div>
          ) : sysmonError ? (
            <div className="rounded-lg border border-dashed border-red-300 dark:border-red-700 bg-red-50/60 dark:bg-red-900/20 p-4 text-sm text-red-600 dark:text-red-300">
              {sysmonError}
            </div>
          ) : sysmonSummary ? (
            <div className="space-y-4">
              <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
                {sysmonSummary.cpu && (
                  <MetricCard
                    title="CPU Load"
                    value={`${sysmonSummary.cpu.averageUsage.toFixed(1)}%`}
                    subtitle={`Across ${sysmonSummary.cpu.coreCount} cores`}
                    icon={<Activity className="h-6 w-6" />}
                    color="orange"
                  />
                )}
                {sysmonSummary.memory && (
                  <MetricCard
                    title="Memory Usage"
                    value={`${formatBytes(sysmonSummary.memory.usedBytes)} / ${formatBytes(sysmonSummary.memory.totalBytes)}`}
                    subtitle={`${sysmonSummary.memory.percent.toFixed(1)}% used`}
                    icon={<BarChart3 className="h-6 w-6" />}
                    color="purple"
                  />
                )}
                {icmpSnapshot && (
                  <MetricCard
                    title="Latest ICMP RTT"
                    value={`${icmpSnapshot.value.toFixed(1)} ms`}
                    subtitle={formatRelativeTime(
                      new Date(icmpSnapshot.timestamp),
                    )}
                    icon={<TrendingUp className="h-6 w-6" />}
                    color="green"
                  />
                )}
              </div>
              {sysmonSummary.disks && sysmonSummary.disks.length > 0 && (
                <div className="rounded-lg border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-900/30 p-4">
                  <h4 className="text-sm font-semibold text-gray-800 dark:text-gray-200 mb-3">
                    Heaviest Disk Utilization
                  </h4>
                  <div className="space-y-3">
                    {sysmonSummary.disks.map((disk) => (
                      <div key={`${disk.mountPoint}-${disk.timestamp}`}>
                        <div className="flex items-center justify-between text-sm">
                          <span className="font-medium text-gray-700 dark:text-gray-300">
                            {disk.mountPoint}
                          </span>
                          <span className="text-gray-600 dark:text-gray-400">
                            {disk.percent.toFixed(1)}%
                          </span>
                        </div>
                        <div className="mt-1 h-2 w-full rounded-full bg-gray-200 dark:bg-gray-800">
                          <div
                            className="h-2 rounded-full bg-blue-500"
                            style={{ width: `${Math.min(disk.percent, 100)}%` }}
                          />
                        </div>
                        <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
                          {formatBytes(disk.usedBytes)} of{" "}
                          {formatBytes(disk.totalBytes)}
                        </p>
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </div>
          ) : (
            <div className="rounded-lg border border-dashed border-gray-300 dark:border-gray-700 p-4 text-sm text-gray-500 dark:text-gray-400">
              No Sysmon data captured for this device.
            </div>
          )}
        </div>
      )}

      <div className="rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 p-6">
        <div className="mb-4 flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
          <div>
            <h3 className="text-lg font-semibold text-gray-900 dark:text-white">
              Device Metrics Timeline
            </h3>
            <p className="text-sm text-gray-500 dark:text-gray-400">
              Visualize collected timeseries metrics for this device
            </p>
          </div>
          <div className="flex items-center gap-3">
            <label className="text-sm font-medium text-gray-700 dark:text-gray-300">
              Metric Type
            </label>
            <select
              value={selectedMetricType}
              onChange={(event) => setSelectedMetricType(event.target.value)}
              className="rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white focus:border-blue-500 focus:outline-none focus:ring focus:ring-blue-500/30"
            >
              <option value="all">All Types</option>
              {metricTypes.map((type) => (
                <option key={type} value={type}>
                  {type.toUpperCase()}
                </option>
              ))}
            </select>
          </div>
        </div>

        {metricsLoading ? (
          <div className="flex items-center justify-center py-10 text-gray-500 dark:text-gray-400">
            <Loader2 className="mr-2 h-5 w-5 animate-spin" />
            Loading metrics…
          </div>
        ) : metrics.length === 0 ? (
          <div className="rounded-lg border border-dashed border-gray-300 dark:border-gray-700 p-6 text-center text-sm text-gray-500 dark:text-gray-400">
            No metrics recorded for this period.
          </div>
        ) : (
          <div className="h-96">
            <ResponsiveContainer width="100%" height="100%">
              <LineChart data={chartData}>
                <CartesianGrid strokeDasharray="3 3" className="opacity-30" />
                <XAxis dataKey="time" className="text-xs" />
                <YAxis className="text-xs" />
                <Tooltip
                  contentStyle={{
                    backgroundColor: "rgba(17, 24, 39, 0.95)",
                    border: "none",
                    borderRadius: "8px",
                    color: "white",
                  }}
                />
                <Legend />
                {chartSeriesKeys.map((series, index) => (
                  <Line
                    key={series}
                    type="monotone"
                    dataKey={series}
                    stroke={`hsl(${(index * 60) % 360}, 70%, 50%)`}
                    strokeWidth={2}
                    dot={false}
                  />
                ))}
              </LineChart>
            </ResponsiveContainer>
          </div>
        )}
      </div>

      {(aliasLoading || aliasHistory || aliasError) && (
        <div className="rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 p-6">
          <div className="mb-4">
            <h3 className="text-lg font-semibold text-gray-900 dark:text-white">
              Collector & Alias History
            </h3>
            <p className="text-sm text-gray-500 dark:text-gray-400">
              Tracks the most recent service and IP associations for this device
            </p>
          </div>
          {aliasLoading ? (
            <div className="flex items-center justify-center py-6 text-gray-500 dark:text-gray-400">
              <Loader2 className="mr-2 h-5 w-5 animate-spin" />
              Loading alias history…
            </div>
          ) : aliasError ? (
            <div className="rounded-md border border-dashed border-red-300 dark:border-red-700 bg-red-50/60 dark:bg-red-900/20 p-3 text-sm text-red-600 dark:text-red-300">
              {aliasError}
            </div>
          ) : aliasHistory ? (
            <div className="space-y-4">
              <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
                <div className="rounded-md bg-gray-50 dark:bg-gray-900/40 px-3 py-2">
                  <p className="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">
                    Current Service
                  </p>
                  <p className="text-sm font-medium text-gray-900 dark:text-gray-100 break-words">
                    {aliasHistory.current_service_id ?? "Unknown"}
                  </p>
                  {aliasHistory.last_seen_at && (
                    <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
                      Last seen{" "}
                      {formatRelativeTime(new Date(aliasHistory.last_seen_at))}
                    </p>
                  )}
                </div>
                <div className="rounded-md bg-gray-50 dark:bg-gray-900/40 px-3 py-2">
                  <p className="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">
                    Current Host IP
                  </p>
                  <p className="text-sm font-medium text-gray-900 dark:text-gray-100">
                    {aliasHistory.current_ip ?? "Unknown"}
                  </p>
                  {aliasHistory.collector_ip && (
                    <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
                      Collector {aliasHistory.collector_ip}
                    </p>
                  )}
                </div>
                <div className="rounded-md bg-gray-50 dark:bg-gray-900/40 px-3 py-2">
                  <p className="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">
                    Last Update
                  </p>
                  <p className="text-sm font-medium text-gray-900 dark:text-gray-100">
                    {aliasHistory.last_seen_at
                      ? formatTimestampForDisplay(aliasHistory.last_seen_at)
                      : "N/A"}
                  </p>
                </div>
              </div>

              {aliasHistory.services && aliasHistory.services.length > 0 && (
                <div>
                  <p className="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400 mb-2">
                    Service Associations
                  </p>
                  <div className="space-y-2">
                    {aliasHistory.services.map((svc) => (
                      <div
                        key={`${svc.id ?? "unknown"}-${svc.last_seen_at ?? "unknown"}`}
                        className="flex items-center justify-between rounded-md bg-gray-50 dark:bg-gray-900/40 px-3 py-2"
                      >
                        <span className="text-sm font-medium text-gray-900 dark:text-gray-100 break-words">
                          {svc.id ?? "Unknown service"}
                        </span>
                        <span className="text-xs text-gray-500 dark:text-gray-400 ml-4 whitespace-nowrap">
                          {svc.last_seen_at
                            ? formatRelativeTime(new Date(svc.last_seen_at))
                            : "N/A"}
                        </span>
                      </div>
                    ))}
                  </div>
                </div>
              )}

              {aliasHistory.ips && aliasHistory.ips.length > 0 && (
                <div>
                  <p className="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400 mb-2">
                    Recent IP Aliases
                  </p>
                  <div className="space-y-2">
                    {aliasHistory.ips.map((ip) => (
                      <div
                        key={`${ip.ip ?? "unknown"}-${ip.last_seen_at ?? "unknown"}`}
                        className="flex items-center justify-between rounded-md bg-gray-50 dark:bg-gray-900/40 px-3 py-2"
                      >
                        <span className="text-sm font-medium text-gray-900 dark:text-gray-100 break-words">
                          {ip.ip ?? "Unknown IP"}
                        </span>
                        <span className="text-xs text-gray-500 dark:text-gray-400 ml-4 whitespace-nowrap">
                          {ip.last_seen_at
                            ? formatRelativeTime(new Date(ip.last_seen_at))
                            : "N/A"}
                        </span>
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </div>
          ) : (
            <p className="text-sm text-gray-500 dark:text-gray-400">
              Alias history not available for this device.
            </p>
          )}
        </div>
      )}

      {metadataEntries.length > 0 && (
        <div className="rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 p-6">
          <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">
            Device Metadata
          </h3>
          <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
            {metadataEntries.map(([key, value]) => (
              <div
                key={key}
                className="rounded-md bg-gray-50 dark:bg-gray-900/40 px-3 py-2"
              >
                <p className="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">
                  {key}
                </p>
                <p className="text-sm font-medium text-gray-900 dark:text-gray-100 break-words">
                  {value}
                </p>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
};

export default DeviceDetail;
