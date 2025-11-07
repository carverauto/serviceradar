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

import React, {
  useState,
  Fragment,
  useEffect,
  useMemo,
  useCallback,
} from "react";
import {
  CheckCircle,
  XCircle,
  ChevronDown,
  ChevronRight,
  ArrowUp,
  ArrowDown,
} from "lucide-react";
import Link from "next/link";
import ReactJson from "@/components/Common/DynamicReactJson";
import { Device, CapabilitySnapshot } from "@/types/devices";
import SysmonStatusIndicator from "./SysmonStatusIndicator";
import SNMPStatusIndicator from "./SNMPStatusIndicator";
import ICMPSparkline from "./ICMPSparkline";
import DeviceTypeIndicator from "./DeviceTypeIndicator";
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

const CAPABILITY_STATE_CLASS_MAP: Record<string, string> = {
  ok: "bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-200",
  healthy: "bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-200",
  failed: "bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-200",
  error: "bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-200",
  degraded: "bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-200",
  warning: "bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-200",
  unknown: "bg-gray-200 text-gray-800 dark:bg-gray-700/60 dark:text-gray-200",
};

const CAPABILITY_STATE_DISABLED_CLASS =
  "bg-gray-300 text-gray-700 dark:bg-gray-600/60 dark:text-gray-200";

const formatCapabilityTimestamp = (timestamp?: string): string =>
  timestamp ? formatTimestampForDisplay(timestamp, undefined, undefined, "—") : "—";

const getCapabilityStateBadge = (snapshot: CapabilitySnapshot) => {
  if (!snapshot.enabled) {
    return {
      label: "disabled",
      classes: CAPABILITY_STATE_DISABLED_CLASS,
    };
  }

  const normalized = (snapshot.state ?? "unknown").toLowerCase();
  const classes =
    CAPABILITY_STATE_CLASS_MAP[normalized] ?? CAPABILITY_STATE_CLASS_MAP.unknown;

  return {
    label: normalized || "unknown",
    classes,
  };
};

const describeService = (snapshot: CapabilitySnapshot): string => {
  const serviceId = snapshot.service_id?.trim();
  const serviceType = snapshot.service_type?.trim();
  if (serviceId && serviceType) {
    return `${serviceType} · ${serviceId}`;
  }
  if (serviceId) {
    return serviceId;
  }
  if (serviceType) {
    return serviceType;
  }
  return "—";
};

const summarizeMetadata = (metadata?: Record<string, unknown>): string => {
  if (!metadata) {
    return "—";
  }
  const entries = Object.entries(metadata);
  if (entries.length === 0) {
    return "—";
  }
  const json = JSON.stringify(metadata);
  return json.length > 120 ? `${json.slice(0, 117)}…` : json;
};

const METRICS_STATUS_REFRESH_INTERVAL_MS = 30_000;

const DeviceTable: React.FC<DeviceTableProps> = ({
  devices,
  onSort,
  sortBy = "last_seen",
  sortOrder = "desc",
}) => {
  const { token } = useAuth();
  const [expandedRow, setExpandedRow] = useState<string | null>(null);
  const [sysmonStatuses, setSysmonStatuses] = useState<
    Record<string, { hasMetrics: boolean }>
  >({});
  const [sysmonStatusesLoading, setSysmonStatusesLoading] = useState(true);
  const [snmpStatuses, setSnmpStatuses] = useState<
    Record<string, { hasMetrics: boolean }>
  >({});
  const [snmpStatusesLoading, setSnmpStatusesLoading] = useState(true);

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
    devices.forEach((device) => {
      info.set(device.device_id, extractCollectorInfo(device));
    });
    return info;
  }, [devices, extractCollectorInfo]);

  const icmpCollectorInfo = useMemo(() => {
    const collectors = new Map<
      string,
      {
        shouldRender: boolean;
        hasMetrics: boolean | undefined;
      }
    >();

    devices.forEach((device) => {
      const info = collectorInfoByDevice.get(device.device_id);
      if (!info) {
        return;
      }

      if (!info.supports.icmp || !info.hasCollector) {
        return;
      }

      const summary = device.metrics_summary as
        | Record<string, boolean>
        | undefined;

      const hasSummaryMetrics = summary?.icmp === true;
      const hasExplicitCollector =
        info.capabilities.length > 0 ||
        Boolean(info.serviceId || info.collectorIp || info.aliasIp);

      if (hasExplicitCollector || hasSummaryMetrics) {
        collectors.set(device.device_id, {
          shouldRender: true,
          hasMetrics: hasSummaryMetrics ? true : undefined,
        });
      }
    });

    return collectors;
  }, [devices, collectorInfoByDevice]);

  const sysmonEligibleDeviceIds = useMemo(() => {
    return devices
      .filter(
        (device) =>
          collectorInfoByDevice.get(device.device_id)?.supports.sysmon,
      )
      .map((device) => device.device_id);
  }, [devices, collectorInfoByDevice]);

  const snmpEligibleDeviceIds = useMemo(() => {
    return devices
      .filter(
        (device) => collectorInfoByDevice.get(device.device_id)?.supports.snmp,
      )
      .map((device) => device.device_id);
  }, [devices, collectorInfoByDevice]);

  const sysmonDeviceIdsString = useMemo(() => {
    return [...sysmonEligibleDeviceIds].sort().join(",");
  }, [sysmonEligibleDeviceIds]);

  const snmpDeviceIdsString = useMemo(() => {
    return [...snmpEligibleDeviceIds].sort().join(",");
  }, [snmpEligibleDeviceIds]);

  // Create a stable reference for device IDs
  const deviceIdsString = useMemo(() => {
    return devices
      .map((device) => device.device_id)
      .sort()
      .join(",");
  }, [devices]);

  useEffect(() => {
    if (!devices || devices.length === 0) return;

    const deviceIds = devices.map((device) => device.device_id);
    console.log(
      `DeviceTable useEffect triggered with ${devices.length} devices: ${deviceIds.slice(0, 3).join(", ")}...`,
    );

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
    devices,
    deviceIdsString,
    sysmonDeviceIdsString,
    snmpDeviceIdsString,
    sysmonEligibleDeviceIds,
    snmpEligibleDeviceIds,
    token,
  ]);

  const getSourceColor = (source: string) => {
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

  if (!devices || devices.length === 0) {
    return (
      <div className="text-center p-8 text-gray-600 dark:text-gray-400">
        No devices found.
      </div>
    );
  }

  return (
    <div className="overflow-x-auto">
      <table className="min-w-full divide-y divide-gray-700">
        <thead className="bg-gray-100 dark:bg-gray-800/50">
          <tr>
            <th scope="col" className="w-12"></th>
            <th
              scope="col"
              className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider"
            >
              Status
            </th>
            <TableHeader aKey="ip" label="Device" />
            <th
              scope="col"
              className="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider"
            >
              Sources
            </th>
            <TableHeader aKey="poller_id" label="Poller" />
            <TableHeader aKey="last_seen" label="Last Seen" />
          </tr>
        </thead>
        <tbody className="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700">
          {devices.map((device) => {
            const metadata = device.metadata || {};
            const sysmonServiceHint =
              typeof metadata === "object" &&
              metadata !== null &&
              typeof metadata.checker_service === "string" &&
              metadata.checker_service.toLowerCase().includes("sysmon");

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

            return (
              <Fragment key={device.device_id}>
                <tr className="hover:bg-gray-700/30">
                  <td className="pl-4">
                    <button
                      onClick={() =>
                        setExpandedRow(
                          expandedRow === device.device_id
                            ? null
                            : device.device_id,
                        )
                      }
                      className="p-1 rounded-full hover:bg-gray-200 dark:hover:bg-gray-600"
                    >
                      {expandedRow === device.device_id ? (
                        <ChevronDown className="h-5 w-5 text-gray-600 dark:text-gray-400" />
                      ) : (
                        <ChevronRight className="h-5 w-5 text-gray-600 dark:text-gray-400" />
                      )}
                    </button>
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap">
                    <div className="flex items-center gap-2">
                      {getDeviceDisplayStatus(device) ? (
                        <CheckCircle className="h-5 w-5 text-green-500" />
                      ) : (
                        <XCircle className="h-5 w-5 text-red-500" />
                      )}
                      <DeviceTypeIndicator
                        deviceId={device.device_id}
                        compact={true}
                        discoverySource={
                          Array.isArray(device.discovery_sources)
                            ? device.discovery_sources.join(",")
                            : undefined
                        }
                      />
                      <SysmonStatusIndicator
                        deviceId={device.device_id}
                        compact={true}
                        hasMetrics={
                          sysmonStatusesLoading
                            ? undefined
                            : sysmonStatuses[device.device_id]?.hasMetrics
                        }
                        serviceHint={sysmonServiceHint}
                      />
                      <SNMPStatusIndicator
                        deviceId={device.device_id}
                        compact={true}
                        hasMetrics={
                          snmpStatusesLoading
                            ? undefined
                            : snmpStatuses[device.device_id]?.hasMetrics
                        }
                        hasSnmpSource={
                          Array.isArray(device.discovery_sources) &&
                          (device.discovery_sources.includes("snmp") ||
                            device.discovery_sources.includes("mapper"))
                        }
                      />
                      {icmpCollectorInfo.get(device.device_id)
                        ?.shouldRender && (
                        <ICMPSparkline
                          deviceId={device.device_id}
                          deviceIp={device.ip}
                          compact={false}
                          hasMetrics={
                            icmpCollectorInfo.get(device.device_id)?.hasMetrics
                          }
                          hasCollector={
                            collectorInfoByDevice.get(device.device_id)
                              ?.hasCollector
                          }
                          supportsICMP={
                            collectorInfoByDevice.get(device.device_id)
                              ?.supports.icmp
                          }
                        />
                      )}
                    </div>
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap">
                    <Link
                      href={`/devices/${encodeURIComponent(device.device_id)}`}
                      className="block hover:bg-gray-50 dark:hover:bg-gray-700/50 -m-4 p-4 rounded transition-colors"
                    >
                      <div className="text-sm font-medium text-blue-600 dark:text-blue-400 hover:text-blue-800 dark:hover:text-blue-300">
                        {device.hostname || device.ip}
                      </div>
                      <div className="text-sm text-gray-500 dark:text-gray-400">
                        {device.hostname ? device.ip : device.mac}
                      </div>
                      {collectorBadges.length > 0 && (
                        <div className="mt-1 flex flex-wrap gap-1">
                          {collectorBadges}
                        </div>
                      )}
                    </Link>
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap">
                    <div className="flex flex-wrap gap-1">
                      {Array.isArray(device.discovery_sources)
                        ? device.discovery_sources
                            .filter(
                              (source): source is string =>
                                typeof source === "string" && source.length > 0,
                            )
                            .sort((a, b) => a.localeCompare(b))
                            .map((source) => (
                              <span
                                key={source}
                                className={`px-2 inline-flex text-xs leading-5 font-semibold rounded-full ${getSourceColor(source)}`}
                              >
                                {source}
                              </span>
                            ))
                        : null}
                    </div>
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300">
                    {device.poller_id}
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-700 dark:text-gray-300">
                    {formatDate(device.last_seen)}
                  </td>
                </tr>
                {expandedRow === device.device_id && (
                  <tr className="bg-gray-50 dark:bg-gray-800/50">
                    <td colSpan={6} className="p-0">
                      <div className="p-4 space-y-4">
                        {Array.isArray(device.capability_snapshots) &&
                          device.capability_snapshots.length > 0 && (
                            <div>
                              <h4 className="text-md font-semibold text-gray-900 dark:text-white mb-2">
                                Capability Status
                              </h4>
                              <div className="overflow-x-auto rounded-lg border border-gray-200 dark:border-gray-700">
                                <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
                                  <thead className="bg-gray-100 dark:bg-gray-700/60">
                                    <tr>
                                      <th className="px-4 py-2 text-left font-semibold text-gray-700 dark:text-gray-200">
                                        Capability
                                      </th>
                                      <th className="px-4 py-2 text-left font-semibold text-gray-700 dark:text-gray-200">
                                        Service
                                      </th>
                                      <th className="px-4 py-2 text-left font-semibold text-gray-700 dark:text-gray-200">
                                        Status
                                      </th>
                                      <th className="px-4 py-2 text-left font-semibold text-gray-700 dark:text-gray-200">
                                        Last Success
                                      </th>
                                      <th className="px-4 py-2 text-left font-semibold text-gray-700 dark:text-gray-200">
                                        Last Failure
                                      </th>
                                      <th className="px-4 py-2 text-left font-semibold text-gray-700 dark:text-gray-200">
                                        Last Checked
                                      </th>
                                      <th className="px-4 py-2 text-left font-semibold text-gray-700 dark:text-gray-200">
                                        Recorded By
                                      </th>
                                      <th className="px-4 py-2 text-left font-semibold text-gray-700 dark:text-gray-200">
                                        Failure Reason
                                      </th>
                                      <th className="px-4 py-2 text-left font-semibold text-gray-700 dark:text-gray-200">
                                        Metadata
                                      </th>
                                    </tr>
                                  </thead>
                                  <tbody className="divide-y divide-gray-200 dark:divide-gray-700 bg-white dark:bg-gray-900/30">
                                    {device.capability_snapshots.map((snapshot) => {
                                      const { label, classes } =
                                        getCapabilityStateBadge(snapshot);
                                      const serviceLabel = describeService(snapshot);
                                      const rowKey = `${snapshot.capability}-${snapshot.service_id ?? "global"}-${
                                        snapshot.recorded_by ?? "system"
                                      }-${snapshot.last_checked ?? "na"}`;
                                      const metadataSummary = summarizeMetadata(
                                        snapshot.metadata,
                                      );

                                      return (
                                        <tr key={rowKey}>
                                          <td className="px-4 py-2 font-mono text-xs uppercase tracking-wide text-gray-800 dark:text-gray-100">
                                            {snapshot.capability || "unknown"}
                                          </td>
                                          <td className="px-4 py-2 text-sm text-gray-700 dark:text-gray-200">
                                            {serviceLabel}
                                          </td>
                                          <td className="px-4 py-2">
                                            <span
                                              className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold capitalize ${classes}`}
                                            >
                                              {label}
                                            </span>
                                          </td>
                                          <td className="px-4 py-2 text-sm text-gray-700 dark:text-gray-200">
                                            {formatCapabilityTimestamp(snapshot.last_success)}
                                          </td>
                                          <td className="px-4 py-2 text-sm text-gray-700 dark:text-gray-200">
                                            {formatCapabilityTimestamp(snapshot.last_failure)}
                                          </td>
                                          <td className="px-4 py-2 text-sm text-gray-700 dark:text-gray-200">
                                            {formatCapabilityTimestamp(snapshot.last_checked)}
                                          </td>
                                          <td className="px-4 py-2 text-sm text-gray-700 dark:text-gray-200">
                                            {snapshot.recorded_by ?? "—"}
                                          </td>
                                          <td className="px-4 py-2 text-sm text-gray-600 dark:text-gray-300">
                                            {snapshot.failure_reason ?? "—"}
                                          </td>
                                          <td className="px-4 py-2 text-xs text-gray-600 dark:text-gray-300">
                                            {metadataSummary === "—" ? (
                                              "—"
                                            ) : (
                                              <span title={JSON.stringify(snapshot.metadata, null, 2)}>
                                                {metadataSummary}
                                              </span>
                                            )}
                                          </td>
                                        </tr>
                                      );
                                    })}
                                  </tbody>
                                </table>
                              </div>
                            </div>
                          )}
                        <div>
                          <h4 className="text-md font-semibold text-gray-900 dark:text-white mb-2">
                            Metadata
                          </h4>
                          <ReactJson
                            src={device.metadata}
                            theme="pop"
                            collapsed={false}
                            displayDataTypes={false}
                            enableClipboard={true}
                            style={{
                              padding: "1rem",
                              borderRadius: "0.375rem",
                              backgroundColor: "#1C1B22",
                            }}
                          />
                        </div>
                      </div>
                    </td>
                  </tr>
                )}
              </Fragment>
            );
          })}
        </tbody>
      </table>
    </div>
  );
};

export default DeviceTable;
