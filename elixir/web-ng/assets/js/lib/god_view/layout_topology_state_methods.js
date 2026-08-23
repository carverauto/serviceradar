import ELK from "elkjs/lib/elk.bundled.js"

let defaultLayoutEngine = null
const MAX_LAYOUT_CACHE_ENTRIES = 12
const DEFAULT_NODE_WIDTH = 54
const DEFAULT_NODE_HEIGHT = 54
const LAYOUT_WIDTH = 640
const LAYOUT_HEIGHT = 320
const LAYOUT_PAD = 20
const BACKBONE_LAYER_GAP_X = 180
const BACKBONE_COMPONENT_GAP_Y = 180
const ORGANIC_ROOT_X = 320
const ORGANIC_ROOT_Y = 280
const ORGANIC_DEPTH_RADIUS = 168
const ORGANIC_DEPTH_RADIUS_STEP = 120
const ORGANIC_FULL_SPAN = Math.PI * 1.7
const BACKBONE_NODE_MIN_DISTANCE = 120
const UNPLACED_LANE_X_OFFSET = 220
const UNPLACED_LANE_GAP_Y = 92
const HOSTED_ISLAND_X_OFFSET = 300
const HOSTED_ISLAND_GAP_Y = 220
const HOSTED_ISLAND_GUEST_RING_RADIUS = 118
const HOSTED_ISLAND_GUEST_RING_STEP = 78
const HOSTED_ISLAND_GUESTS_PER_RING = 12
const ATTACHMENT_SATELLITE_RING_RADIUS = 118
const ATTACHMENT_SATELLITE_RING_STEP = 78
const ATTACHMENT_SATELLITES_PER_RING = 12
const EXPANDED_CLUSTER_SPIRAL_SPACING = 56
const EXPANDED_CLUSTER_SPIRAL_MIN_RADIUS = 96
const EXPANDED_CLUSTER_GOLDEN_ANGLE = 2.399963229728653
const EXPANDED_CLUSTER_NODE_CLEARANCE = 120

const ELK_ROOT_OPTIONS = {
  "elk.algorithm": "layered",
  "elk.direction": "DOWN",
  "elk.edgeRouting": "POLYLINE",
  "elk.layered.crossingMinimization.strategy": "LAYER_SWEEP",
  "elk.layered.considerModelOrder.strategy": "PREFER_NODES",
  "elk.layered.considerModelOrder.crossingCounterNodeInfluence": "0.001",
  "elk.layered.nodePlacement.strategy": "NETWORK_SIMPLEX",
  "elk.layered.nodePlacement.favorStraightEdges": "true",
  "elk.layered.nodePlacement.bk.edgeStraightening": "IMPROVE_STRAIGHTNESS",
  "elk.layered.nodePlacement.bk.fixedAlignment": "BALANCED",
  "elk.layered.spacing.nodeNodeBetweenLayers": "120",
  "elk.spacing.nodeNode": "64",
  "elk.spacing.edgeNode": "48",
  "elk.padding": "[top=48,left=48,bottom=48,right=48]",
}

function getDefaultLayoutEngine() {
  if (!defaultLayoutEngine) defaultLayoutEngine = new ELK()
  return defaultLayoutEngine
}

function projectMercator(lat, lon) {
  const clampedLat = Math.max(-85, Math.min(85, lat))
  const x = ((lon + 180) / 360) * (LAYOUT_WIDTH - LAYOUT_PAD * 2) + LAYOUT_PAD
  const rad = clampedLat * (Math.PI / 180)
  const mercY = (1 - Math.log(Math.tan(Math.PI / 4 + rad / 2)) / Math.PI) / 2
  const y = mercY * (LAYOUT_HEIGHT - LAYOUT_PAD * 2) + LAYOUT_PAD
  return [x, y]
}

function graphNodeId(node, fallbackIndex) {
  const id = typeof node?.id === "string" && node.id.trim() !== "" ? node.id.trim() : `node-${fallbackIndex + 1}`
  return id
}

function hashStringToSeed(value) {
  const text = String(value || "")
  let hash = 0
  for (let index = 0; index < text.length; index += 1) {
    hash = ((hash << 5) - hash + text.charCodeAt(index)) | 0
  }
  return hash
}

function graphNodeDetails(node) {
  return node?.details && typeof node.details === "object" ? node.details : {}
}

function clusterIdForNode(node) {
  const clusterId = graphNodeDetails(node).cluster_id
  return typeof clusterId === "string" && clusterId.trim() !== "" ? clusterId.trim() : null
}

function clusterKindForNode(node) {
  const clusterKind = graphNodeDetails(node).cluster_kind
  return typeof clusterKind === "string" && clusterKind.trim() !== "" ? clusterKind.trim() : ""
}

function isClusterExpandedFlag(value) {
  return value === true || value === "true" || value === 1
}

function isExpandedClusterNode(node) {
  return isClusterExpandedFlag(graphNodeDetails(node).cluster_expanded)
}

function isEndpointSummaryNode(node) {
  return clusterKindForNode(node) === "endpoint-summary"
}

function isEndpointMemberNode(node) {
  return clusterKindForNode(node) === "endpoint-member"
}

function isEndpointAnchorNode(node) {
  return clusterKindForNode(node) === "endpoint-anchor"
}

function isUnplacedNode(node) {
  const details = graphNodeDetails(node)
  return details.topology_unplaced === true || String(details.topology_plane || "").trim() === "unplaced"
}

function isHypervisorNode(node) {
  const details = graphNodeDetails(node)
  const tokens = [
    node?.type,
    details.type,
    details.device_type,
    details.type_name,
    details.device_role,
    details.hypervisor_provider,
  ]
    .map((value) => String(value || "").trim().toLowerCase())
    .filter((value) => value !== "")

  return tokens.some((value) => value === "hypervisor" || value === "virtualization_host" || value === "proxmox")
}

function isHostedTopologyEdge(edge) {
  const topologyClass = String(edge?.topologyClass || "").trim().toLowerCase()
  const evidenceClass = String(edge?.evidenceClass || "").trim().toLowerCase()
  const relationType = String(edge?.metadata?.relation_type || edge?.relationType || "").trim().toUpperCase()
  const topologyPlane = String(edge?.metadata?.topology_plane || "").trim().toLowerCase()

  return (
    topologyClass === "hosted" ||
    evidenceClass === "hosted" ||
    evidenceClass === "hosted-virtual" ||
    relationType === "HOSTED_ON" ||
    topologyPlane === "hosted"
  )
}

function nodeLayoutSize(node) {
  const details = graphNodeDetails(node)
  const clusterCount = Math.max(1, Number(node?.clusterCount || details.cluster_member_count || 1))
  const clusterKind = clusterKindForNode(node)

  if (clusterKind === "endpoint-summary") {
    const size = 72 + Math.min(72, Math.sqrt(clusterCount) * 8)
    return {width: size, height: size}
  }

  if (clusterKind === "endpoint-anchor") {
    return {width: 60, height: 60}
  }

  if (clusterKind === "endpoint-member") {
    return {width: 26, height: 26}
  }

  return {width: DEFAULT_NODE_WIDTH, height: DEFAULT_NODE_HEIGHT}
}

function mergeNodeDetails(existing, incoming) {
  return {
    ...existing,
    ...incoming,
    cluster_expanded:
      isClusterExpandedFlag(existing?.cluster_expanded) || isClusterExpandedFlag(incoming?.cluster_expanded),
  }
}

function mergeGraphNodes(existing, incoming) {
  const existingDetails = graphNodeDetails(existing)
  const incomingDetails = graphNodeDetails(incoming)
  const nextX = Number(existing?.x)
  const nextY = Number(existing?.y)
  const incomingX = Number(incoming?.x)
  const incomingY = Number(incoming?.y)

  return {
    ...existing,
    ...incoming,
    x: Number.isFinite(nextX) ? nextX : (Number.isFinite(incomingX) ? incomingX : 0),
    y: Number.isFinite(nextY) ? nextY : (Number.isFinite(incomingY) ? incomingY : 0),
    label:
      typeof existing?.label === "string" && existing.label.trim() !== ""
        ? existing.label
        : incoming?.label,
    clusterCount: Math.max(
      1,
      Number(existing?.clusterCount || 1),
      Number(incoming?.clusterCount || 1),
    ),
    pps: Math.max(Number(existing?.pps || 0), Number(incoming?.pps || 0)),
    operUp: Number(existing?.operUp || 0) || Number(incoming?.operUp || 0),
    details: mergeNodeDetails(existingDetails, incomingDetails),
  }
}

function collectElkPositions(node, out, offsetX = 0, offsetY = 0) {
  if (!node || typeof node !== "object") return out

  if (typeof node.id === "string" && Number.isFinite(node.x) && Number.isFinite(node.y)) {
    out.set(node.id, {x: offsetX + Number(node.x), y: offsetY + Number(node.y)})
  }

  const nextOffsetX = offsetX + Number(node.x || 0)
  const nextOffsetY = offsetY + Number(node.y || 0)
  const children = Array.isArray(node.children) ? node.children : []

  for (const child of children) collectElkPositions(child, out, nextOffsetX, nextOffsetY)
  return out
}

function rotatePoint(x, y, angle) {
  const cos = Math.cos(angle)
  const sin = Math.sin(angle)
  return {
    x: x * cos - y * sin,
    y: x * sin + y * cos,
  }
}

function edgeNodeId(graph, edge, side) {
  const nodeIndex = Number(edge?.[side])
  if (!Number.isInteger(nodeIndex) || nodeIndex < 0 || nodeIndex >= (graph?.nodes || []).length) return null
  return graphNodeId(graph.nodes[nodeIndex], nodeIndex)
}

export const godViewLayoutTopologyStateMethods = {
  geoGridData() {
    if (this.state.layoutMode !== "geo") return []

    const lines = []

    for (let lon = -150; lon <= 150; lon += 30) {
      for (let lat = -80; lat < 80; lat += 10) {
        const [sx, sy] = projectMercator(lat, lon)
        const [tx, ty] = projectMercator(lat + 10, lon)
        lines.push({sourcePosition: [sx, sy, 0], targetPosition: [tx, ty, 0]})
      }
    }

    for (let lat = -60; lat <= 60; lat += 20) {
      for (let lon = -180; lon < 180; lon += 15) {
        const [sx, sy] = projectMercator(lat, lon)
        const [tx, ty] = projectMercator(lat, lon + 15)
        lines.push({sourcePosition: [sx, sy, 0], targetPosition: [tx, ty, 0]})
      }
    }

    return lines
  },
  async prepareGraphLayout(graph, revision, topologyStamp) {
    const {state} = this
    if (!graph || !Array.isArray(graph.nodes) || !Array.isArray(graph.edges)) return graph

    const deduped = this.dedupeGraphById(graph)
    const layoutKey = this.graphLayoutCacheKey(deduped, revision, topologyStamp)
    const cached = this.getCachedGraphLayout(layoutKey)

    if (cached) {
      state.layoutMode = cached._layoutMode || "elk-client"
      state.layoutRevision = revision
      state.lastLayoutKey = layoutKey
      return cached
    }

    const laidOut = await this.computeClientTopologyLayout(deduped, layoutKey)
    const finalGraph = {
      ...laidOut,
      _layoutMode: laidOut?._layoutMode || "elk-client",
      _layoutRevision: revision,
      _layoutCacheKey: layoutKey,
    }

    this.storeCachedGraphLayout(layoutKey, finalGraph)
    state.layoutMode = finalGraph._layoutMode
    state.layoutRevision = revision
    state.lastLayoutKey = layoutKey
    return finalGraph
  },
  graphLayoutCacheKey(graph, revision, topologyStamp) {
    const revisionToken = Number.isFinite(revision) ? revision : "na"
    const expansionStamp = this.graphExpansionStamp(graph)
    return `${revisionToken}:${topologyStamp}:${expansionStamp}`
  },
  graphExpansionStamp(graph) {
    if (!graph || !Array.isArray(graph.nodes)) return "collapsed"
    const expanded = new Set()

    for (const node of graph.nodes) {
      const clusterId = clusterIdForNode(node)
      if (clusterId && isExpandedClusterNode(node)) expanded.add(clusterId)
    }

    const ordered = Array.from(expanded).sort()
    return ordered.length > 0 ? ordered.join("|") : "collapsed"
  },
  getCachedGraphLayout(layoutKey) {
    const cache = this.state.layoutCache
    if (!(cache instanceof Map)) return null
    return cache.get(layoutKey) || null
  },
  storeCachedGraphLayout(layoutKey, graph) {
    const {state} = this
    if (!(state.layoutCache instanceof Map)) state.layoutCache = new Map()
    state.layoutCache.set(layoutKey, graph)

    while (state.layoutCache.size > MAX_LAYOUT_CACHE_ENTRIES) {
      const firstKey = state.layoutCache.keys().next().value
      state.layoutCache.delete(firstKey)
    }
  },
  async computeClientTopologyLayout(graph, layoutKey) {
    const previousGraph = this.state.lastGraph
    const clusterLayout = this.collectEndpointProjectionGroups(graph)
    const excludedNodeIds =
      clusterLayout?.excludedNodeIds instanceof Set ? clusterLayout.excludedNodeIds : new Set()
    const layeredPositions = this.computeBackboneLayeredPositions(graph, excludedNodeIds)

    if (layeredPositions instanceof Map && layeredPositions.size > 0) {
      const withBackbone = this.applyPositionMap(graph, layeredPositions)
      const projected = this.applyEndpointProjectionLayout(withBackbone, clusterLayout)
      const normalized = this.normalizeHorizontalLayout(projected)
      return {
        ...normalized,
        _layoutMode: "client-radial",
        _layoutCacheKey: layoutKey,
      }
    }

    const layoutGraph = this.buildElkLayoutGraph(graph, excludedNodeIds)

    try {
      const engine = this.state.layoutEngine || getDefaultLayoutEngine()
      const elkResult = await engine.layout(layoutGraph)
      const withBackbone = this.applyElkNodePositions(graph, elkResult)
      const projected = this.applyEndpointProjectionLayout(withBackbone, clusterLayout)
      const normalized = this.normalizeHorizontalLayout(projected)
      return {
        ...normalized,
        _layoutMode: "elk-client-fallback",
        _layoutCacheKey: layoutKey,
      }
    } catch (_error) {
      const fallback = previousGraph ? this.reusePreviousPositions(graph, previousGraph) : graph
      return {
        ...fallback,
        _layoutMode: "client-fallback",
        _layoutCacheKey: layoutKey,
      }
    }
  },
  requiresFullElkLayout(_graph) {
    return false
  },
  dedupeGraphById(graph) {
    if (!graph || !Array.isArray(graph.nodes) || !Array.isArray(graph.edges)) return graph

    const nodes = []
    const nodeIndexById = new Map()
    const originalToDeduped = new Array(graph.nodes.length)

    for (let index = 0; index < graph.nodes.length; index += 1) {
      const node = graph.nodes[index]
      const id = graphNodeId(node, index)
      const normalized = {...node, id}

      if (nodeIndexById.has(id)) {
        const dedupedIndex = nodeIndexById.get(id)
        nodes[dedupedIndex] = mergeGraphNodes(nodes[dedupedIndex], normalized)
        originalToDeduped[index] = dedupedIndex
        continue
      }

      const dedupedIndex = nodes.length
      nodeIndexById.set(id, dedupedIndex)
      originalToDeduped[index] = dedupedIndex
      nodes.push(normalized)
    }

    const edges = []
    const seenEdgeKeys = new Set()

    for (const edge of graph.edges) {
      const source = originalToDeduped[Number(edge?.source)]
      const target = originalToDeduped[Number(edge?.target)]
      if (!Number.isInteger(source) || !Number.isInteger(target) || source === target) continue

      const dedupedEdge = {...edge, source, target}
      const edgeKey = [
        source,
        target,
        String(edge?.topologyClass || ""),
        String(edge?.label || ""),
        String(edge?.protocol || ""),
        String(edge?.evidenceClass || ""),
      ].join("|")

      if (seenEdgeKeys.has(edgeKey)) continue
      seenEdgeKeys.add(edgeKey)
      edges.push(dedupedEdge)
    }

    return {
      ...graph,
      nodes,
      edges,
      edgeSourceIndex: Uint32Array.from(edges.map((edge) => edge.source)),
      edgeTargetIndex: Uint32Array.from(edges.map((edge) => edge.target)),
    }
  },
  collectEndpointProjectionGroups(graph) {
    const clusters = new Map()
    const excludedNodeIds = new Set()

    for (let index = 0; index < graph.nodes.length; index += 1) {
      const node = graph.nodes[index]
      const clusterId = clusterIdForNode(node)
      if (!clusterId) continue

      const current = clusters.get(clusterId) || {
        clusterId,
        anchorNodeId: null,
        summaryNodeId: null,
        memberNodeIds: [],
        parentNodeId: null,
        expanded: false,
        slotIndex: 0,
        slotCount: 1,
      }

      if (isEndpointAnchorNode(node)) current.anchorNodeId = graphNodeId(node, index)
      if (isEndpointSummaryNode(node)) {
        current.summaryNodeId = graphNodeId(node, index)
        excludedNodeIds.add(current.summaryNodeId)
      }
      if (isEndpointMemberNode(node)) {
        const memberId = graphNodeId(node, index)
        current.memberNodeIds.push(memberId)
        excludedNodeIds.add(memberId)
      }
      current.expanded = current.expanded || isExpandedClusterNode(node)

      clusters.set(clusterId, current)
    }

    for (const edge of graph.edges) {
      const sourceId = edgeNodeId(graph, edge, "source")
      const targetId = edgeNodeId(graph, edge, "target")
      if (!sourceId || !targetId) continue
      if (String(edge?.evidenceClass || "") === "endpoint-attachment") continue

      for (const cluster of clusters.values()) {
        if (!cluster.anchorNodeId || cluster.parentNodeId) continue
        const memberIds = new Set(cluster.memberNodeIds)

        if (
          sourceId === cluster.anchorNodeId &&
          targetId !== cluster.summaryNodeId &&
          !memberIds.has(targetId)
        ) {
          cluster.parentNodeId = targetId
        } else if (
          targetId === cluster.anchorNodeId &&
          sourceId !== cluster.summaryNodeId &&
          !memberIds.has(sourceId)
        ) {
          cluster.parentNodeId = sourceId
        }
      }
    }

    for (const cluster of clusters.values()) {
      cluster.memberNodeIds = Array.from(new Set(cluster.memberNodeIds)).sort()
    }

    const groups = Array.from(clusters.values()).filter(
      (cluster) => cluster.anchorNodeId && cluster.summaryNodeId,
    )

    const groupsByAnchor = new Map()

    for (const group of groups) {
      const grouped = groupsByAnchor.get(group.anchorNodeId) || []
      grouped.push(group)
      groupsByAnchor.set(group.anchorNodeId, grouped)
    }

    for (const grouped of groupsByAnchor.values()) {
      grouped.sort((left, right) => String(left.clusterId).localeCompare(String(right.clusterId)))
      for (let index = 0; index < grouped.length; index += 1) {
        grouped[index].slotIndex = index
        grouped[index].slotCount = grouped.length
      }
    }

    return {
      groups,
      excludedNodeIds,
    }
  },
  buildElkLayoutGraph(graph, excludedNodeIds = new Set(), options = {}) {
    const includeAttachmentEdges = options?.includeAttachmentEdges === true
    const children = []
    const includedIds = new Set()

    for (let index = 0; index < graph.nodes.length; index += 1) {
      const node = graph.nodes[index]
      const nodeId = graphNodeId(node, index)
      if (excludedNodeIds.has(nodeId)) continue

      const {width, height} = nodeLayoutSize(node)
      children.push({
        id: nodeId,
        width,
        height,
      })
      includedIds.add(nodeId)
    }

    children.sort((left, right) => String(left.id).localeCompare(String(right.id)))

    const edges = []

    for (let index = 0; index < graph.edges.length; index += 1) {
      const edge = graph.edges[index]
      const sourceId = edgeNodeId(graph, edge, "source")
      const targetId = edgeNodeId(graph, edge, "target")
      if (!sourceId || !targetId) continue
      if (!includedIds.has(sourceId) || !includedIds.has(targetId)) continue
      if (!includeAttachmentEdges && String(edge?.evidenceClass || "") === "endpoint-attachment") continue

      edges.push({
        id: `edge-${index}`,
        sources: [sourceId],
        targets: [targetId],
      })
    }

    edges.sort((left, right) => {
      const leftKey = `${left.sources[0] || ""}|${left.targets[0] || ""}|${left.id || ""}`
      const rightKey = `${right.sources[0] || ""}|${right.targets[0] || ""}|${right.id || ""}`
      return leftKey.localeCompare(rightKey)
    })

    return {
      id: "god-view-root",
      layoutOptions: ELK_ROOT_OPTIONS,
      children,
      edges,
    }
  },
  computeBackboneLayeredPositions(graph, excludedNodeIds) {
    const hostedLayoutNodeIds = this.hostedLayoutNodeIds(graph, excludedNodeIds)
    const backbone = this.buildBackboneAdjacency(graph, excludedNodeIds)
    const unplacedNodes = Array.isArray(graph?.nodes)
      ? graph.nodes
          .map((node, index) => ({id: graphNodeId(node, index), node}))
          .filter(({id, node}) => !excludedNodeIds.has(id) && !hostedLayoutNodeIds.has(id) && isUnplacedNode(node))
      : []
    const residualNodes = Array.isArray(graph?.nodes)
      ? graph.nodes
          .map((node, index) => ({id: graphNodeId(node, index), node}))
          .filter(({id, node}) => {
            if (excludedNodeIds.has(id) || isUnplacedNode(node)) return false
            if (hostedLayoutNodeIds.has(id)) return false
            return !backbone.nodeIds.includes(id)
          })
      : []

    if ((!backbone || backbone.nodeIds.length === 0) && unplacedNodes.length === 0 && residualNodes.length === 0) {
      return null
    }

    const components = this.connectedBackboneComponents(backbone.nodeIds, backbone.adjacency)
    const positions = new Map()
    let componentOffsetY = 0

    for (const componentIds of components) {
      const rootId = this.selectBackboneRoot(componentIds, backbone)
      if (!rootId) continue

      const tree = this.buildBackboneTree(rootId, componentIds, backbone)
      const subtreeWeights = this.backboneSubtreeWeights(rootId, tree.childrenById)
      const depthById = this.backboneDepthsFromRoot(rootId, tree.childrenById)
      const radiiByDepth = this.backboneRadiiByDepth(depthById)
      let componentPositions = new Map()

      const assignFrame = {
        x: ORGANIC_ROOT_X,
        y: ORGANIC_ROOT_Y + componentOffsetY,
        startAngle: -(ORGANIC_FULL_SPAN / 2),
        endAngle: ORGANIC_FULL_SPAN / 2,
        depth: 0,
      }

      this.assignOrganicBackbonePositions(
        rootId,
        tree.childrenById,
        subtreeWeights,
        depthById,
        radiiByDepth,
        componentPositions,
        assignFrame,
      )

      const orderedChildrenById = this.applyBarycenterChildOrder(
        tree.childrenById,
        backbone.adjacency,
        componentPositions,
      )

      if (orderedChildrenById) {
        componentPositions = new Map()
        this.assignOrganicBackbonePositions(
          rootId,
          orderedChildrenById,
          subtreeWeights,
          depthById,
          radiiByDepth,
          componentPositions,
          assignFrame,
        )
      }

      for (const [nodeId, point] of componentPositions.entries()) positions.set(nodeId, point)

      const componentYs = Array.from(componentPositions.values()).map((point) => Number(point.y || 0))
      const componentHeight =
        componentYs.length > 0
          ? Math.max(...componentYs) - Math.min(...componentYs) + BACKBONE_COMPONENT_GAP_Y
          : BACKBONE_COMPONENT_GAP_Y

      componentOffsetY += componentHeight
    }

    const hostedIslands = this.collectHostedTopologyIslands(graph, excludedNodeIds)
    if (hostedIslands.length > 0) {
      const placedBeforeHosted = Array.from(positions.values())
      const hostedAnchorX = placedBeforeHosted.length > 0
        ? Math.max(...placedBeforeHosted.map((point) => Number(point.x || 0))) + HOSTED_ISLAND_X_OFFSET
        : ORGANIC_ROOT_X
      let hostedCursorY = placedBeforeHosted.length > 0
        ? Math.min(...placedBeforeHosted.map((point) => Number(point.y || 0)))
        : ORGANIC_ROOT_Y

      for (const island of hostedIslands) {
        const rootedInBackbone = positions.get(island.rootId)
        const islandPositions = this.hostedIslandPositions(
          island,
          rootedInBackbone?.x ?? hostedAnchorX,
          rootedInBackbone?.y ?? hostedCursorY,
        )
        const islandPoints = Array.from(islandPositions.values())

        for (const [nodeId, point] of islandPositions.entries()) {
          if (!positions.has(nodeId) || hostedLayoutNodeIds.has(nodeId)) positions.set(nodeId, point)
        }

        if (!rootedInBackbone && islandPoints.length > 0) {
          const minY = Math.min(...islandPoints.map((point) => Number(point.y || 0)))
          const maxY = Math.max(...islandPoints.map((point) => Number(point.y || 0)))
          hostedCursorY += Math.max(maxY - minY, HOSTED_ISLAND_GUEST_RING_RADIUS * 2) + HOSTED_ISLAND_GAP_Y
        } else {
          hostedCursorY += HOSTED_ISLAND_GAP_Y
        }
      }
    }

    const placedPoints = Array.from(positions.values())
    const laneAnchorX = placedPoints.length > 0
      ? Math.max(...placedPoints.map((point) => Number(point.x || 0))) + UNPLACED_LANE_X_OFFSET
      : 120
    let laneCursorY = placedPoints.length > 0
      ? Math.min(...placedPoints.map((point) => Number(point.y || 0)))
      : 220

    if (unplacedNodes.length > 0) {
      const orderedUnplaced = [...unplacedNodes].sort((left, right) => {
        const leftLabel = String(left.node?.label || left.id || "")
        const rightLabel = String(right.node?.label || right.id || "")
        const leftPps = Number(left.node?.pps || 0)
        const rightPps = Number(right.node?.pps || 0)
        return rightPps - leftPps || leftLabel.localeCompare(rightLabel) || left.id.localeCompare(right.id)
      })

      for (let index = 0; index < orderedUnplaced.length; index += 1) {
        const column = Math.floor(index / 8)
        const row = index % 8
        positions.set(orderedUnplaced[index].id, {
          x: laneAnchorX + column * Math.round(BACKBONE_LAYER_GAP_X * 0.9),
          y: laneCursorY + row * UNPLACED_LANE_GAP_Y,
        })
      }

      laneCursorY += Math.ceil(orderedUnplaced.length / 8) * UNPLACED_LANE_GAP_Y + 44
    }

    if (residualNodes.length > 0) {
      const residualIds = new Set(residualNodes.map(({id}) => id))
      const satellitePlacements = this.attachmentSatellitePlacements(graph, positions, residualIds)

      const leftoverResidual = []

      for (const residual of residualNodes) {
        const satellitePoint = satellitePlacements.get(residual.id)

        if (satellitePoint) {
          positions.set(residual.id, satellitePoint)
        } else {
          leftoverResidual.push(residual)
        }
      }

      const orderedResidual = [...leftoverResidual].sort((left, right) => {
        const leftLabel = String(left.node?.label || left.id || "")
        const rightLabel = String(right.node?.label || right.id || "")
        const leftPps = Number(left.node?.pps || 0)
        const rightPps = Number(right.node?.pps || 0)
        return rightPps - leftPps || leftLabel.localeCompare(rightLabel) || left.id.localeCompare(right.id)
      })

      for (let index = 0; index < orderedResidual.length; index += 1) {
        const column = Math.floor(index / 8)
        const row = index % 8
        positions.set(orderedResidual[index].id, {
          x: laneAnchorX + column * Math.round(BACKBONE_LAYER_GAP_X * 0.9),
          y: laneCursorY + row * UNPLACED_LANE_GAP_Y,
        })
      }
    }

    return positions
  },
  hostedLayoutNodeIds(graph, excludedNodeIds = new Set()) {
    const ids = new Set()
    if (!graph || !Array.isArray(graph.nodes) || !Array.isArray(graph.edges)) return ids

    const nodeById = new Map()
    const backboneAttachedNodeIds = new Set()
    for (let index = 0; index < graph.nodes.length; index += 1) {
      const node = graph.nodes[index]
      nodeById.set(graphNodeId(node, index), node)
    }

    for (const edge of graph.edges) {
      if (!this.edgeDrivesBackboneLayout(edge)) continue
      const sourceId = edgeNodeId(graph, edge, "source")
      const targetId = edgeNodeId(graph, edge, "target")
      if (sourceId) backboneAttachedNodeIds.add(sourceId)
      if (targetId) backboneAttachedNodeIds.add(targetId)
    }

    for (const edge of graph.edges) {
      if (!isHostedTopologyEdge(edge)) continue
      const sourceId = edgeNodeId(graph, edge, "source")
      const targetId = edgeNodeId(graph, edge, "target")
      if (!sourceId || !targetId) continue
      const sourceHypervisor = isHypervisorNode(nodeById.get(sourceId))
      const targetHypervisor = isHypervisorNode(nodeById.get(targetId))
      if (sourceHypervisor && targetHypervisor) continue

      for (const nodeId of [sourceId, targetId]) {
        if (excludedNodeIds.has(nodeId)) continue
        if (backboneAttachedNodeIds.has(nodeId)) continue
        const node = nodeById.get(nodeId)
        if (isUnplacedNode(node)) continue
        ids.add(nodeId)
      }
    }

    return ids
  },
  collectHostedTopologyIslands(graph, excludedNodeIds = new Set()) {
    if (!graph || !Array.isArray(graph.nodes) || !Array.isArray(graph.edges)) return []

    const nodeById = new Map()
    const rootGroups = new Map()
    const fallbackAdjacency = new Map()
    const hostedLayoutNodeIds = this.hostedLayoutNodeIds(graph, excludedNodeIds)

    for (let index = 0; index < graph.nodes.length; index += 1) {
      const node = graph.nodes[index]
      const nodeId = graphNodeId(node, index)
      if (excludedNodeIds.has(nodeId) || isUnplacedNode(node)) continue
      nodeById.set(nodeId, node)
    }

    for (const edge of graph.edges) {
      if (!isHostedTopologyEdge(edge)) continue
      const sourceId = edgeNodeId(graph, edge, "source")
      const targetId = edgeNodeId(graph, edge, "target")
      if (!sourceId || !targetId || sourceId === targetId) continue
      if (!nodeById.has(sourceId) || !nodeById.has(targetId)) continue
      if (!hostedLayoutNodeIds.has(sourceId) && !hostedLayoutNodeIds.has(targetId)) continue

      const sourceHypervisor = isHypervisorNode(nodeById.get(sourceId))
      const targetHypervisor = isHypervisorNode(nodeById.get(targetId))

      if (sourceHypervisor && targetHypervisor) continue

      if (sourceHypervisor || targetHypervisor) {
        const rootId = sourceHypervisor ? sourceId : targetId
        const childId = sourceHypervisor ? targetId : sourceId
        const group = rootGroups.get(rootId) || new Set([rootId])
        group.add(childId)
        rootGroups.set(rootId, group)
        continue
      }

      if (!fallbackAdjacency.has(sourceId)) fallbackAdjacency.set(sourceId, new Set())
      if (!fallbackAdjacency.has(targetId)) fallbackAdjacency.set(targetId, new Set())
      fallbackAdjacency.get(sourceId).add(targetId)
      fallbackAdjacency.get(targetId).add(sourceId)
    }

    const visited = new Set()
    const islands = Array.from(rootGroups.entries()).map(([rootId, group]) => ({
      rootId,
      nodeIds: this.sortedHostedIslandNodeIds(Array.from(group), rootId, nodeById),
      nodeById,
    }))

    for (const nodeId of Array.from(fallbackAdjacency.keys()).sort()) {
      if (visited.has(nodeId)) continue
      const queue = [nodeId]
      const nodeIds = []
      visited.add(nodeId)

      while (queue.length > 0) {
        const current = queue.shift()
        nodeIds.push(current)

        for (const neighbor of fallbackAdjacency.get(current) || []) {
          if (visited.has(neighbor)) continue
          visited.add(neighbor)
          queue.push(neighbor)
        }
      }

      const rootId = [...nodeIds].sort((leftId, rightId) => {
        const leftNode = nodeById.get(leftId) || {}
        const rightNode = nodeById.get(rightId) || {}
        const leftDegree = Number((fallbackAdjacency.get(leftId) || new Set()).size)
        const rightDegree = Number((fallbackAdjacency.get(rightId) || new Set()).size)

        return (
          Number(isHypervisorNode(rightNode)) - Number(isHypervisorNode(leftNode)) ||
          rightDegree - leftDegree ||
          String(leftNode?.label || leftId).localeCompare(String(rightNode?.label || rightId)) ||
          leftId.localeCompare(rightId)
        )
      })[0] || nodeId

      islands.push({
        rootId,
        nodeIds: this.sortedHostedIslandNodeIds(nodeIds, rootId, nodeById),
        nodeById,
      })
    }

    return islands.sort((left, right) => {
      const leftNode = left.nodeById.get(left.rootId) || {}
      const rightNode = right.nodeById.get(right.rootId) || {}
      return (
        String(leftNode?.label || left.rootId).localeCompare(String(rightNode?.label || right.rootId)) ||
        left.rootId.localeCompare(right.rootId)
      )
    })
  },
  sortedHostedIslandNodeIds(nodeIds, rootId, nodeById) {
    return nodeIds.sort((leftId, rightId) => {
      if (leftId === rootId) return -1
      if (rightId === rootId) return 1
      const leftNode = nodeById.get(leftId) || {}
      const rightNode = nodeById.get(rightId) || {}
      return (
        String(leftNode?.label || leftId).localeCompare(String(rightNode?.label || rightId)) ||
        leftId.localeCompare(rightId)
      )
    })
  },
  hostedIslandPositions(island, anchorX, anchorY) {
    const positions = new Map()
    const rootId = island?.rootId
    const nodeIds = Array.isArray(island?.nodeIds) ? island.nodeIds : []
    if (!rootId || nodeIds.length === 0) return positions

    positions.set(rootId, {x: anchorX, y: anchorY})

    const guests = nodeIds.filter((nodeId) => nodeId !== rootId)

    for (let index = 0; index < guests.length; index += 1) {
      const ring = Math.floor(index / HOSTED_ISLAND_GUESTS_PER_RING)
      const ringStart = ring * HOSTED_ISLAND_GUESTS_PER_RING
      const ringCount = Math.min(HOSTED_ISLAND_GUESTS_PER_RING, guests.length - ringStart)
      const ringIndex = index - ringStart
      const radius = HOSTED_ISLAND_GUEST_RING_RADIUS + ring * HOSTED_ISLAND_GUEST_RING_STEP
      const angle = -Math.PI / 2 + (Math.PI * 2 * ringIndex) / Math.max(1, ringCount)

      positions.set(guests[index], {
        x: anchorX + Math.cos(angle) * radius,
        y: anchorY + Math.sin(angle) * radius,
      })
    }

    return positions
  },
  backboneDepthsFromRoot(rootId, childrenById) {
    const depthById = new Map([[rootId, 0]])
    const queue = [rootId]

    while (queue.length > 0) {
      const nodeId = queue.shift()
      const depth = Number(depthById.get(nodeId) || 0)

      for (const childId of childrenById.get(nodeId) || []) {
        depthById.set(childId, depth + 1)
        queue.push(childId)
      }
    }

    return depthById
  },
  backboneRadiiByDepth(depthById) {
    const counts = new Map()

    for (const depth of depthById.values()) {
      if (!Number.isInteger(depth) || depth <= 0) continue
      counts.set(depth, Number(counts.get(depth) || 0) + 1)
    }

    const radiiByDepth = new Map([[0, 0]])

    for (const [depth, count] of Array.from(counts.entries()).sort((left, right) => left[0] - right[0])) {
      const minimumRadius = (Math.max(1, count) * BACKBONE_NODE_MIN_DISTANCE) / Math.max(ORGANIC_FULL_SPAN, Math.PI)
      radiiByDepth.set(
        depth,
        Math.max(
          ORGANIC_DEPTH_RADIUS + ((depth - 1) * ORGANIC_DEPTH_RADIUS_STEP),
          minimumRadius,
        ),
      )
    }

    return radiiByDepth
  },
  buildBackboneTree(rootId, componentIds, backbone) {
    const componentSet = new Set(componentIds)
    const visited = new Set([rootId])
    const queue = [rootId]
    const childrenById = new Map()

    for (const nodeId of componentIds) childrenById.set(nodeId, [])

    while (queue.length > 0) {
      const current = queue.shift()
      const neighbors = [...(backbone.adjacency.get(current) || [])]
        .filter((neighbor) => componentSet.has(neighbor))
        .sort((leftId, rightId) => {
          const leftNode = backbone.nodeById.get(leftId) || {}
          const rightNode = backbone.nodeById.get(rightId) || {}
          const leftDegree = (backbone.adjacency.get(leftId) || new Set()).size
          const rightDegree = (backbone.adjacency.get(rightId) || new Set()).size
          const leftPps = Number(leftNode?.pps || 0)
          const rightPps = Number(rightNode?.pps || 0)
          return (
            rightDegree - leftDegree ||
            rightPps - leftPps ||
            String(leftNode?.label || leftId).localeCompare(String(rightNode?.label || rightId)) ||
            leftId.localeCompare(rightId)
          )
        })

      for (const neighbor of neighbors) {
        if (visited.has(neighbor)) continue
        visited.add(neighbor)
        childrenById.get(current).push(neighbor)
        queue.push(neighbor)
      }
    }

    return {rootId, childrenById}
  },
  backboneSubtreeWeights(rootId, childrenById) {
    const weights = new Map()
    const visit = (nodeId) => {
      const children = childrenById.get(nodeId) || []
      if (children.length === 0) {
        weights.set(nodeId, 1)
        return 1
      }

      let total = 0
      for (const childId of children) total += visit(childId)
      const weight = Math.max(1, total)
      weights.set(nodeId, weight)
      return weight
    }

    visit(rootId)
    return weights
  },
  applyBarycenterChildOrder(childrenById, adjacency, positions) {
    if (!(childrenById instanceof Map) || !(positions instanceof Map)) return null
    if (!(adjacency instanceof Map) || adjacency.size === 0) return null

    const ordered = new Map()
    let changed = false

    for (const [parentId, children] of childrenById.entries()) {
      if (!Array.isArray(children) || children.length < 2) {
        ordered.set(parentId, children)
        continue
      }

      const parentPoint = positions.get(parentId)
      if (!parentPoint) {
        ordered.set(parentId, children)
        continue
      }

      const scored = children.map((childId, index) => {
        let angleSum = 0
        let angleCount = 0

        for (const neighborId of adjacency.get(childId) || []) {
          if (neighborId === childId || neighborId === parentId) continue
          const neighborPoint = positions.get(neighborId)
          if (!neighborPoint) continue
          angleSum += Math.atan2(neighborPoint.y - parentPoint.y, neighborPoint.x - parentPoint.x)
          angleCount += 1
        }

        return {
          childId,
          index,
          meanAngle: angleCount > 0 ? angleSum / angleCount : null,
        }
      })

      let hasAngles = false
      for (const entry of scored) {
        if (entry.meanAngle !== null) {
          hasAngles = true
          break
        }
      }

      if (!hasAngles) {
        ordered.set(parentId, children)
        continue
      }

      const sorted = [...scored].sort((left, right) => {
        const leftAngle = left.meanAngle === null ? Math.PI * 4 + left.index * 1e-6 : left.meanAngle
        const rightAngle = right.meanAngle === null ? Math.PI * 4 + right.index * 1e-6 : right.meanAngle
        return leftAngle - rightAngle || left.index - right.index
      })

      const orderedChildren = sorted.map((entry) => entry.childId)
      if (orderedChildren.some((childId, index) => childId !== children[index])) changed = true
      ordered.set(parentId, orderedChildren)
    }

    return changed ? ordered : null
  },
  assignOrganicBackbonePositions(nodeId, childrenById, subtreeWeights, depthById, radiiByDepth, positions, frame) {
    positions.set(nodeId, {x: frame.x, y: frame.y})

    const children = childrenById.get(nodeId) || []
    if (children.length === 0) return

    const totalWeight = children.reduce((sum, childId) => sum + Number(subtreeWeights.get(childId) || 1), 0)
    const span = frame.endAngle - frame.startAngle
    let cursor = frame.startAngle

    for (let index = 0; index < children.length; index += 1) {
      const childId = children[index]
      const childWeight = Number(subtreeWeights.get(childId) || 1)
      const proportionalSpan = span * (childWeight / Math.max(totalWeight, 1))
      const childStart = cursor
      const childEnd = childStart + proportionalSpan
      const childAngle = childStart + (proportionalSpan / 2)
      const childDepth = Number(depthById.get(childId) || (frame.depth + 1))
      const radius = Number(radiiByDepth.get(childDepth) || ORGANIC_DEPTH_RADIUS)

      this.assignOrganicBackbonePositions(
        childId,
        childrenById,
        subtreeWeights,
        depthById,
        radiiByDepth,
        positions,
        {
          x: frame.x + Math.cos(childAngle) * radius,
          y: frame.y + Math.sin(childAngle) * radius,
          startAngle: childStart,
          endAngle: childEnd,
          depth: childDepth,
        },
      )

      cursor += proportionalSpan
    }
  },
  buildBackboneAdjacency(graph, excludedNodeIds) {
    const nodeIds = []
    const nodeById = new Map()
    const adjacency = new Map()
    const depthById = new Map()
    const allNodes = new Map()
    const hostedLayoutNodes = this.hostedLayoutNodeIds(graph, excludedNodeIds)

    for (let index = 0; index < graph.nodes.length; index += 1) {
      const node = graph.nodes[index]
      const nodeId = graphNodeId(node, index)
      allNodes.set(nodeId, node)
    }

    for (const edge of graph.edges) {
      const sourceId = edgeNodeId(graph, edge, "source")
      const targetId = edgeNodeId(graph, edge, "target")
      if (!sourceId || !targetId) continue
      if (!this.edgeDrivesBackboneLayout(edge)) continue
      if (excludedNodeIds.has(sourceId) || excludedNodeIds.has(targetId)) continue
      if (hostedLayoutNodes.has(sourceId) || hostedLayoutNodes.has(targetId)) continue
      if (isUnplacedNode(allNodes.get(sourceId)) || isUnplacedNode(allNodes.get(targetId))) continue

      if (!adjacency.has(sourceId)) {
        adjacency.set(sourceId, new Set())
        nodeIds.push(sourceId)
        nodeById.set(sourceId, allNodes.get(sourceId))
        depthById.set(sourceId, Number(allNodes.get(sourceId)?.y || 0))
      }

      if (!adjacency.has(targetId)) {
        adjacency.set(targetId, new Set())
        nodeIds.push(targetId)
        nodeById.set(targetId, allNodes.get(targetId))
        depthById.set(targetId, Number(allNodes.get(targetId)?.y || 0))
      }

      adjacency.get(sourceId).add(targetId)
      adjacency.get(targetId).add(sourceId)
    }

    if (nodeIds.length === 0) {
      for (const [nodeId, node] of allNodes.entries()) {
        if (excludedNodeIds.has(nodeId) || isUnplacedNode(node)) continue
        if (hostedLayoutNodes.has(nodeId)) continue
        nodeIds.push(nodeId)
        nodeById.set(nodeId, node)
        adjacency.set(nodeId, new Set())
        depthById.set(nodeId, Number(node?.y || 0))
      }
    }

    return {nodeIds, nodeById, adjacency, depthById}
  },
  edgeDrivesBackboneLayout(edge) {
    const topologyClass = String(edge?.topologyClass || "").trim().toLowerCase()
    const evidenceClass = String(edge?.evidenceClass || "").trim().toLowerCase()

    if (topologyClass === "endpoints" || topologyClass === "endpoint") return false
    if (topologyClass === "inferred" || topologyClass === "observed") return false
    if (topologyClass === "hosted") return false
    if (topologyClass === "backbone" || topologyClass === "logical") return true

    if (evidenceClass === "endpoint-attachment") return false
    if (evidenceClass === "inferred" || evidenceClass === "inferred-segment") return false
    if (evidenceClass === "observed" || evidenceClass === "observed-only") return false

    return (
      evidenceClass === "direct" ||
      evidenceClass === "direct-physical" ||
      evidenceClass === "logical" ||
      evidenceClass === "direct-logical" ||
      topologyClass === "" ||
      topologyClass === "unknown"
    )
  },
  isAttachmentTopologyEdge(edge) {
    const topologyClass = String(edge?.topologyClass || "").trim().toLowerCase()
    const evidenceClass = String(edge?.evidenceClass || "").trim().toLowerCase()

    if (topologyClass === "endpoints" || topologyClass === "endpoint" || topologyClass === "attachment") {
      return true
    }

    return evidenceClass === "endpoint-attachment" || evidenceClass === "inferred-segment"
  },
  attachmentSatellitePlacements(graph, positions, candidateIds) {
    const placements = new Map()
    if (!candidateIds || candidateIds.size === 0) return placements
    if (!graph || !Array.isArray(graph.edges)) return placements

    const anchorGuests = new Map()

    for (const edge of graph.edges) {
      if (!this.isAttachmentTopologyEdge(edge)) continue
      const sourceId = edgeNodeId(graph, edge, "source")
      const targetId = edgeNodeId(graph, edge, "target")
      if (!sourceId || !targetId || sourceId === targetId) continue

      let guestId = null
      let anchorId = null

      if (candidateIds.has(sourceId) && !candidateIds.has(targetId) && positions.has(targetId)) {
        guestId = sourceId
        anchorId = targetId
      } else if (candidateIds.has(targetId) && !candidateIds.has(sourceId) && positions.has(sourceId)) {
        guestId = targetId
        anchorId = sourceId
      }

      if (!guestId || placements.has(guestId)) continue
      const guests = anchorGuests.get(anchorId) || []
      guests.push(guestId)
      anchorGuests.set(anchorId, guests)
    }

    for (const [anchorId, guests] of anchorGuests.entries()) {
      const anchorPoint = positions.get(anchorId)
      if (!anchorPoint) continue
      const orderedGuests = guests.sort()
      const anchorSeed = Math.abs(hashStringToSeed(anchorId)) % ATTACHMENT_SATELLITES_PER_RING

      for (let index = 0; index < orderedGuests.length; index += 1) {
        const guestId = orderedGuests[index]
        if (placements.has(guestId)) continue
        const ring = Math.floor(index / ATTACHMENT_SATELLITES_PER_RING)
        const ringStart = ring * ATTACHMENT_SATELLITES_PER_RING
        const ringCount = Math.min(ATTACHMENT_SATELLITES_PER_RING, orderedGuests.length - ringStart)
        const ringIndex = index - ringStart
        const radius = ATTACHMENT_SATELLITE_RING_RADIUS + ring * ATTACHMENT_SATELLITE_RING_STEP
        const angle =
          -Math.PI / 2 +
          (Math.PI * 2 * (ringIndex + anchorSeed)) / Math.max(1, ringCount)

        placements.set(guestId, {
          x: anchorPoint.x + Math.cos(angle) * radius,
          y: anchorPoint.y + Math.sin(angle) * radius,
        })
      }
    }

    return placements
  },
  connectedBackboneComponents(nodeIds, adjacency) {
    const visited = new Set()
    const components = []

    for (const nodeId of nodeIds) {
      if (visited.has(nodeId)) continue
      const queue = [nodeId]
      const component = []
      visited.add(nodeId)

      while (queue.length > 0) {
        const current = queue.shift()
        component.push(current)

        for (const neighbor of adjacency.get(current) || []) {
          if (visited.has(neighbor)) continue
          visited.add(neighbor)
          queue.push(neighbor)
        }
      }

      components.push(component)
    }

    components.sort((left, right) => right.length - left.length || String(left[0] || "").localeCompare(String(right[0] || "")))
    return components
  },
  selectBackboneRoot(componentIds, backbone) {
    return [...componentIds].sort((leftId, rightId) => {
      const leftNode = backbone.nodeById.get(leftId) || {}
      const rightNode = backbone.nodeById.get(rightId) || {}
      const leftClusterAnchor = isEndpointAnchorNode(leftNode) ? 1 : 0
      const rightClusterAnchor = isEndpointAnchorNode(rightNode) ? 1 : 0
      const leftDegree = (backbone.adjacency.get(leftId) || new Set()).size
      const rightDegree = (backbone.adjacency.get(rightId) || new Set()).size
      const leftPps = Number(leftNode?.pps || 0)
      const rightPps = Number(rightNode?.pps || 0)
      const leftLabel = String(leftNode?.label || leftId)
      const rightLabel = String(rightNode?.label || rightId)

      return (
        leftClusterAnchor - rightClusterAnchor ||
        rightDegree - leftDegree ||
        rightPps - leftPps ||
        leftLabel.localeCompare(rightLabel) ||
        leftId.localeCompare(rightId)
      )
    })[0] || null
  },
  backboneLayersFromRoot(rootId, componentIds, backbone) {
    const componentSet = new Set(componentIds)
    const visited = new Set([rootId])
    const queue = [{id: rootId, depth: 0}]
    const layers = []

    while (queue.length > 0) {
      const {id, depth} = queue.shift()
      if (!layers[depth]) layers[depth] = []
      layers[depth].push(id)

      const neighbors = [...(backbone.adjacency.get(id) || [])]
        .filter((neighbor) => componentSet.has(neighbor))
        .sort()

      for (const neighbor of neighbors) {
        if (visited.has(neighbor)) continue
        visited.add(neighbor)
        queue.push({id: neighbor, depth: depth + 1})
      }
    }

    return layers
  },
  orderBackboneLayerNodes(layerIds, layerIndex, positions, backbone) {
    if (layerIndex === 0) return [...layerIds]

    return [...layerIds].sort((leftId, rightId) => {
      const leftParents = [...(backbone.adjacency.get(leftId) || [])]
        .map((neighbor) => positions.get(neighbor))
        .filter(Boolean)
      const rightParents = [...(backbone.adjacency.get(rightId) || [])]
        .map((neighbor) => positions.get(neighbor))
        .filter(Boolean)

      const leftCenter =
        leftParents.length > 0
          ? leftParents.reduce((sum, point) => sum + Number(point.y || 0), 0) / leftParents.length
          : Number(backbone.depthById.get(leftId) || 0)
      const rightCenter =
        rightParents.length > 0
          ? rightParents.reduce((sum, point) => sum + Number(point.y || 0), 0) / rightParents.length
          : Number(backbone.depthById.get(rightId) || 0)

      const leftNode = backbone.nodeById.get(leftId) || {}
      const rightNode = backbone.nodeById.get(rightId) || {}

      return (
        leftCenter - rightCenter ||
        String(leftNode?.label || leftId).localeCompare(String(rightNode?.label || rightId)) ||
        leftId.localeCompare(rightId)
      )
    })
  },
  applyPositionMap(graph, positions) {
    const nodes = graph.nodes.map((node, index) => {
      const positioned = positions.get(graphNodeId(node, index))
      if (!positioned) return {...node}
      return {
        ...node,
        x: positioned.x,
        y: positioned.y,
      }
    })

    return {
      ...graph,
      nodes,
    }
  },
  applyElkNodePositions(graph, elkResult) {
    const positions = collectElkPositions(elkResult, new Map())
    const nodes = graph.nodes.map((node, index) => {
      const id = graphNodeId(node, index)
      const positioned = positions.get(id)
      if (!positioned) return {...node}
      return {
        ...node,
        x: positioned.x,
        y: positioned.y,
      }
    })

    return {
      ...graph,
      nodes,
    }
  },
  applyEndpointProjectionLayout(graph, clusterLayout) {
    if (!clusterLayout || !Array.isArray(clusterLayout.groups) || clusterLayout.groups.length === 0) {
      return graph
    }

    const nodes = graph.nodes.map((node) => ({...node}))
    const nodeIndexById = new Map(nodes.map((node, index) => [graphNodeId(node, index), index]))

    for (const cluster of clusterLayout.groups) {
      const anchorIndex = nodeIndexById.get(cluster.anchorNodeId)
      if (!Number.isInteger(anchorIndex)) continue

      const anchorNode = nodes[anchorIndex]
      const anchorX = Number(anchorNode?.x)
      const anchorY = Number(anchorNode?.y)
      if (!Number.isFinite(anchorX) || !Number.isFinite(anchorY)) continue

      const occupiedNodes = this.endpointProjectionOccupiedNodes(nodes, cluster)
      const summaryIndex = nodeIndexById.get(cluster.summaryNodeId)

      if (cluster.expanded && cluster.memberNodeIds.length > 0) {
        const metrics = this.expandedClusterSpiralMetrics(cluster.memberNodeIds.length)
        const edgeSegments = this.clusterLayoutEdgeSegments(graph, clusterLayout)
        const placement = this.chooseExpandedClusterPlacement(
          anchorX,
          anchorY,
          metrics,
          occupiedNodes,
          edgeSegments,
        )
        const orderedMemberIds = this.orderExpandedClusterMembers(nodes, nodeIndexById, cluster.memberNodeIds)

        if (Number.isInteger(summaryIndex)) {
          const summary = nodes[summaryIndex]
          nodes[summaryIndex] = {
            ...summary,
            x: placement.centerX,
            y: placement.centerY,
            details: {
              ...(summary?.details && typeof summary.details === "object" ? summary.details : {}),
              cluster_expanded: true,
              cluster_anchor_id: cluster.anchorNodeId,
              cluster_panel_side: placement.name,
            },
          }
        }

        for (let memberIndex = 0; memberIndex < orderedMemberIds.length; memberIndex += 1) {
          const memberId = orderedMemberIds[memberIndex]
          const graphIndex = nodeIndexById.get(memberId)
          if (!Number.isInteger(graphIndex)) continue

          const point = this.expandedClusterSpiralPosition(memberIndex, metrics, placement)
          const member = nodes[graphIndex]
          nodes[graphIndex] = {
            ...member,
            x: point.x,
            y: point.y,
            details: {
              ...(member?.details && typeof member.details === "object" ? member.details : {}),
              cluster_expanded: true,
              cluster_anchor_id: cluster.anchorNodeId,
              cluster_panel_side: placement.name,
            },
          }
        }
        continue
      }

      const baseAngle = this.resolveEndpointProjectionAngle(nodes, nodeIndexById, cluster, anchorNode)
      const clusterAngle = this.endpointProjectionSlotAngle(
        this.resolveEndpointProjectionBearing(baseAngle, anchorNode, occupiedNodes, false),
        cluster.slotIndex,
        cluster.slotCount,
      )
      const hubDistance = this.endpointProjectionHubDistance(
        cluster.memberNodeIds.length,
        false,
        this.endpointProjectionClearanceDistance(anchorNode, clusterAngle, occupiedNodes, false),
      )
      const hubOffset = rotatePoint(hubDistance, 0, clusterAngle)

      if (Number.isInteger(summaryIndex)) {
        nodes[summaryIndex] = {
          ...nodes[summaryIndex],
          x: anchorX + hubOffset.x,
          y: anchorY + hubOffset.y,
        }
      }
    }

    return {
      ...graph,
      nodes,
    }
  },
  endpointProjectionOccupiedNodes(nodes, cluster) {
    const memberIds = new Set(cluster.memberNodeIds || [])

    return nodes.filter((node, index) => {
      const nodeId = graphNodeId(node, index)
      if (nodeId === cluster.anchorNodeId) return false
      if (nodeId === cluster.summaryNodeId) return false
      if (memberIds.has(nodeId)) return false
      if (isEndpointSummaryNode(node)) return false

      const x = Number(node?.x)
      const y = Number(node?.y)
      return Number.isFinite(x) && Number.isFinite(y)
    })
  },
  normalizeHorizontalLayout(graph) {
    return graph
  },
  resolveEndpointProjectionAngle(nodes, nodeIndexById, cluster, anchorNode) {
    const parentIndex = cluster.parentNodeId ? nodeIndexById.get(cluster.parentNodeId) : null
    const parentNode = Number.isInteger(parentIndex) ? nodes[parentIndex] : null

    if (parentNode) {
      const dx = Number(anchorNode.x || 0) - Number(parentNode.x || 0)
      const dy = Number(anchorNode.y || 0) - Number(parentNode.y || 0)
      if (Math.abs(dx) > 0.001 || Math.abs(dy) > 0.001) return Math.atan2(dy, dx)
    }

    let centroidX = 0
    let centroidY = 0
    let count = 0

    for (let index = 0; index < nodes.length; index += 1) {
      const node = nodes[index]
      const nodeId = graphNodeId(node, index)
      if (nodeId === cluster.anchorNodeId) continue
      if (nodeId === cluster.summaryNodeId) continue
      if (cluster.memberNodeIds.includes(nodeId)) continue
      if (isEndpointSummaryNode(node)) continue

      const x = Number(node?.x)
      const y = Number(node?.y)
      if (!Number.isFinite(x) || !Number.isFinite(y)) continue

      centroidX += x
      centroidY += y
      count += 1
    }

    if (count > 0) {
      centroidX /= count
      centroidY /= count
      return Math.atan2(Number(anchorNode.y || 0) - centroidY, Number(anchorNode.x || 0) - centroidX)
    }

    return 0
  },
  resolveEndpointProjectionBearing(baseAngle, anchorNode, occupiedNodes, expanded) {
    const offsets = [0, 0.52, -0.52, 1.05, -1.05, 1.57, -1.57, Math.PI]
    let bestAngle = baseAngle
    let bestScore = -Infinity

    for (const offset of offsets) {
      const angle = baseAngle + offset
      const score = this.endpointProjectionBearingScore(anchorNode, angle, occupiedNodes, expanded)
      if (score > bestScore) {
        bestScore = score
        bestAngle = angle
      }
    }

    return bestAngle
  },
  endpointProjectionBearingScore(anchorNode, angle, occupiedNodes, expanded) {
    const directionX = Math.cos(angle)
    const directionY = Math.sin(angle)
    const corridorHalfWidth = expanded ? 260 : 180
    const rearGuard = expanded ? 40 : 24
    let nearestForward = Infinity
    let lateralPenalty = 0

    for (const node of occupiedNodes) {
      const dx = Number(node?.x || 0) - Number(anchorNode?.x || 0)
      const dy = Number(node?.y || 0) - Number(anchorNode?.y || 0)
      const forward = (dx * directionX) + (dy * directionY)
      const lateral = Math.abs((-directionY * dx) + (directionX * dy))
      if (forward <= -rearGuard || lateral > corridorHalfWidth) continue

      nearestForward = Math.min(nearestForward, forward)
      lateralPenalty += Math.max(0, corridorHalfWidth - lateral)
    }

    const forwardScore = nearestForward === Infinity ? 960 : nearestForward
    return forwardScore - (lateralPenalty * 0.45)
  },
  endpointProjectionSlotAngle(baseAngle, slotIndex, slotCount) {
    const count = Math.max(1, Number(slotCount || 1))
    const index = Math.max(0, Number(slotIndex || 0))
    return baseAngle + (index - ((count - 1) / 2)) * 0.42
  },
  endpointProjectionClearanceDistance(anchorNode, angle, occupiedNodes, expanded) {
    const directionX = Math.cos(angle)
    const directionY = Math.sin(angle)
    const corridorHalfWidth = expanded ? 240 : 160
    const nodeRadius = expanded ? 172 : 108
    let clearance = 0

    for (const node of occupiedNodes) {
      const dx = Number(node?.x || 0) - Number(anchorNode?.x || 0)
      const dy = Number(node?.y || 0) - Number(anchorNode?.y || 0)
      const forward = (dx * directionX) + (dy * directionY)
      const lateral = Math.abs((-directionY * dx) + (directionX * dy))
      if (forward <= 0 || lateral > corridorHalfWidth) continue

      clearance = Math.max(clearance, forward + nodeRadius)
    }

    return clearance
  },
  endpointProjectionHubDistance(memberCount, expanded, clearanceDistance = 0) {
    const count = Math.max(1, Number(memberCount || 1))
    const base = expanded ? 168 : 82
    const intrinsic = base + Math.min(96, Math.sqrt(count) * (expanded ? 16 : 9))
    return Math.max(intrinsic, Number(clearanceDistance || 0))
  },
  expandedClusterSpiralMetrics(memberCount) {
    const count = Math.max(1, Number(memberCount || 1))
    return {
      count,
      spacing: EXPANDED_CLUSTER_SPIRAL_SPACING,
      minRadius: count <= 2 ? 0 : EXPANDED_CLUSTER_SPIRAL_MIN_RADIUS,
    }
  },
  expandedClusterSpiralPosition(memberIndex, metrics, placement) {
    const idx = Math.max(0, Number(memberIndex || 0))
    const spacing = Number(metrics?.spacing || EXPANDED_CLUSTER_SPIRAL_SPACING)
    const minRadius = Number(metrics?.minRadius || 0)
    const radius = minRadius + spacing * Math.sqrt(idx)
    const angle = -Math.PI / 2 + idx * EXPANDED_CLUSTER_GOLDEN_ANGLE
    return {
      x: Number(placement?.centerX || 0) + Math.cos(angle) * radius,
      y: Number(placement?.centerY || 0) + Math.sin(angle) * radius,
    }
  },
  orderExpandedClusterMembers(nodes, nodeIndexById, memberNodeIds) {
    return [...(memberNodeIds || [])].sort((leftId, rightId) => {
      const leftNode = nodes[nodeIndexById.get(leftId)]
      const rightNode = nodes[nodeIndexById.get(rightId)]
      const leftLabel = String(leftNode?.label || leftId || "")
      const rightLabel = String(rightNode?.label || rightId || "")
      return leftLabel.localeCompare(rightLabel, undefined, {numeric: true, sensitivity: "base"}) ||
        String(leftId).localeCompare(String(rightId))
    })
  },
  clusterLayoutEdgeSegments(graph, clusterLayout) {
    const segments = []
    if (!graph || !Array.isArray(graph.edges)) return segments

    const clusterNodeIds = new Set()
    for (const cluster of clusterLayout?.groups || []) {
      if (cluster.anchorNodeId) clusterNodeIds.add(cluster.anchorNodeId)
      if (cluster.summaryNodeId) clusterNodeIds.add(cluster.summaryNodeId)
      for (const memberId of cluster.memberNodeIds || []) clusterNodeIds.add(memberId)
    }

    const positionById = new Map()
    for (let index = 0; index < graph.nodes.length; index += 1) {
      const node = graph.nodes[index]
      const x = Number(node?.x)
      const y = Number(node?.y)
      if (Number.isFinite(x) && Number.isFinite(y)) positionById.set(graphNodeId(node, index), {x, y})
    }

    for (const edge of graph.edges) {
      const sourceId = edgeNodeId(graph, edge, "source")
      const targetId = edgeNodeId(graph, edge, "target")
      if (!sourceId || !targetId || sourceId === targetId) continue
      if (clusterNodeIds.has(sourceId) || clusterNodeIds.has(targetId)) continue

      const sourcePoint = positionById.get(sourceId)
      const targetPoint = positionById.get(targetId)
      if (!sourcePoint || !targetPoint) continue

      segments.push([sourcePoint.x, sourcePoint.y, targetPoint.x, targetPoint.y])
    }

    return segments
  },
  segmentsIntersect(ax, ay, bx, by, cx, cy, dx, dy) {
    const orientation = (px, py, qx, qy, rx, ry) => {
      const value = (qx - px) * (ry - py) - (qy - py) * (rx - px)
      if (Math.abs(value) < 1e-9) return 0
      return value > 0 ? 1 : 2
    }
    const onSegment = (px, py, qx, qy, rx, ry) =>
      Math.min(px, rx) <= qx && qx <= Math.max(px, rx) &&
      Math.min(py, ry) <= qy && qy <= Math.max(py, ry)

    const o1 = orientation(ax, ay, bx, by, cx, cy)
    const o2 = orientation(ax, ay, bx, by, dx, dy)
    const o3 = orientation(cx, cy, dx, dy, ax, ay)
    const o4 = orientation(cx, cy, dx, dy, bx, by)

    if (o1 !== o2 && o3 !== o4) return true
    if (o1 === 0 && onSegment(ax, ay, cx, cy, bx, by)) return true
    if (o2 === 0 && onSegment(ax, ay, dx, dy, bx, by)) return true
    if (o3 === 0 && onSegment(cx, cy, ax, ay, dx, dy)) return true
    if (o4 === 0 && onSegment(cx, cy, bx, by, dx, dy)) return true
    return false
  },
  chooseExpandedClusterPlacement(anchorX, anchorY, metrics, occupiedNodes, edgeSegments = []) {
    const spacing = Number(metrics?.spacing || EXPANDED_CLUSTER_SPIRAL_SPACING)
    const count = Math.max(1, Number(metrics?.count || 1))
    const spiralRadius =
      Number(metrics?.minRadius || 0) + spacing * Math.sqrt(Math.max(0, count - 1)) + spacing
    const pad = spiralRadius + 96
    const candidates = [
      {name: "right", centerX: anchorX + pad, centerY: anchorY},
      {name: "left", centerX: anchorX - pad, centerY: anchorY},
      {name: "down", centerX: anchorX, centerY: anchorY + pad},
      {name: "up", centerX: anchorX, centerY: anchorY - pad},
    ]

    let best = candidates[0]
    let bestScore = -Infinity

    for (const candidate of candidates) {
      let overlapHits = 0
      let crossings = 0
      const memberPoints = []

      for (let memberIndex = 0; memberIndex < count; memberIndex += 1) {
        const point = this.expandedClusterSpiralPosition(memberIndex, metrics, candidate)
        memberPoints.push(point)

        for (const node of occupiedNodes || []) {
          const x = Number(node?.x)
          const y = Number(node?.y)
          if (!Number.isFinite(x) || !Number.isFinite(y)) continue
          if (Math.hypot(point.x - x, point.y - y) < EXPANDED_CLUSTER_NODE_CLEARANCE) {
            overlapHits += 1
          }
        }
      }

      if (edgeSegments.length > 0) {
        const clusterSegments = [
          [anchorX, anchorY, candidate.centerX, candidate.centerY],
          ...memberPoints.map((point) => [candidate.centerX, candidate.centerY, point.x, point.y]),
        ]

        for (const clusterSegment of clusterSegments) {
          for (const segment of edgeSegments) {
            if (
              this.segmentsIntersect(
                clusterSegment[0],
                clusterSegment[1],
                clusterSegment[2],
                clusterSegment[3],
                segment[0],
                segment[1],
                segment[2],
                segment[3],
              )
            ) {
              crossings += 1
            }
          }
        }
      }

      const sideBonus = candidate.name === "right" || candidate.name === "left" ? 80 : 0
      const score =
        -overlapHits * 1000 - crossings * 120 + sideBonus - Math.hypot(candidate.centerX - anchorX, candidate.centerY - anchorY) * 0.01
      if (score > bestScore) {
        bestScore = score
        best = candidate
      }
    }

    return best
  },
  graphTopologyStamp(graph) {
    if (!graph || !Array.isArray(graph.nodes) || !Array.isArray(graph.edges)) return "0:0"
    const nodeIds = graph.nodes.map((node, index) => graphNodeId(node, index)).sort()
    let nodeHash = 0
    for (let i = 0; i < nodeIds.length; i += 1) {
      const id = nodeIds[i]
      for (let j = 0; j < id.length; j += 1) nodeHash = ((nodeHash << 5) - nodeHash + id.charCodeAt(j)) | 0
    }

    const edgeKeys = graph.edges
      .map((edge) => {
        const sourceId = edgeNodeId(graph, edge, "source")
        const targetId = edgeNodeId(graph, edge, "target")
        const left = sourceId || String(edge?.sourceCluster || edge?.source || "")
        const right = targetId || String(edge?.targetCluster || edge?.target || "")
        return left <= right ? `${left}::${right}` : `${right}::${left}`
      })
      .sort()

    let edgeHash = 0
    for (let i = 0; i < edgeKeys.length; i += 1) {
      const key = edgeKeys[i]
      for (let j = 0; j < key.length; j += 1) edgeHash = ((edgeHash << 5) - edgeHash + key.charCodeAt(j)) | 0
    }

    return `${graph.nodes.length}:${graph.edges.length}:${nodeHash}:${edgeHash}`
  },
  sameTopology(previousGraph, nextGraph, stamp, revision) {
    const {state} = this
    if (!previousGraph || !nextGraph) return false
    if (Number.isFinite(revision) && Number.isFinite(state.lastRevision) && revision === state.lastRevision) {
      return (
        previousGraph.nodes.length === nextGraph.nodes.length &&
        previousGraph.edges.length === nextGraph.edges.length
      )
    }
    return (
      stamp === state.lastTopologyStamp &&
      previousGraph.nodes.length === nextGraph.nodes.length &&
      previousGraph.edges.length === nextGraph.edges.length
    )
  },
  reusePreviousPositions(nextGraph, previousGraph) {
    if (!nextGraph || !previousGraph) return nextGraph
    const byId = new Map((previousGraph.nodes || []).map((node, index) => [graphNodeId(node, index), node]))
    const nodes = (nextGraph.nodes || []).map((node, index) => {
      const prev = byId.get(graphNodeId(node, index))
      if (!prev) return node
      return {
        ...node,
        x: Number(prev.x || node.x || 0),
        y: Number(prev.y || node.y || 0),
      }
    })
    return {...nextGraph, nodes}
  },
}
