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
import { Device } from "@/types/devices";
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
    const metadata = (device.metadata ?? {}) as Record<string, unknown>;
    const capabilityHints = device.collector_capabilities;
    const metricsSummaryRaw = device.metrics_summary;
    const metricsSummary = (metricsSummaryRaw ?? {}) as Record<string, boolean>;

    const getMetadataString = (key: string): string => {
      const value = metadata[key];
      return typeof value === "string" ? value.trim() : "";
    };

    const registerServiceType = (raw: string, bucket: Set<string>) => {
      const value = raw.trim().toLowerCase();
      if (!value) {
        return;
      }

      if (value.includes("icmp") || value.includes("ping")) {
        bucket.add("icmp");
      }
      if (value.includes("sysmon")) {
        bucket.add("sysmon");
      }
      if (value.includes("snmp")) {
        bucket.add("snmp");
      }
    };

    const serviceTypes = new Set<string>();

    const serviceId = (
      aliasHistory?.current_service_id ||
      getMetadataString("_alias_last_seen_service_id") ||
      getMetadataString("collector_agent_id")
    ).trim();
    const collectorIp = (
      aliasHistory?.collector_ip || getMetadataString("_alias_collector_ip")
    ).trim();
    const aliasIp = (
      aliasHistory?.current_ip || getMetadataString("_alias_last_seen_ip")
    ).trim();

    if (typeof metadata.checker_service_type === "string") {
      registerServiceType(metadata.checker_service_type, serviceTypes);
    }
    if (typeof metadata.checker_service === "string") {
      registerServiceType(metadata.checker_service, serviceTypes);
    }
    if (
      typeof metadata.icmp_service_name === "string" ||
      "icmp_target" in metadata ||
      "_last_icmp_update_at" in metadata
    ) {
      serviceTypes.add("icmp");
    }
    if ("snmp_monitoring" in metadata) {
      serviceTypes.add("snmp");
    }

    Object.keys(metadata).forEach((key) => {
      if (key.startsWith("service_alias:")) {
        registerServiceType(
          key.substring("service_alias:".length),
          serviceTypes,
        );
      }
    });

    aliasHistory?.services?.forEach((svc) => {
      if (svc?.id) {
        registerServiceType(svc.id, serviceTypes);
      }
    });

    device.discovery_sources?.forEach((source) => {
      if (typeof source === "string") {
        registerServiceType(source, serviceTypes);
      }
    });

    const collectorAgent = getMetadataString("collector_agent_id");
    const collectorPoller = getMetadataString("collector_poller_id");

    let hasCollector = Boolean(
      serviceId ||
        collectorIp ||
        collectorAgent ||
        collectorPoller ||
        serviceTypes.size > 0,
    );

    let supports: CollectorFlags = {
      icmp: serviceTypes.has("icmp"),
      sysmon: serviceTypes.has("sysmon"),
      snmp: serviceTypes.has("snmp"),
    };

    if (capabilityHints) {
      hasCollector = capabilityHints.has_collector ?? hasCollector;
      supports = {
        icmp: capabilityHints.supports_icmp ?? supports.icmp,
        sysmon: capabilityHints.supports_sysmon ?? supports.sysmon,
        snmp: capabilityHints.supports_snmp ?? supports.snmp,
      };

      if (!supports.icmp && serviceTypes.has("icmp")) {
        supports.icmp = true;
      }
      if (!supports.sysmon && serviceTypes.has("sysmon")) {
        supports.sysmon = true;
      }
      if (!supports.snmp && serviceTypes.has("snmp")) {
        supports.snmp = true;
      }
    } else if (serviceTypes.size === 0 && hasCollector) {
      supports.icmp = true;
      supports.sysmon = true;
      supports.snmp = true;
    }

    if (metricsSummaryRaw !== undefined) {
      if (!supports.icmp && metricsSummary.icmp === true) {
        supports.icmp = true;
      }
      if (!supports.sysmon && metricsSummary.sysmon === true) {
        supports.sysmon = true;
      }
      if (!supports.snmp && metricsSummary.snmp === true) {
        supports.snmp = true;
      }
      if (!hasCollector) {
        hasCollector = Object.values(metricsSummary).some(Boolean);
      }
    }

    return {
      serviceId,
      collectorIp,
      aliasIp,
      hasCollector,
      supports,
    };
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
      const hasExplicitCollector = Boolean(
        info.serviceId || info.collectorIp || info.aliasIp,
      );

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
                          compact={false}
                          hasMetrics={
                            icmpCollectorInfo.get(device.device_id)?.hasMetrics
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
                      <div className="p-4">
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
