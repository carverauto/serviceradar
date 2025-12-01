/*
 * Lightweight AGE device graph summary for inventory/detail views.
 * Fetches the neighborhood and renders badges for collectors, services,
 * capabilities, and targets with a toggle to hide non-collector-owned items.
 */
"use client";

import React, { useEffect, useMemo, useState } from "react";
import {
  ShieldCheck,
  Radio,
  Network,
  ServerCog,
  Plug,
  Loader2,
  AlertTriangle,
  EyeOff,
  Eye,
} from "lucide-react";
import type {
  DeviceGraphNeighborhood,
  AgeServiceEdge,
} from "@/types/deviceGraph";
import {
  capabilityLabel,
  collectorOwnedServices,
  fetchDeviceGraph,
  nodeId,
  nodeType,
  targetServices,
} from "@/lib/graph";

type DeviceGraphSummaryProps = {
  deviceId: string;
  defaultCollectorOwnedOnly?: boolean;
  includeTopology?: boolean;
};

const Badge = ({
  label,
  description,
  tone = "blue",
}: {
  label: string;
  description?: string;
  tone?: "blue" | "purple" | "green" | "amber";
}) => {
  const toneClasses: Record<string, string> = {
    blue: "bg-blue-100 text-blue-800 dark:bg-blue-900/40 dark:text-blue-200",
    purple:
      "bg-purple-100 text-purple-800 dark:bg-purple-900/40 dark:text-purple-200",
    green:
      "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/40 dark:text-emerald-200",
    amber:
      "bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-200",
  };

  return (
    <span
      className={`inline-flex items-center gap-1 rounded-full px-2 py-1 text-xs font-semibold ${toneClasses[tone] ?? toneClasses.blue}`}
      title={description}
    >
      {label}
    </span>
  );
};

const renderServices = (
  services: AgeServiceEdge[],
  tone: "purple" | "green",
): React.ReactElement => {
  if (services.length === 0) {
    return (
      <p className="text-sm text-gray-500 dark:text-gray-400">
        No services reported yet.
      </p>
    );
  }

  return (
    <div className="flex flex-wrap gap-2">
      {services.map((svc) => {
        const svcNodeId = nodeId(svc.service);
        const svcType = nodeType(svc.service);
        const label = svcNodeId || "service";
        const description =
          svcType && svcType !== label ? `${svcType} • ${label}` : label;
        return (
          <Badge
            key={`${label}-${svc.collector_id ?? "none"}`}
            label={label}
            description={description}
            tone={tone}
          />
        );
      })}
    </div>
  );
};

const DeviceGraphSummary: React.FC<DeviceGraphSummaryProps> = ({
  deviceId,
  defaultCollectorOwnedOnly = false,
  includeTopology = true,
}) => {
  const [graph, setGraph] = useState<DeviceGraphNeighborhood | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [collectorOwnedOnly, setCollectorOwnedOnly] = useState(
    defaultCollectorOwnedOnly,
  );

  useEffect(() => {
    let cancelled = false;
    const load = async () => {
      setLoading(true);
      setError(null);
      try {
        const result = await fetchDeviceGraph(deviceId, {
          collectorOwnedOnly,
          includeTopology,
        });
        if (!cancelled) {
          setGraph(result);
        }
      } catch (err) {
        if (!cancelled) {
          const message =
            err instanceof Error ? err.message : "Failed to load device graph";
          setError(message);
          setGraph(null);
        }
      } finally {
        if (!cancelled) {
          setLoading(false);
        }
      }
    };

    void load();
    return () => {
      cancelled = true;
    };
  }, [collectorOwnedOnly, deviceId]);

  const collectors = useMemo(() => graph?.collectors ?? [], [graph]);
  const services = useMemo(() => graph?.services ?? [], [graph]);
  const capabilities = useMemo(
    () => ({
      device: graph?.device_capabilities ?? [],
      service: graph?.service_capabilities ?? [],
    }),
    [graph],
  );
  const targets = useMemo(() => graph?.targets ?? [], [graph]);
  const interfaces = useMemo(() => graph?.interfaces ?? [], [graph]);
  const peerInterfaces = useMemo(
    () => graph?.peer_interfaces ?? [],
    [graph],
  );

  return (
    <div className="rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-900/60">
      <div className="flex items-center justify-between border-b border-gray-200 dark:border-gray-700 px-4 py-3">
        <div className="flex items-center gap-2 text-sm font-semibold text-gray-900 dark:text-gray-100">
          <Network className="h-4 w-4" />
          Graph Relationships
        </div>
        <button
          type="button"
          onClick={() => setCollectorOwnedOnly((prev) => !prev)}
          className="inline-flex items-center gap-1 rounded-md border border-gray-300 dark:border-gray-700 px-3 py-1 text-xs font-medium text-gray-800 dark:text-gray-100 hover:bg-gray-100 dark:hover:bg-gray-800"
        >
          {collectorOwnedOnly ? (
            <>
              <EyeOff className="h-4 w-4" />
              Collector-owned only
            </>
          ) : (
            <>
              <Eye className="h-4 w-4" />
              Include targets
            </>
          )}
        </button>
      </div>

      <div className="space-y-4 p-4">
        {loading && (
          <div className="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-300">
            <Loader2 className="h-4 w-4 animate-spin" />
            Loading graph neighborhood…
          </div>
        )}

        {error && (
          <div className="flex items-center gap-2 text-sm text-red-500">
            <AlertTriangle className="h-4 w-4" />
            {error}
          </div>
        )}

        {!loading && !error && (
          <>
            <div className="space-y-2">
              <div className="flex items-center gap-2 text-sm font-semibold text-gray-900 dark:text-gray-100">
                <Radio className="h-4 w-4" />
                Collectors
              </div>
              {collectors.length === 0 ? (
                <p className="text-sm text-gray-500 dark:text-gray-400">
                  No collectors linked yet.
                </p>
              ) : (
                <div className="flex flex-wrap gap-2">
                  {collectors.map((collector) => {
                    const id = nodeId(collector);
                    const cType = nodeType(collector);
                    const description =
                      cType && cType !== id ? `${cType} • ${id}` : id;
                    return (
                      <Badge
                        key={id || description}
                        label={id || "collector"}
                        description={description}
                        tone="blue"
                      />
                    );
                  })}
                </div>
              )}
            </div>

            <div className="space-y-2">
              <div className="flex items-center gap-2 text-sm font-semibold text-gray-900 dark:text-gray-100">
                <ServerCog className="h-4 w-4" />
                Collector-owned services
              </div>
              {renderServices(collectorOwnedServices(services), "purple")}
            </div>

            {!collectorOwnedOnly && (
              <div className="space-y-2">
                <div className="flex items-center gap-2 text-sm font-semibold text-gray-900 dark:text-gray-100">
                  <Plug className="h-4 w-4" />
                  Targeted services
                </div>
                {renderServices(targetServices(services), "green")}
              </div>
            )}

            <div className="space-y-2">
              <div className="flex items-center gap-2 text-sm font-semibold text-gray-900 dark:text-gray-100">
                <ShieldCheck className="h-4 w-4" />
                Capabilities
              </div>
              {capabilities.device.length === 0 &&
              capabilities.service.length === 0 ? (
                <p className="text-sm text-gray-500 dark:text-gray-400">
                  No capabilities reported yet.
                </p>
              ) : (
                <div className="flex flex-wrap gap-2">
                  {capabilities.device.map((cap) => {
                    const label = capabilityLabel(cap) || "capability";
                    return (
                      <Badge
                        key={`device-cap-${label}-${nodeId(cap)}`}
                        label={label}
                        tone="green"
                        description="Device capability"
                      />
                    );
                  })}
                  {capabilities.service.map((cap) => {
                    const label = capabilityLabel(cap) || "capability";
                    return (
                      <Badge
                        key={`service-cap-${label}-${nodeId(cap)}`}
                        label={label}
                        tone="amber"
                        description="Service capability"
                      />
                    );
                  })}
                </div>
              )}
            </div>

            {includeTopology && (interfaces.length > 0 || peerInterfaces.length > 0) && (
              <div className="space-y-2">
                <div className="flex items-center gap-2 text-sm font-semibold text-gray-900 dark:text-gray-100">
                  <Network className="h-4 w-4" />
                  Interfaces & topology
                </div>
                {interfaces.length === 0 ? (
                  <p className="text-sm text-gray-500 dark:text-gray-400">
                    No interfaces discovered yet.
                  </p>
                ) : (
                  <div className="flex flex-wrap gap-2">
                    {interfaces.map((iface) => {
                      const id = nodeId(iface);
                      const label =
                        id || nodeType(iface) || "interface";
                      return (
                        <Badge
                          key={`iface-${label}`}
                          label={label}
                          tone="blue"
                          description="Discovered interface"
                        />
                      );
                    })}
                  </div>
                )}
                {peerInterfaces.length > 0 && (
                  <div className="flex flex-wrap gap-2">
                    {peerInterfaces.map((peer) => {
                      const id = nodeId(peer);
                      return (
                        <Badge
                          key={`peer-${id || nodeType(peer)}`}
                          label={id || nodeType(peer) || "peer"}
                          tone="purple"
                          description="Peer interface"
                        />
                      );
                    })}
                  </div>
                )}
              </div>
            )}

            {!collectorOwnedOnly && targets.length > 0 && (
              <div className="space-y-2">
                <div className="flex items-center gap-2 text-sm font-semibold text-gray-900 dark:text-gray-100">
                  <Network className="h-4 w-4" />
                  Targets
                </div>
                <div className="flex flex-wrap gap-2">
                  {targets.map((tgt) => {
                    const id = nodeId(tgt);
                    return (
                      <Badge
                        key={`target-${id || nodeType(tgt)}`}
                        label={id || nodeType(tgt) || "target"}
                        tone="blue"
                      />
                    );
                  })}
                </div>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
};

export default DeviceGraphSummary;
