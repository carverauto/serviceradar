/*
 * D3-based canvas for rendering a device neighborhood from the AGE graph.
 * Uses a cluster/dendrogram layout for typical neighborhoods and a pack
 * layout that groups targets by CIDR for very large neighborhoods to avoid
 * drawing tens of thousands of edges.
 */
"use client";

import React, { useMemo } from "react";
import { cluster, hierarchy, pack } from "d3-hierarchy";
import type {
  AgeNode,
  AgeServiceEdge,
  DeviceGraphNeighborhood,
} from "@/types/deviceGraph";
import { capabilityLabel, nodeId, nodeType } from "@/lib/graph";

type GraphNodeKind =
  | "device"
  | "collector"
  | "service"
  | "interface"
  | "target";

type GraphNode = {
  id: string;
  label: string;
  subLabel?: string;
  badges?: string[];
  href?: string;
  kind: GraphNodeKind;
  children?: GraphNode[];
  value?: number;
};

type DeviceGraphCanvasProps = {
  deviceId: string;
  graph: DeviceGraphNeighborhood | null;
  collectorOwnedOnly: boolean;
  includeTopology: boolean;
};

type LayoutMode = "cluster" | "pack";

type ClusterNode = {
  x: number;
  y: number;
  data: GraphNode;
  depth: number;
};

type ClusterLink = {
  source: { x: number; y: number };
  target: { x: number; y: number };
};

type PackCircle = {
  x: number;
  y: number;
  r: number;
  data: GraphNode;
  depth: number;
  isLeaf: boolean;
};

type ClusterLayout = {
  mode: "cluster";
  width: number;
  height: number;
  nodes: ClusterNode[];
  links: ClusterLink[];
  targetCount: number;
  nodeCount: number;
};

type PackLayout = {
  mode: "pack";
  width: number;
  height: number;
  circles: PackCircle[];
  targetCount: number;
  nodeCount: number;
};

type LayoutResult = ClusterLayout | PackLayout | null;

const CANVAS_WIDTH = 1100;
const CANVAS_HEIGHT = 420;
const MARGIN = { top: 24, right: 220, bottom: 24, left: 160 };
const LARGE_TARGET_THRESHOLD = 5000;
const LARGE_NODE_THRESHOLD = 8000;

const kindStyles: Record<GraphNodeKind, { fill: string; stroke: string }> = {
  device: { fill: "#dbeafe", stroke: "#2563eb" },
  collector: { fill: "#f3e8ff", stroke: "#7c3aed" },
  service: { fill: "#d1fae5", stroke: "#059669" },
  interface: { fill: "#fef3c7", stroke: "#d97706" },
  target: { fill: "#e2e8f0", stroke: "#475569" },
};

const safeKind = (kind?: GraphNodeKind): GraphNodeKind =>
  kindStyles[kind ?? "device"] ? (kind as GraphNodeKind) : "device";

const nameForNode = (node?: AgeNode | null): string => {
  const props = node?.properties ?? {};
  const hostname =
    typeof props["hostname"] === "string" ? props["hostname"] : undefined;
  const ip = typeof props["ip"] === "string" ? props["ip"] : undefined;
  return hostname || ip || nodeId(node) || node?.label || "node";
};

const deriveKind = (node?: AgeNode | null): GraphNodeKind => {
  const id = String(nodeId(node) ?? "").toLowerCase();
  const type = String(nodeType(node) ?? "").toLowerCase();
  const label = String(node?.label ?? "").toLowerCase();

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

const cidrBucket = (ipOrLabel?: string): string => {
  if (!ipOrLabel) return "unknown";
  const ipv4 = ipOrLabel.match(
    /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/,
  );
  if (ipv4) {
    const [a, b, c] = ipv4.slice(1).map((p) => Number.parseInt(p, 10));
    if ([a, b, c].every((n) => n >= 0 && n <= 255)) {
      return `${a}.${b}.${c}.0/24`;
    }
  }
  // Fall back to hostname/domain bucketing
  if (ipOrLabel.includes(".")) {
    const parts = ipOrLabel.split(".");
    return parts.slice(-2).join(".") || ipOrLabel;
  }
  return ipOrLabel;
};

const attach = (parent: GraphNode, child: GraphNode) => {
  if (!parent.children) {
    parent.children = [];
  }
  parent.children.push(child);
};

const truncateText = (value: string | undefined, max = 26): string =>
  !value ? "" : value.length > max ? `${value.slice(0, max - 1)}…` : value;

const assignValues = (node: GraphNode): number => {
  if (!node.children || node.children.length === 0) {
    node.value = 1;
    return 1;
  }
  const total = node.children.map(assignValues).reduce((acc, v) => acc + v, 0);
  node.value = Math.max(total, node.children.length);
  return node.value;
};

const countNodes = (node?: GraphNode): number => {
  if (!node) return 0;
  return 1 + (node.children ?? []).reduce((acc, child) => acc + countNodes(child), 0);
};

const buildHierarchy = (
  graph: DeviceGraphNeighborhood,
  deviceId: string,
  collectorOwnedOnly: boolean,
  includeTopology: boolean,
): { root: GraphNode; targetCount: number; nodeCount: number } => {
  const mainNodeId = nodeId(graph.device) || deviceId;
  const mainKind = deriveKind(graph.device);
  const deviceBadges = [
    ...((graph.device_capabilities ?? [])
      .map((cap) => capabilityLabel(cap) || "")
      .filter(Boolean)),
    collectorOwnedOnly ? "collector scope" : "full scope",
  ];

  const root: GraphNode = {
    id: mainNodeId,
    label: nameForNode(graph.device) || mainNodeId,
    subLabel: nodeType(graph.device) || mainNodeId,
    badges: deviceBadges.filter(Boolean),
    href: `/devices/${encodeURIComponent(mainNodeId)}`,
    kind: mainKind,
    children: [],
  };

  const collectorMap = new Map<string, GraphNode>();
  (graph.collectors ?? []).forEach((collector, idx) => {
    const id = nodeId(collector) || `collector-${idx}`;
    if (id === mainNodeId) return;
    const node: GraphNode = {
      id,
      label: nameForNode(collector),
      subLabel: nodeType(collector) || id,
      href: `/devices/${encodeURIComponent(id)}`,
      kind: "collector",
      badges: ["collector"],
      children: [],
    };
    collectorMap.set(id, node);
    attach(root, node);
  });

  const services: GraphNode[] = [];
  const serviceIdMap = new Map<string, GraphNode>();
  (graph.services ?? []).forEach((svc, idx) => {
    const id = nodeId(svc.service) || `service-${idx}`;
    if (id === mainNodeId) return;
    if (serviceIdMap.has(id)) return;

    const badges = [
      nodeType(svc.service) || "service",
      svc.collector_owned ? "collector-owned" : "targeting",
    ].filter(Boolean);

    const svcNode: GraphNode = {
      id,
      label: nameForNode(svc.service),
      subLabel: nodeId(svc.service) || id,
      badges,
      href: `/devices/${encodeURIComponent(id)}`,
      kind: deriveKind(svc.service),
      children: [],
    };
    const host =
      (svc.collector_id && collectorMap.get(svc.collector_id)) ||
      (mainKind === "collector" ? root : null);
    attach(host ?? root, svcNode);
    services.push(svcNode);
    serviceIdMap.set(id, svcNode);
  });

  let targetCount = 0;
  if (!collectorOwnedOnly) {
    const targets = (graph.targets ?? []).map((target, idx) => {
      const id = nodeId(target) || `target-${idx}`;
      return {
        id,
        label: nameForNode(target),
        subLabel: nodeType(target) || id,
        href: `/devices/${encodeURIComponent(id)}`,
        kind: "target" as const,
      };
    });
    targetCount = targets.length;

    targets.forEach((target, idx) => {
      const parent = services[idx % Math.max(services.length, 1)] ?? root;
      attach(parent, target);
    });
  }

  if (includeTopology) {
    const ifaceGroup: GraphNode = {
      id: `${mainNodeId}-interfaces`,
      label: "Interfaces",
      kind: "interface",
      badges: ["topology"],
      children: [],
    };

    (graph.interfaces ?? []).forEach((iface, idx) => {
      const id = nodeId(iface) || `iface-${idx}`;
      attach(ifaceGroup, {
        id,
        label: nameForNode(iface),
        subLabel: nodeType(iface) || id,
        href: `/devices/${encodeURIComponent(id)}`,
        badges: ["interface"],
        kind: "interface",
      });
    });

    (graph.peer_interfaces ?? []).forEach((peer, idx) => {
      const id = nodeId(peer) || `peer-${idx}`;
      attach(ifaceGroup, {
        id,
        label: nameForNode(peer),
        subLabel: nodeType(peer) || id,
        href: `/devices/${encodeURIComponent(id)}`,
        badges: ["peer"],
        kind: "interface",
      });
    });

    if (ifaceGroup.children && ifaceGroup.children.length > 0) {
      attach(root, ifaceGroup);
    }
  }

  assignValues(root);
  const nodeCount = countNodes(root);

  return { root, targetCount, nodeCount };
};

const buildCidrPackRoot = (root: GraphNode): GraphNode => {
  const cidrGroup = new Map<string, GraphNode>();

  const collectTargets = (node: GraphNode): GraphNode[] => {
    const children = node.children ?? [];
    const directTargets = children.filter((child) => child.kind === "target");
    return [
      ...directTargets,
      ...children.flatMap((child) => collectTargets(child)),
    ];
  };

  const cloneWithoutTargets = (node: GraphNode): GraphNode => ({
    ...node,
    children: (node.children ?? [])
      .filter((child) => child.kind !== "target")
      .map(cloneWithoutTargets),
  });

  const targets = collectTargets(root);
  targets.forEach((tgt) => {
    const bucket = cidrBucket(tgt.subLabel || tgt.label);
    const clone: GraphNode = { ...tgt, children: [] };
    const existing = cidrGroup.get(bucket);
    if (existing) {
      attach(existing, clone);
    } else {
      const clusterNode: GraphNode = {
        id: `cidr-${bucket}`,
        label: bucket,
        kind: "target",
        badges: ["cidr"],
        children: [clone],
      };
      cidrGroup.set(bucket, clusterNode);
    }
  });

  const baseTree = cloneWithoutTargets(root);
  const targetsNode: GraphNode = {
    id: "target-clusters",
    label: "Targets by CIDR",
    kind: "target",
    badges: ["clustered"],
    children: Array.from(cidrGroup.values()),
  };

  const packedRoot: GraphNode = {
    ...baseTree,
    children: [...(baseTree.children ?? []), targetsNode],
  };

  assignValues(packedRoot);
  return packedRoot;
};

const DeviceGraphCanvas: React.FC<DeviceGraphCanvasProps> = ({
  deviceId,
  graph,
  collectorOwnedOnly,
  includeTopology,
}) => {
  const layout: LayoutResult = useMemo(() => {
    if (!graph) {
      return null;
    }

    const { root, targetCount, nodeCount } = buildHierarchy(graph, deviceId, collectorOwnedOnly, includeTopology);

    const usePack =
      targetCount >= LARGE_TARGET_THRESHOLD || nodeCount >= LARGE_NODE_THRESHOLD;
    const mode: LayoutMode = usePack ? "pack" : "cluster";

    const width = CANVAS_WIDTH;
    const height = CANVAS_HEIGHT;
    const innerWidth = width - MARGIN.left - MARGIN.right;
    const innerHeight = height - MARGIN.top - MARGIN.bottom;

    if (mode === "pack") {
      const packedRoot = hierarchy(buildCidrPackRoot(root)).sum(
        (d) => d.value ?? 1,
      );
      const packLayout = pack<GraphNode>()
        .size([innerWidth, innerHeight])
        .padding(10);
      const packed = packLayout(packedRoot);
      const circles: PackCircle[] = packed.descendants().map((node) => ({
        x: node.x + MARGIN.left,
        y: node.y + MARGIN.top,
        r: node.r,
        data: node.data,
        depth: node.depth,
        isLeaf: !node.children || node.children.length === 0,
      }));
      return {
        mode,
        width,
        height,
        circles,
        targetCount,
        nodeCount,
      };
    }

    const rootHierarchy = hierarchy(root);
    const clusterLayout = cluster<GraphNode>().size([innerHeight, innerWidth]);
    clusterLayout(rootHierarchy);

    const nodes: ClusterNode[] = rootHierarchy.descendants().map((node) => ({
      x: (node.y ?? 0) + MARGIN.left,
      y: (node.x ?? 0) + MARGIN.top,
      data: node.data,
      depth: node.depth,
    }));

    const links: ClusterLink[] = rootHierarchy.links().map((link) => ({
      source: {
        x: (link.source.y ?? 0) + MARGIN.left,
        y: (link.source.x ?? 0) + MARGIN.top,
      },
      target: {
        x: (link.target.y ?? 0) + MARGIN.left,
        y: (link.target.x ?? 0) + MARGIN.top,
      },
    }));

    return {
      mode,
      width,
      height,
      nodes,
      links,
      targetCount,
      nodeCount,
    };
  }, [collectorOwnedOnly, deviceId, graph, includeTopology]);

  if (!graph) {
    return (
      <div className="flex items-center gap-2 text-sm text-gray-500 dark:text-gray-300">
        Neighborhood graph is not available yet.
      </div>
    );
  }

  if (!layout) {
    return null;
  }

  const modeLabel =
    layout.mode === "pack"
      ? "CIDR-clustered pack layout (large graph)"
      : "Hierarchy dendrogram";

  return (
    <div className="w-full">
      <div className="mb-2 flex items-center justify-between text-xs text-gray-600 dark:text-gray-300">
        <span>
          {modeLabel} • {layout.nodeCount} nodes
          {layout.targetCount ? `, ${layout.targetCount} targets` : ""}
        </span>
        {layout.mode === "pack" && (
          <span className="rounded-full bg-gray-100 px-2 py-0.5 text-[11px] font-semibold uppercase text-gray-700 dark:bg-gray-800 dark:text-gray-200">
            Large neighborhood clustered by CIDR
          </span>
        )}
      </div>
      <svg
        viewBox={`0 0 ${layout.width} ${layout.height}`}
        className="h-[360px] w-full rounded-md border border-gray-200 bg-white text-gray-900 shadow-sm dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
      >
        {layout.mode === "cluster" && (
          <g>
            {layout.links?.map((link: ClusterLink) => {
              const sourceX = link.source?.x ?? 0;
              const sourceY = link.source?.y ?? 0;
              const targetX = link.target?.x ?? 0;
              const targetY = link.target?.y ?? 0;
              return (
              <path
                key={`${sourceX}-${sourceY}-${targetX}-${targetY}`}
                d={`M${sourceX},${sourceY}C${(sourceX + targetX) / 2},${sourceY} ${(sourceX + targetX) / 2},${targetY} ${targetX},${targetY}`}
                fill="none"
                stroke="#cbd5e1"
                strokeWidth={1.4}
              />
              );
            })}
            {layout.nodes?.map((node: ClusterNode) => {
              const nodeX = node.x ?? 0;
              const nodeY = node.y ?? 0;
              const kind = safeKind(node.data.kind);
              const styles = kindStyles[kind];
              const hasHref = Boolean(node.data.href);
              const handleClick = () => {
                if (node.data.href) {
                  window.location.href = node.data.href;
                }
              };
              const radius =
                16 + Math.min(12, (node.data.badges?.length ?? 0) * 1.5);
              const labelX = radius + 14;
              const label = truncateText(node.data.label);
              const subLabel = truncateText(node.data.subLabel, 24);
              const badgeText =
                node.data.badges && node.data.badges.length > 0
                  ? truncateText(node.data.badges.join(" · "), 40)
                  : "";
              return (
                <g
                  key={node.data.id}
                  transform={`translate(${nodeX},${nodeY})`}
                  className={hasHref ? "cursor-pointer" : undefined}
                  onClick={handleClick}
                >
                  <circle
                    r={radius}
                    fill={styles.fill}
                    stroke={styles.stroke}
                    strokeWidth={2}
                  />
                  {badgeText && (
                    <text
                      x={labelX}
                      y={-10}
                      textAnchor="start"
                      fontSize={8}
                      fill="#0f172a"
                      className="dark:fill-gray-100"
                      paintOrder="stroke"
                      stroke="#fff"
                      strokeWidth={2}
                    >
                      {badgeText}
                    </text>
                  )}
                  <text
                    x={labelX}
                    y={-2}
                    textAnchor="start"
                    dominantBaseline="middle"
                    fontSize={11}
                    fontWeight={600}
                    fill="#0f172a"
                    className="dark:fill-white"
                    paintOrder="stroke"
                    stroke="#fff"
                    strokeWidth={2}
                  >
                    {label}
                  </text>
                  {subLabel && (
                    <text
                      x={labelX}
                      y={12}
                      textAnchor="start"
                      dominantBaseline="hanging"
                      fontSize={9}
                      fill="#475569"
                      className="dark:fill-gray-300"
                    >
                      {subLabel}
                    </text>
                  )}
                </g>
              );
            })}
          </g>
        )}

        {layout.mode === "pack" && (
          <g>
            {layout.circles?.map((circle: PackCircle) => {
              const kind = safeKind(circle.data.kind);
              const styles = kindStyles[kind];
              const hasHref = Boolean(circle.data.href);
              const handleClick = () => {
                if (circle.data.href) {
                  window.location.href = circle.data.href;
                }
              };
              return (
                <g
                  key={`${circle.data.id}-${circle.depth}`}
                  transform={`translate(${circle.x},${circle.y})`}
                  className={hasHref ? "cursor-pointer" : undefined}
                  onClick={handleClick}
                >
                  <circle
                    r={circle.r}
                    fill={circle.depth === 0 ? "transparent" : styles.fill}
                    stroke={styles.stroke}
                    strokeWidth={circle.depth === 0 ? 1.2 : 1.6}
                    fillOpacity={circle.depth === 0 ? 0 : 0.9}
                  />
                  {circle.r > 14 && (
                    <text
                      textAnchor="middle"
                      dominantBaseline="middle"
                      fontSize={Math.min(12, Math.max(9, circle.r / 6))}
                      fontWeight={600}
                      fill="#0f172a"
                      className="pointer-events-none dark:fill-white"
                      paintOrder="stroke"
                      stroke="#fff"
                      strokeWidth={2}
                    >
                      {truncateText(circle.data.label, Math.max(10, Math.floor(circle.r / 1.8)))}
                    </text>
                  )}
                  {circle.r > 22 && circle.data.badges && (
                    <text
                      y={14}
                      textAnchor="middle"
                      fontSize={8}
                      fill="#475569"
                      className="pointer-events-none dark:fill-gray-300"
                      paintOrder="stroke"
                      stroke="#fff"
                      strokeWidth={2}
                    >
                      {truncateText(circle.data.badges.join(" · "), Math.max(12, Math.floor(circle.r / 2.2)))}
                    </text>
                  )}
                </g>
              );
            })}
          </g>
        )}
      </svg>
    </div>
  );
};

export default DeviceGraphCanvas;
