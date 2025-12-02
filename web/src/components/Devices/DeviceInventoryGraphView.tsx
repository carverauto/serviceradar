/*
 * Graph-forward inventory view that renders each device with its graph relationships.
 */
"use client";

import React from "react";
import Link from "next/link";
import { CheckCircle, Clock, MapPin, XCircle } from "lucide-react";
import DeviceGraphSummary from "./DeviceGraphSummary";
import DeviceTypeIndicator from "./DeviceTypeIndicator";
import type { Device } from "@/types/devices";
import { formatTimestampForDisplay } from "@/utils/traceTimestamp";

type DeviceInventoryGraphViewProps = {
  devices: Device[];
  collectorServiceMeta: Map<string, string>;
};

const DeviceInventoryGraphView: React.FC<DeviceInventoryGraphViewProps> = ({
  devices,
  collectorServiceMeta,
}) => {
  if (!devices || devices.length === 0) {
    return (
      <div className="text-center p-8 text-gray-600 dark:text-gray-300">
        No devices found.
      </div>
    );
  }

  return (
    <div className="space-y-4 p-4">
      {devices.map((device) => {
        const serviceTypeLabel =
          collectorServiceMeta.get(device.device_id) ?? null;
        const isCollectorService = Boolean(serviceTypeLabel);
        const deviceName =
          device.hostname || device.ip || device.device_id || "device";
        const online = device.is_available;

        return (
          <div
            key={device.device_id}
            className="overflow-hidden rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900"
          >
            <div className="flex flex-col gap-3 border-b border-gray-200 dark:border-gray-800 px-4 py-3 md:flex-row md:items-start md:justify-between">
              <div className="space-y-1">
                <div className="flex flex-wrap items-center gap-2">
                  {online ? (
                    <CheckCircle className="h-5 w-5 text-emerald-500" />
                  ) : (
                    <XCircle className="h-5 w-5 text-rose-500" />
                  )}
                  <Link
                    href={`/devices/${encodeURIComponent(device.device_id)}`}
                    className="text-lg font-semibold text-blue-700 dark:text-blue-300 hover:underline"
                  >
                    {deviceName}
                  </Link>
                  <DeviceTypeIndicator
                    deviceId={device.device_id}
                    compact
                    discoverySource={
                      Array.isArray(device.discovery_sources)
                        ? device.discovery_sources.join(",")
                        : undefined
                    }
                  />
                  {isCollectorService && (
                    <span className="inline-flex items-center gap-1 rounded-full bg-emerald-100 px-2 py-0.5 text-xs font-semibold text-emerald-800 dark:bg-emerald-800/40 dark:text-emerald-100">
                      Collector service
                      {serviceTypeLabel ? ` • ${serviceTypeLabel}` : ""}
                    </span>
                  )}
                </div>
                <div className="flex flex-wrap items-center gap-2 text-xs text-gray-600 dark:text-gray-400">
                  <span className="font-mono break-all">{device.device_id}</span>
                  {device.ip && (
                    <span className="inline-flex items-center gap-1">
                      <MapPin className="h-3 w-3" />
                      {device.ip}
                    </span>
                  )}
                  {device.hostname && (
                    <span className="text-gray-500 dark:text-gray-400">
                      ({device.hostname})
                    </span>
                  )}
                </div>
              </div>
              <div className="text-right text-xs text-gray-600 dark:text-gray-400">
                <div className="inline-flex items-center gap-1">
                  <Clock className="h-3 w-3" />
                  Last seen {formatTimestampForDisplay(device.last_seen)}
                </div>
                <div>Poller: {device.poller_id || "—"}</div>
              </div>
            </div>
            <div className="p-4">
              <DeviceGraphSummary
                deviceId={device.device_id}
                defaultCollectorOwnedOnly={true}
                includeTopology={false}
              />
            </div>
          </div>
        );
      })}
    </div>
  );
};

export default DeviceInventoryGraphView;
