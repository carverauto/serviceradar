/*
 * ReactFlow-based canvas for rendering a device neighborhood from the AGE graph.
 */
"use client";

import React, { useMemo } from "react";
import Link from "next/link";
import ReactFlow, {
  Background,
  Controls,
  Edge,
  MarkerType,
  Node,
  NodeProps,
  Position,
  ReactFlowProvider,
} from "reactflow";
import "reactflow/dist/style.css";
import type {
  AgeNode,
  AgeServiceEdge,
  DeviceGraphNeighborhood,
} from "@/types/deviceGraph";
import { capabilityLabel, nodeId, nodeType } from "@/lib/graph";

type GraphNodeKind = "device" | "collector" | "service" | "interface" | "target";

type FlowNodeData = {
  label: string;
  subLabel?: string;
  badges?: string[];
  href?: string;
  kind: GraphNodeKind;
};

const kindClasses: Record<GraphNodeKind, string> = {
  device:
    "border-blue-200 dark:border-blue-800 bg-blue-50 dark:bg-blue-900/30",
  collector:
    "border-purple-200 dark:border-purple-800 bg-purple-50 dark:bg-purple-900/30",
  service:
    "border-emerald-200 dark:border-emerald-800 bg-emerald-50 dark:bg-emerald-900/30",
  interface:
    "border-amber-200 dark:border-amber-700 bg-amber-50 dark:bg-amber-900/30",
  target:
    "border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-900/30",
};

const FlowNode: React.FC<NodeProps<FlowNodeData>> = ({ data }) => {
  const kind = (data?.kind as GraphNodeKind | undefined) ?? "device";
  const badges = Array.isArray(data?.badges) ? data.badges : [];

  const body = (
    <div
      className={`min-w-[160px] rounded-md border px-3 py-2 shadow-sm ${kindClasses[kind] ?? kindClasses.device}`}
    >
      <div className="flex items-center justify-between gap-2">
        <span className="text-sm font-semibold text-gray-900 dark:text-gray-50">
          {data?.label}
        </span>
        <span className="text-[10px] uppercase tracking-wide text-gray-600 dark:text-gray-300">
          {kind}
        </span>
      </div>
      {data?.subLabel && (
        <div className="mt-0.5 text-xs text-gray-600 dark:text-gray-300">
          {data.subLabel}
        </div>
      )}
      {badges.length > 0 && (
        <div className="mt-2 flex flex-wrap gap-1">
          {badges.map((badge: string) => (
            <span
              key={badge}
              className="rounded-full bg-black/5 px-2 py-0.5 text-[10px] font-semibold uppercase text-gray-700 dark:bg-white/10 dark:text-gray-100"
            >
              {badge}
            </span>
          ))}
        </div>
      )}
    </div>
  );

  if (data.href) {
    return (
      <Link href={data.href} className="block">
        {body}
      </Link>
    );
  }

  return body;
};

const nodeTypes = {
  srNode: FlowNode,
};

const nameForNode = (node?: AgeNode | null): string => {
  const props = node?.properties ?? {};
  const hostname =
    typeof props["hostname"] === "string" ? props["hostname"] : undefined;
  const ip = typeof props["ip"] === "string" ? props["ip"] : undefined;
  return hostname || ip || nodeId(node) || node?.label || "node";
};

const deriveKind = (node?: AgeNode | null): GraphNodeKind => {
  const id = nodeId(node).toLowerCase();
  const type = nodeType(node).toLowerCase();
  const label = (node?.label ?? "").toLowerCase();

  if (
    id.startsWith("serviceradar:agent:") ||
    id.startsWith("serviceradar:poller:") ||
    type === "agent" ||
    type === "poller" ||
    label === "collector"
  ) {
    return "collector";
  }

  if (label === "interface" || id.includes("/")) {
    return "interface";
  }

  if (label === "service" || type === "service" || id.startsWith("serviceradar:")) {
    return "service";
  }

  return "device";
};

const stackPositions = (
  count: number,
  x: number,
  startY = 0,
  spacing = 120,
): { x: number; y: number }[] => {
  if (count === 0) return [];
  const offset = ((count - 1) * spacing) / 2;
  return Array.from({ length: count }).map((_, idx) => ({
    x,
    y: startY + idx * spacing - offset,
  }));
};

type DeviceGraphCanvasProps = {
  deviceId: string;
  graph: DeviceGraphNeighborhood | null;
  collectorOwnedOnly: boolean;
  includeTopology: boolean;
};

const DeviceGraphCanvas: React.FC<DeviceGraphCanvasProps> = ({
  deviceId,
  graph,
  collectorOwnedOnly,
  includeTopology,
}) => {
  const { nodes, edges } = useMemo(() => {
    if (!graph) {
      return { nodes: [] as Node<FlowNodeData>[], edges: [] as Edge[] };
    }

    const flowNodes: Node<FlowNodeData>[] = [];
    const flowEdges: Edge[] = [];

    const addEdge = (
      source: string,
      target: string,
      label?: string,
      variant?: "solid" | "dashed",
    ) => {
      const key = `${source}->${target}-${label ?? "link"}`;
      flowEdges.push({
        id: key,
        source,
        target,
        label,
        type: "smoothstep",
        animated: variant !== "dashed",
        markerEnd: { type: MarkerType.ArrowClosed, color: "#64748b" },
        style: variant === "dashed" ? { strokeDasharray: "6 4" } : undefined,
      });
    };

    const mainNodeId = nodeId(graph.device) || deviceId;
    const mainKind = deriveKind(graph.device);
    const deviceBadges = [
      ...((graph.device_capabilities ?? [])
        .map((cap) => capabilityLabel(cap) || "")
        .filter(Boolean)),
      collectorOwnedOnly ? "collector scope" : "full scope",
    ];

    const rootNodeId = `root:${mainNodeId}`;
    flowNodes.push({
      id: rootNodeId,
      position: { x: 80, y: 0 },
      type: "srNode",
      data: {
        label: nameForNode(graph.device) || mainNodeId,
        subLabel: nodeType(graph.device) || mainNodeId,
        badges: deviceBadges.filter(Boolean),
        href: `/devices/${encodeURIComponent(mainNodeId)}`,
        kind: mainKind,
      },
      draggable: false,
      sourcePosition: Position.Right,
      targetPosition: Position.Left,
    });

    const collectorPositions = stackPositions(
      graph.collectors?.length ?? 0,
      -280,
    );
    const collectorIdMap = new Map<string, string>();
    (graph.collectors ?? []).forEach((collector, idx) => {
      const id = nodeId(collector) || `collector-${idx}`;
      const flowId = `collector:${id}`;
      collectorIdMap.set(id, flowId);
      flowNodes.push({
        id: flowId,
        position: collectorPositions[idx] ?? { x: -280, y: idx * 80 },
        type: "srNode",
        data: {
          label: nameForNode(collector),
          subLabel: nodeType(collector) || id,
          badges: [],
          href: `/devices/${encodeURIComponent(id)}`,
          kind: "collector",
        },
        sourcePosition: Position.Right,
        targetPosition: Position.Left,
      });

      if (mainKind !== "collector") {
        addEdge(flowId, rootNodeId, "reports");
      } else {
        addEdge(flowId, rootNodeId, "parent");
      }
    });

    const serviceMap = new Map<string, AgeServiceEdge>();
    (graph.services ?? []).forEach((svc) => {
      const id = nodeId(svc.service);
      const key = id || `service-${serviceMap.size}`;
      if (!serviceMap.has(key)) {
        serviceMap.set(key, svc);
      }
    });

    const servicePositions = stackPositions(serviceMap.size, -60);
    let svcIdx = 0;
    const serviceFlowIds: string[] = [];
    Array.from(serviceMap.entries()).forEach(([svcId, svcEdge]) => {
      const flowId = `service:${svcId}`;
      serviceFlowIds.push(flowId);
      const svcKind = deriveKind(svcEdge.service);
      const badges = [
        nodeType(svcEdge.service) || "service",
        svcEdge.collector_owned ? "collector-owned" : "targeting",
      ].filter(Boolean);
      flowNodes.push({
        id: flowId,
        position: servicePositions[svcIdx] ?? { x: -60, y: svcIdx * 80 },
        type: "srNode",
        data: {
          label: nameForNode(svcEdge.service),
          subLabel: nodeId(svcEdge.service) || svcId,
          badges,
          href: svcId ? `/devices/${encodeURIComponent(svcId)}` : undefined,
          kind: svcKind,
        },
        sourcePosition: Position.Right,
        targetPosition: Position.Left,
      });
      svcIdx += 1;

      const hostCollector =
        (svcEdge.collector_id && collectorIdMap.get(svcEdge.collector_id)) ||
        (mainKind === "collector" ? rootNodeId : null);
      if (hostCollector) {
        addEdge(hostCollector, flowId, "hosts");
      }

      if (mainKind === "device") {
        addEdge(flowId, rootNodeId, "targets");
      } else if (mainKind === "collector" && (graph.targets?.length ?? 0) === 0) {
        addEdge(rootNodeId, flowId, "runs");
      }
    });

    const targetPositions = stackPositions(graph.targets?.length ?? 0, 260);
    (graph.targets ?? []).forEach((target, idx) => {
      const id = nodeId(target) || `target-${idx}`;
      const flowId = `target:${id}`;
      flowNodes.push({
        id: flowId,
        position: targetPositions[idx] ?? { x: 260, y: idx * 80 },
        type: "srNode",
        data: {
          label: nameForNode(target),
          subLabel: nodeType(target) || id,
          href: `/devices/${encodeURIComponent(id)}`,
          badges: [],
          kind: "target",
        },
        sourcePosition: Position.Right,
        targetPosition: Position.Left,
      });

      if (mainKind === "collector") {
        addEdge(rootNodeId, flowId, "monitors");
      } else {
        addEdge(rootNodeId, flowId, "peer");
      }

      if (serviceFlowIds.length > 0) {
        serviceFlowIds.forEach((svcFlowId) => addEdge(svcFlowId, flowId, "targets"));
      }
    });

    if (includeTopology) {
      const interfacePositions = stackPositions(
        graph.interfaces?.length ?? 0,
        80,
        140,
        90,
      );
      (graph.interfaces ?? []).forEach((iface, idx) => {
        const id = nodeId(iface) || `iface-${idx}`;
        const flowId = `iface:${id}`;
        flowNodes.push({
          id: flowId,
          position: interfacePositions[idx] ?? { x: 80, y: 140 + idx * 90 },
          type: "srNode",
          data: {
            label: nameForNode(iface),
            subLabel: nodeType(iface) || id,
            href: `/devices/${encodeURIComponent(id)}`,
            badges: ["interface"],
            kind: "interface",
          },
          sourcePosition: Position.Right,
          targetPosition: Position.Left,
        });
        addEdge(rootNodeId, flowId, "has");
      });

      const peerPositions = stackPositions(
        graph.peer_interfaces?.length ?? 0,
        360,
        160,
        90,
      );
      (graph.peer_interfaces ?? []).forEach((peer, idx) => {
        const id = nodeId(peer) || `peer-${idx}`;
        const flowId = `peer:${id}`;
        flowNodes.push({
          id: flowId,
          position: peerPositions[idx] ?? { x: 360, y: 160 + idx * 90 },
          type: "srNode",
          data: {
            label: nameForNode(peer),
            subLabel: nodeType(peer) || id,
            href: `/devices/${encodeURIComponent(id)}`,
            badges: ["peer"],
            kind: "interface",
          },
          sourcePosition: Position.Right,
          targetPosition: Position.Left,
        });

        const ifaceTarget =
          graph.interfaces && graph.interfaces.length > 0
            ? `iface:${nodeId(graph.interfaces[idx % graph.interfaces.length]) || `iface-${idx % graph.interfaces.length}`}`
            : rootNodeId;
        addEdge(ifaceTarget, flowId, "connects", "dashed");
      });
    }

    return { nodes: flowNodes, edges: flowEdges };
  }, [collectorOwnedOnly, deviceId, graph, includeTopology]);

  if (!graph) {
    return (
      <div className="flex items-center gap-2 text-sm text-gray-500 dark:text-gray-300">
        Neighborhood graph is not available yet.
      </div>
    );
  }

  return (
    <div className="h-[420px] w-full">
      <ReactFlowProvider>
        <ReactFlow
          nodes={nodes}
          edges={edges}
          nodeTypes={nodeTypes}
          fitView
          minZoom={0.6}
          maxZoom={1.5}
          proOptions={{ hideAttribution: true }}
          defaultEdgeOptions={{
            animated: true,
          }}
        >
          <Background />
          <Controls />
        </ReactFlow>
      </ReactFlowProvider>
    </div>
  );
};

export default DeviceGraphCanvas;
