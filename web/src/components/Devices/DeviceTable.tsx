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

import React, { useState, useEffect, useMemo, useCallback } from "react";
import {
  ArrowUp,
  ArrowDown,
  Server,
  Box,
  Cpu,
  Monitor,
} from "lucide-react";
import Link from "next/link";
import { Device } from "@/types/devices";
import SysmonStatusIndicator from "./SysmonStatusIndicator";
import SNMPStatusIndicator from "./SNMPStatusIndicator";
import ICMPSparkline from "./ICMPSparkline";
import { formatTimestampForDisplay } from "@/utils/traceTimestamp";
import { useAuth } from "@/components/AuthProvider";

type SortableKeys =
  | "ip"
  | "hostname"
  | "last_seen"
  | "first_seen"
  | "poller_id";

interface DeviceTableProps {
  devices: Device[];
  onSort?: (key: SortableKeys) => void;
  sortBy?: SortableKeys;
  sortOrder?: "asc" | "desc";
  collectorServiceMeta?: Map<string, string>;
  hideCollectorServices?: boolean;
}

type CollectorFlags = {
  icmp: boolean;
  sysmon: boolean;
  snmp: boolean;
};

type CollectorInfo = {
  serviceId: string;
  collectorIp: string;
  aliasIp: string;
  hasCollector: boolean;
  supports: CollectorFlags;
  capabilities: string[];
  agentId?: string;
  pollerId?: string;
  lastSeen?: string;
};

type IcmpState = {
  shouldRender: boolean;
  hasMetrics: boolean | undefined;
  hasCollector: boolean;
  supportsICMP: boolean;
};

const DeviceIcon = ({
  type,
  className,
}: {
  type: string;
  className?: string;
}) => {
  const cls = className || "h-4 w-4";
  switch (type) {
    case "poller":
      return <Server className={`text-purple-600 ${cls}`} />;
    case "agent":
      return <Box className={`text-blue-600 ${cls}`} />;
    case "service":
    case "checker":
      return <Cpu className={`text-emerald-600 ${cls}`} />;
    default:
      return <Monitor className={`text-gray-500 ${cls}`} />;
  }
};

const normalizeString = (value: unknown): string => {
  if (typeof value === "string") {
    return value.trim();
  }
  return "";
};

const metaString = (
  metadata: Record<string, unknown> | undefined,
  key: string,
): string => {
  if (!metadata) return "";
  const raw = metadata[key];
  return typeof raw === "string" ? raw.trim() : "";
};

const isPollerDeviceId = (deviceId: string): boolean =>
  deviceId.startsWith("serviceradar:poller:");

const deviceIp = (device: Device): string => {
  const metadata = (device.metadata as Record<string, unknown>) || {};
  const candidates = [
    device.ip,
    metaString(metadata, "host_ip"),
    metaString(metadata, "collector_ip"),
    metaString(metadata, "alias_ip"),
    metaString(metadata, "current_ip"),
    metaString(metadata, "checker_host_ip"),
  ];
  const ip = candidates.find((val) => val && val.trim().length > 0);
  return ip ? ip.trim() : "";
};

const looksLikeCollectorHost = (
  device: Device,
  normalizedIp: string,
): boolean => {
  const name =
    (device.hostname || metaString(device.metadata, "canonical_hostname") || "")
      .toLowerCase();
  if (name === "agent" || name === "poller") {
    return true;
  }
  if (name.startsWith("docker-agent") || name.startsWith("docker-poller")) {
    return true;
  }
  return normalizedIp.startsWith("172.18.");
};

const METRICS_STATUS_REFRESH_INTERVAL_MS = 30_000;

const normalizeDiscoverySources = (raw: unknown): string[] => {
  if (!Array.isArray(raw)) {
    return [];
  }

  return raw
    .map((entry) => {
      if (typeof entry === "string") {
        return entry.trim();
      }
      if (entry && typeof entry === "object") {
        const sourceField = (entry as Record<string, unknown>).source;
        if (typeof sourceField === "string" && sourceField.trim()) {
          return sourceField.trim();
        }
        try {
          return JSON.stringify(entry);
        } catch {
          return null;
        }
      }
      return null;
    })
    .filter((value): value is string => Boolean(value && value.length > 0))
    .sort((a, b) => a.localeCompare(b));
};

const DeviceTable: React.FC<DeviceTableProps> = ({
  devices,
  collectorServiceMeta,
  hideCollectorServices = true,
  onSort,
  sortBy = "last_seen",
  sortOrder = "desc",
}) => {
  const { token } = useAuth();
  const [sysmonStatuses, setSysmonStatuses] = useState<
    Record<string, { hasMetrics: boolean }>
  >({});
  const [sysmonStatusesLoading, setSysmonStatusesLoading] = useState(true);
  const [snmpStatuses, setSnmpStatuses] = useState<
    Record<string, { hasMetrics: boolean }>
  >({});
  const [snmpStatusesLoading, setSnmpStatusesLoading] = useState(true);
  const filteredDevices = useMemo(() => {
    return devices.filter((device) => {
      if (hideCollectorServices && collectorServiceMeta?.has(device.device_id)) {
        return false;
      }
      const normalizedIp = deviceIp(device);
      const placeholderCollectorOwned =
        !!metaString(device.metadata, "checker_service") &&
        looksLikeCollectorHost(device, normalizedIp) &&
        Boolean(
          metaString(device.metadata, "collector_agent_id") ||
            metaString(device.metadata, "collector_poller_id"),
        );
      return !(hideCollectorServices && placeholderCollectorOwned);
    });
  }, [collectorServiceMeta, devices, hideCollectorServices]);

  const extractCollectorInfo = useCallback((device: Device): CollectorInfo => {
    const aliasHistory = device.alias_history;
    const capabilityHints = device.collector_capabilities;
    const metricsSummary = (device.metrics_summary ?? {}) as Record<string, boolean>;

    const capabilitySet = new Set<string>();
    if (Array.isArray(capabilityHints?.capabilities)) {
      for (const cap of capabilityHints.capabilities) {
        if (typeof cap === "string" && cap.trim()) {
          capabilitySet.add(cap.trim().toLowerCase());
        }
      }
    }

    const supports: CollectorFlags = {
      icmp: capabilityHints?.supports_icmp ?? capabilitySet.has("icmp"),
      sysmon: capabilityHints?.supports_sysmon ?? capabilitySet.has("sysmon"),
      snmp: capabilityHints?.supports_snmp ?? capabilitySet.has("snmp"),
    };

    let hasCollector = capabilityHints?.has_collector ?? capabilitySet.size > 0;

    if (!hasCollector && (supports.icmp || supports.sysmon || supports.snmp)) {
      hasCollector = true;
    }

    if (metricsSummary.icmp === true) {
      supports.icmp = true;
      hasCollector = true;
    }
    if (metricsSummary.sysmon === true) {
      supports.sysmon = true;
      hasCollector = true;
    }
    if (metricsSummary.snmp === true) {
      supports.snmp = true;
      hasCollector = true;
    }

    const serviceId = (
      capabilityHints?.service_name ?? aliasHistory?.current_service_id ?? ""
    ).trim();
    const collectorIp = (aliasHistory?.collector_ip ?? "").trim();
    const aliasIp = (aliasHistory?.current_ip ?? "").trim();

    const info: CollectorInfo = {
      serviceId,
      collectorIp,
      aliasIp,
      hasCollector,
      supports,
      capabilities: Array.from(capabilitySet),
      agentId: capabilityHints?.agent_id,
      pollerId: capabilityHints?.poller_id,
      lastSeen: capabilityHints?.last_seen,
    };

    if (
      !info.hasCollector &&
      Object.values(metricsSummary).some((value) => value === true)
    ) {
      info.hasCollector = true;
    }

    return info;
  }, []);

  const collectorInfoByDevice = useMemo(() => {
    const info = new Map<string, CollectorInfo>();
    filteredDevices.forEach((device) => {
      info.set(device.device_id, extractCollectorInfo(device));
    });
    return info;
  }, [filteredDevices, extractCollectorInfo]);

  const icmpCollectorInfo = useMemo(() => {
    const collectors = new Map<string, IcmpState>();

    filteredDevices.forEach((device) => {
      const info = collectorInfoByDevice.get(device.device_id);
      if (!info) {
        return;
      }

      const summary = device.metrics_summary as
        | Record<string, boolean>
        | undefined;
      const supportsICMP = info.supports.icmp || summary?.icmp === true;

      if (!supportsICMP) {
        return;
      }

      const hasMetrics = summary?.icmp === true ? true : undefined;

      collectors.set(device.device_id, {
        shouldRender: true,
        hasMetrics,
        hasCollector: Boolean(info.hasCollector),
        supportsICMP,
      });
    });

    return collectors;
  }, [collectorInfoByDevice, filteredDevices]);

  const sysmonEligibleDeviceIds = useMemo(() => {
    return filteredDevices
      .filter(
        (device) =>
          collectorInfoByDevice.get(device.device_id)?.supports.sysmon,
      )
      .map((device) => device.device_id);
  }, [collectorInfoByDevice, filteredDevices]);

  const snmpEligibleDeviceIds = useMemo(() => {
    return filteredDevices
      .filter(
        (device) => collectorInfoByDevice.get(device.device_id)?.supports.snmp,
      )
      .map((device) => device.device_id);
  }, [collectorInfoByDevice, filteredDevices]);

  const sysmonDeviceIdsString = useMemo(() => {
    return [...sysmonEligibleDeviceIds].sort().join(",");
  }, [sysmonEligibleDeviceIds]);

  const snmpDeviceIdsString = useMemo(() => {
    return [...snmpEligibleDeviceIds].sort().join(",");
  }, [snmpEligibleDeviceIds]);

  useEffect(() => {
    if (!filteredDevices || filteredDevices.length === 0) return;

    let cancelled = false;
    const safeSetState = <T,>(
      setter: React.Dispatch<React.SetStateAction<T>>,
      value: T,
    ) => {
      if (!cancelled) {
        setter(value);
      }
    };

    const authHeaders: Record<string, string> = token
      ? { Authorization: `Bearer ${token}` }
      : {};

    const fetchSysmonStatuses = async (showSpinner: boolean) => {
      if (showSpinner) {
        safeSetState<boolean>(setSysmonStatusesLoading, true);
      }
      try {
        if (sysmonEligibleDeviceIds.length === 0) {
          safeSetState<Record<string, { hasMetrics: boolean }>>(
            setSysmonStatuses,
            {},
          );
          safeSetState<boolean>(setSysmonStatusesLoading, false);
          return;
        }

        console.log(
          `DeviceTable: Fetching sysmon status for ${sysmonEligibleDeviceIds.length} devices`,
        );
        const response = await fetch("/api/devices/sysmon/status", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            ...authHeaders,
          },
          credentials: "include",
          body: JSON.stringify({ deviceIds: sysmonEligibleDeviceIds }),
        });

        if (response.ok) {
          const data = await response.json();
          if (!cancelled) {
            setSysmonStatuses(data.statuses || {});
          }
        } else {
          console.error(
            "Failed to fetch bulk sysmon statuses:",
            response.status,
          );
        }
      } catch (error) {
        console.error("Error fetching bulk sysmon statuses:", error);
      } finally {
        if (showSpinner) {
          safeSetState<boolean>(setSysmonStatusesLoading, false);
        }
      }
    };

    const fetchSnmpStatuses = async (showSpinner: boolean) => {
      if (showSpinner) {
        safeSetState<boolean>(setSnmpStatusesLoading, true);
      }
      try {
        if (snmpEligibleDeviceIds.length === 0) {
          safeSetState<Record<string, { hasMetrics: boolean }>>(
            setSnmpStatuses,
            {},
          );
          safeSetState<boolean>(setSnmpStatusesLoading, false);
          return;
        }

        console.log(
          `DeviceTable: Fetching SNMP status for ${snmpEligibleDeviceIds.length} devices`,
        );
        const response = await fetch("/api/devices/snmp/status", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            ...authHeaders,
          },
          credentials: "include",
          body: JSON.stringify({ deviceIds: snmpEligibleDeviceIds }),
        });

        if (response.ok) {
          const data = await response.json();
          if (!cancelled) {
            setSnmpStatuses(data.statuses || {});
          }
        } else {
          console.error("Failed to fetch bulk SNMP statuses:", response.status);
        }
      } catch (error) {
        console.error("Error fetching bulk SNMP statuses:", error);
      } finally {
        if (showSpinner) {
          safeSetState<boolean>(setSnmpStatusesLoading, false);
        }
      }
    };

    fetchSysmonStatuses(true);
    fetchSnmpStatuses(true);

    const sysmonInterval =
      sysmonEligibleDeviceIds.length > 0
        ? setInterval(
            () => fetchSysmonStatuses(false),
            METRICS_STATUS_REFRESH_INTERVAL_MS,
          )
        : null;

    const snmpInterval =
      snmpEligibleDeviceIds.length > 0
        ? setInterval(
            () => fetchSnmpStatuses(false),
            METRICS_STATUS_REFRESH_INTERVAL_MS,
          )
        : null;

    return () => {
      cancelled = true;
      if (sysmonInterval) {
        clearInterval(sysmonInterval);
      }
      if (snmpInterval) {
        clearInterval(snmpInterval);
      }
    };
  }, [
    filteredDevices,
    sysmonDeviceIdsString,
    snmpDeviceIdsString,
    sysmonEligibleDeviceIds,
    snmpEligibleDeviceIds,
    token,
  ]);

  const getSourceColor = (source: string) => {
    if (typeof source !== "string") {
      return "bg-gray-100 text-gray-800 dark:bg-gray-600/50 dark:text-gray-200";
    }
    const lowerSource = source.toLowerCase();
    if (lowerSource.includes("netbox"))
      return "bg-blue-100 text-blue-800 dark:bg-blue-600/50 dark:text-blue-200";
    if (lowerSource.includes("sweep"))
      return "bg-green-100 text-green-800 dark:bg-green-600/50 dark:text-green-200";
    if (lowerSource.includes("mapper"))
      return "bg-green-100 text-green-800 dark:bg-green-600/50 dark:text-green-200";
    if (lowerSource.includes("unifi"))
      return "bg-sky-100 text-sky-800 dark:bg-sky-600/50 dark:text-sky-200";
    return "bg-gray-100 text-gray-800 dark:bg-gray-600/50 dark:text-gray-200";
  };

  const formatDate = (dateString: string) =>
    formatTimestampForDisplay(dateString);

  /**
   * Determines the display status of a device by checking metadata first.
   * This makes the UI more robust against backend race conditions.
   * @param device The device object
   * @returns {boolean} True if the device should be displayed as online, false otherwise.
   */
  const getDeviceDisplayStatus = (device: Device): boolean => {
    // Ping/sweep results are the most reliable indicator of current reachability.
    // If the metadata explicitly says the device is unavailable via ICMP, trust that.
    if (device.metadata?.icmp_available === "false") {
      return false;
    }

    // Otherwise, fall back to the general `is_available` flag.
    return device.is_available;
  };

  const TableHeader = ({
    aKey,
    label,
  }: {
    aKey: SortableKeys;
    label: string;
  }) => (
    <th
      scope="col"
      className={`px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider ${onSort ? "cursor-pointer" : ""}`}
      onClick={() => onSort && onSort(aKey)}
    >
      <div className="flex items-center">
        {label}
        {onSort &&
          sortBy === aKey &&
          (sortOrder === "asc" ? (
            <ArrowUp className="ml-1 h-3 w-3" />
          ) : (
            <ArrowDown className="ml-1 h-3 w-3" />
          ))}
      </div>
    </th>
  );

  if (!filteredDevices || filteredDevices.length === 0) {
    return (
      <div className="text-center p-8 text-gray-600 dark:text-gray-400">
        No devices found.
      </div>
    );
  }

  return (
    <div className="overflow-x-auto">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-800">
        <thead className="bg-gray-50 dark:bg-gray-900/50">
          <tr>
            <TableHeader aKey="hostname" label="Device" />
            <TableHeader aKey="ip" label="IP Address" />
            <th
              scope="col"
              className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider"
            >
              Health & Metrics
            </th>
            <TableHeader aKey="last_seen" label="Last Seen" />
          </tr>
        </thead>
        <tbody className="bg-white dark:bg-gray-800/60 divide-y divide-gray-200 dark:divide-gray-800">
          {filteredDevices.map((device) => {
            const metadata = device.metadata || {};
            const serviceTypeLabel =
              collectorServiceMeta?.get(device.device_id) ?? null;
            const isCollectorService = Boolean(serviceTypeLabel);
            const sysmonServiceHint =
              typeof metadata === "object" &&
              metadata !== null &&
              typeof metadata.checker_service === "string" &&
              metadata.checker_service.toLowerCase().includes("sysmon");
            const isPoller = isPollerDeviceId(device.device_id);
            const collectorInfo =
              collectorInfoByDevice.get(device.device_id) ??
              extractCollectorInfo(device);
            const collectorBadges: React.ReactElement[] = [];

            if (collectorInfo.serviceId) {
              collectorBadges.push(
                <span
                  key={`${device.device_id}-collector-${collectorInfo.serviceId}`}
                  className="inline-flex items-center rounded-full bg-purple-100 px-2 py-0.5 text-xs font-medium text-purple-800 dark:bg-purple-700/40 dark:text-purple-200"
                >
                  Collector&nbsp;
                  <span className="font-semibold">
                    {collectorInfo.serviceId}
                  </span>
                </span>,
              );
            }

            if (collectorInfo.collectorIp) {
              collectorBadges.push(
                <span
                  key={`${device.device_id}-collector-ip-${collectorInfo.collectorIp}`}
                  className="inline-flex items-center rounded-full bg-indigo-100 px-2 py-0.5 text-xs font-medium text-indigo-800 dark:bg-indigo-700/40 dark:text-indigo-200"
                >
                  Collector IP&nbsp;
                  <span className="font-mono font-semibold">
                    {collectorInfo.collectorIp}
                  </span>
                </span>,
              );
            }

            if (collectorInfo.aliasIp && collectorInfo.aliasIp !== device.ip) {
              collectorBadges.push(
                <span
                  key={`${device.device_id}-alias-ip-${collectorInfo.aliasIp}`}
                  className="inline-flex items-center rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-700/40 dark:text-amber-200"
                >
                  Alias IP&nbsp;
                  <span className="font-mono font-semibold">
                    {collectorInfo.aliasIp}
                  </span>
                </span>,
              );
            }
            const icmpInfo = icmpCollectorInfo.get(device.device_id);
            const sysmonSupported =
              collectorInfo.supports.sysmon || sysmonServiceHint;
            const sysmonHasMetrics =
              !sysmonSupported
                ? false
                : sysmonStatusesLoading
                  ? undefined
                  : sysmonStatuses[device.device_id]?.hasMetrics ?? false;
            const snmpSupported = collectorInfo.supports.snmp;
            const snmpHasMetrics =
              !snmpSupported
                ? false
                : snmpStatusesLoading
                  ? undefined
                  : snmpStatuses[device.device_id]?.hasMetrics ?? false;
            const deviceOnline = getDeviceDisplayStatus(device);
            const sources = normalizeDiscoverySources(
              device.discovery_sources,
            );
            const deviceHref = `/devices/${encodeURIComponent(device.device_id)}`;

            return (
              <tr
                key={device.device_id}
                className="group hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors"
              >
                <td className="px-6 py-4">
                  <div className="flex items-start gap-3">
                    <div
                      className={`p-2 rounded-lg ${
                        deviceOnline
                          ? "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-300"
                          : "bg-rose-100 text-rose-700 dark:bg-rose-900/30 dark:text-rose-300"
                      }`}
                    >
                      <DeviceIcon
                        type={
                          isPoller
                            ? "poller"
                            : isCollectorService
                              ? "service"
                              : "device"
                        }
                      />
                    </div>
                    <div className="min-w-0">
                      <Link
                        href={deviceHref}
                        className="font-medium text-gray-900 dark:text-gray-100 hover:text-blue-600 dark:hover:text-blue-400"
                      >
                        {device.hostname || device.device_id}
                      </Link>
                      <div className="mt-0.5 flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
                        <span className="font-mono">
                          {device.device_type || device.service_type || "device"}
                        </span>
                        {device.poller_id && !isPoller && (
                          <span className="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-gray-100 text-gray-700 dark:bg-gray-800/70 dark:text-gray-200">
                            Poller {device.poller_id}
                          </span>
                        )}
                      </div>
                      {(collectorBadges.length > 0 ||
                        isCollectorService ||
                        sources.length > 0) && (
                        <div className="mt-1 flex flex-wrap gap-1">
                          {collectorBadges}
                          {isCollectorService && (
                            <span className="inline-flex items-center rounded-full bg-emerald-100 px-2 py-0.5 text-[11px] font-semibold text-emerald-800 dark:bg-emerald-800/40 dark:text-emerald-100">
                              Collector service
                              {serviceTypeLabel ? ` · ${serviceTypeLabel}` : ""}
                            </span>
                          )}
                          {sources.map((source) => (
                            <span
                              key={source}
                              className={`px-2 inline-flex text-[11px] leading-5 font-semibold rounded-full ${getSourceColor(source)}`}
                            >
                              {source}
                            </span>
                          ))}
                        </div>
                      )}
                    </div>
                  </div>
                </td>
                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500 dark:text-gray-400 font-mono">
                  {deviceIp(device) || "—"}
                </td>
                <td className="px-6 py-4">
                  <div className="flex flex-wrap items-center gap-3">
                    <div
                      className={`flex items-center gap-2 text-xs font-semibold ${
                        deviceOnline
                          ? "text-emerald-600 dark:text-emerald-300"
                          : "text-rose-600 dark:text-rose-300"
                      }`}
                    >
                      <span
                        className={`h-2.5 w-2.5 rounded-full ${
                          deviceOnline ? "bg-emerald-500" : "bg-rose-500"
                        }`}
                      />
                      {deviceOnline ? "Online" : "Offline"}
                    </div>
                    {icmpInfo?.shouldRender && (
                      <ICMPSparkline
                        deviceId={device.device_id}
                        deviceIp={device.ip}
                        compact={true}
                        hasMetrics={icmpInfo.hasMetrics}
                        hasCollector={icmpInfo.hasCollector}
                        supportsICMP={icmpInfo.supportsICMP}
                      />
                    )}
                    {sysmonSupported && (
                      <SysmonStatusIndicator
                        deviceId={device.device_id}
                        compact={true}
                        hasMetrics={sysmonHasMetrics}
                        serviceHint={sysmonServiceHint}
                      />
                    )}
                    {snmpSupported && (
                      <SNMPStatusIndicator
                        deviceId={device.device_id}
                        compact={true}
                        hasMetrics={snmpHasMetrics}
                        hasSnmpSource={
                          Array.isArray(device.discovery_sources) &&
                          (device.discovery_sources.includes("snmp") ||
                            device.discovery_sources.includes("mapper"))
                        }
                      />
                    )}
                  </div>
                </td>
                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300">
                  {formatDate(device.last_seen)}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
};

export default DeviceTable;
