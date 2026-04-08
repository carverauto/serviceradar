import ELK from "elkjs/lib/elk.bundled.js"

const DEFAULT_LAYOUT_ENGINE = new ELK()
const MAX_LAYOUT_CACHE_ENTRIES = 12
const DEFAULT_NODE_WIDTH = 54
const DEFAULT_NODE_HEIGHT = 54
const LAYOUT_WIDTH = 640
const LAYOUT_HEIGHT = 320
const LAYOUT_PAD = 20
const BACKBONE_LAYER_GAP_X = 180
const BACKBONE_LAYER_GAP_Y = 120
const BACKBONE_COMPONENT_GAP_Y = 180
const ORGANIC_ROOT_X = 320
const ORGANIC_ROOT_Y = 280
const ORGANIC_DEPTH_RADIUS = 168
const ORGANIC_DEPTH_RADIUS_STEP = 120
const ORGANIC_FULL_SPAN = Math.PI * 1.7
const ORGANIC_MIN_CHILD_SPAN = 0.42
const BACKBONE_RELAXATION_ITERATIONS = 180
const BACKBONE_REPULSION = 220_000
const BACKBONE_SPRING_LENGTH = 210
const BACKBONE_SPRING_STRENGTH = 0.0038
const BACKBONE_CENTERING = 0.0016
const BACKBONE_DAMPING = 0.82
const UNPLACED_LANE_X_OFFSET = 220
const UNPLACED_LANE_GAP_Y = 92

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

function isExpandedClusterNode(node) {
  return graphNodeDetails(node).cluster_expanded === true
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
    cluster_expanded: existing?.cluster_expanded === true || incoming?.cluster_expanded === true,
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
    const requiresFullElk = this.requiresFullElkLayout(graph)
    const layeredPositions = requiresFullElk ? null : this.computeBackboneLayeredPositions(graph, new Set())

    if (layeredPositions instanceof Map && layeredPositions.size > 0) {
      const withBackbone = this.applyPositionMap(graph, layeredPositions)
      const normalized = this.normalizeHorizontalLayout(withBackbone)
      return {
        ...normalized,
        _layoutMode: "client-layered",
        _layoutCacheKey: layoutKey,
      }
    }

    const layoutGraph = this.buildElkLayoutGraph(graph, new Set(), {
      includeAttachmentEdges: requiresFullElk,
    })

    try {
      const engine = this.state.layoutEngine || DEFAULT_LAYOUT_ENGINE
      const elkResult = await engine.layout(layoutGraph)
      const withBackbone = this.applyElkNodePositions(graph, elkResult)
      const normalized = this.normalizeHorizontalLayout(withBackbone)
      return {
        ...normalized,
        _layoutMode: requiresFullElk ? "elk-client-full" : "elk-client",
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
  requiresFullElkLayout(graph) {
    if (!graph || !Array.isArray(graph.nodes) || !Array.isArray(graph.edges)) return false
    return (
      graph.nodes.some((node) => isEndpointSummaryNode(node) || isEndpointMemberNode(node)) ||
      graph.edges.some((edge) => String(edge?.evidenceClass || "") === "endpoint-attachment")
    )
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
    const backbone = this.buildBackboneAdjacency(graph, excludedNodeIds)
    const unplacedNodes = Array.isArray(graph?.nodes)
      ? graph.nodes
          .map((node, index) => ({id: graphNodeId(node, index), node}))
          .filter(({id, node}) => !excludedNodeIds.has(id) && isUnplacedNode(node))
      : []

    if ((!backbone || backbone.nodeIds.length === 0) && unplacedNodes.length === 0) return null

    const components = this.connectedBackboneComponents(backbone.nodeIds, backbone.adjacency)
    const positions = new Map()
    let componentOffsetY = 0

    for (const componentIds of components) {
      const rootId = this.selectBackboneRoot(componentIds, backbone)
      if (!rootId) continue

      const tree = this.buildBackboneTree(rootId, componentIds, backbone)
      const subtreeWeights = this.backboneSubtreeWeights(rootId, tree.childrenById)
      const componentPositions = new Map()

      this.assignOrganicBackbonePositions(
        rootId,
        tree.childrenById,
        subtreeWeights,
        componentPositions,
        {
          x: ORGANIC_ROOT_X,
          y: ORGANIC_ROOT_Y + componentOffsetY,
          angle: 0,
          span: ORGANIC_FULL_SPAN,
          depth: 0,
        },
      )

      this.relaxBackboneComponent(componentIds, backbone, componentPositions, rootId)

      for (const [nodeId, point] of componentPositions.entries()) positions.set(nodeId, point)

      const componentYs = Array.from(componentPositions.values()).map((point) => Number(point.y || 0))
      const componentHeight =
        componentYs.length > 0
          ? Math.max(...componentYs) - Math.min(...componentYs) + BACKBONE_COMPONENT_GAP_Y
          : BACKBONE_COMPONENT_GAP_Y

      componentOffsetY += componentHeight
    }

    if (unplacedNodes.length > 0) {
      const placedPoints = Array.from(positions.values())
      const anchorX = placedPoints.length > 0
        ? Math.max(...placedPoints.map((point) => Number(point.x || 0))) + UNPLACED_LANE_X_OFFSET
        : 120
      const anchorY = placedPoints.length > 0
        ? Math.min(...placedPoints.map((point) => Number(point.y || 0)))
        : 220

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
          x: anchorX + column * Math.round(BACKBONE_LAYER_GAP_X * 0.9),
          y: anchorY + row * UNPLACED_LANE_GAP_Y,
        })
      }
    }

    return positions
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
  relaxBackboneComponent(componentIds, backbone, positions, rootId) {
    const nodes = componentIds
      .map((nodeId) => ({
        id: nodeId,
        position: positions.get(nodeId),
        velocity: {x: 0, y: 0},
      }))
      .filter((entry) => entry.position)

    if (nodes.length < 2) return

    const nodeIndex = new Map(nodes.map((entry, index) => [entry.id, index]))
    const edges = []

    for (const nodeId of componentIds) {
      for (const neighborId of backbone.adjacency.get(nodeId) || []) {
        const left = nodeIndex.get(nodeId)
        const right = nodeIndex.get(neighborId)
        if (!Number.isInteger(left) || !Number.isInteger(right) || left >= right) continue
        edges.push([left, right])
      }
    }

    const rootIndex = nodeIndex.get(rootId)
    const rootAnchor = Number.isInteger(rootIndex)
      ? {
          x: Number(nodes[rootIndex].position.x || ORGANIC_ROOT_X),
          y: Number(nodes[rootIndex].position.y || ORGANIC_ROOT_Y),
        }
      : {x: ORGANIC_ROOT_X, y: ORGANIC_ROOT_Y}

    for (let iteration = 0; iteration < BACKBONE_RELAXATION_ITERATIONS; iteration += 1) {
      const forces = nodes.map(() => ({x: 0, y: 0}))

      for (let left = 0; left < nodes.length; left += 1) {
        const leftPosition = nodes[left].position
        for (let right = left + 1; right < nodes.length; right += 1) {
          const rightPosition = nodes[right].position
          const dx = Number(rightPosition.x || 0) - Number(leftPosition.x || 0)
          const dy = Number(rightPosition.y || 0) - Number(leftPosition.y || 0)
          const distanceSq = Math.max(1, dx * dx + dy * dy)
          const distance = Math.sqrt(distanceSq)
          const force = BACKBONE_REPULSION / distanceSq
          const fx = (dx / distance) * force
          const fy = (dy / distance) * force
          forces[left].x -= fx
          forces[left].y -= fy
          forces[right].x += fx
          forces[right].y += fy
        }
      }

      for (const [left, right] of edges) {
        const leftPosition = nodes[left].position
        const rightPosition = nodes[right].position
        const dx = Number(rightPosition.x || 0) - Number(leftPosition.x || 0)
        const dy = Number(rightPosition.y || 0) - Number(leftPosition.y || 0)
        const distance = Math.max(1, Math.sqrt(dx * dx + dy * dy))
        const extension = distance - BACKBONE_SPRING_LENGTH
        const force = extension * BACKBONE_SPRING_STRENGTH
        const fx = (dx / distance) * force
        const fy = (dy / distance) * force
        forces[left].x += fx
        forces[left].y += fy
        forces[right].x -= fx
        forces[right].y -= fy
      }

      for (let index = 0; index < nodes.length; index += 1) {
        const node = nodes[index]
        const isRoot = index === rootIndex
        const toCenterX = rootAnchor.x - Number(node.position.x || 0)
        const toCenterY = rootAnchor.y - Number(node.position.y || 0)
        forces[index].x += toCenterX * BACKBONE_CENTERING * (isRoot ? 4.5 : 1)
        forces[index].y += toCenterY * BACKBONE_CENTERING * (isRoot ? 4.5 : 1)

        if (isRoot) {
          node.velocity.x = 0
          node.velocity.y = 0
          node.position.x = rootAnchor.x
          node.position.y = rootAnchor.y
          continue
        }

        node.velocity.x = (node.velocity.x + forces[index].x) * BACKBONE_DAMPING
        node.velocity.y = (node.velocity.y + forces[index].y) * BACKBONE_DAMPING
        node.position.x += node.velocity.x
        node.position.y += node.velocity.y
      }
    }
  },
  assignOrganicBackbonePositions(nodeId, childrenById, subtreeWeights, positions, frame) {
    positions.set(nodeId, {x: frame.x, y: frame.y})

    const children = childrenById.get(nodeId) || []
    if (children.length === 0) return

    const totalWeight = children.reduce((sum, childId) => sum + Number(subtreeWeights.get(childId) || 1), 0)
    let cursor = frame.angle - frame.span / 2

    for (let index = 0; index < children.length; index += 1) {
      const childId = children[index]
      const childWeight = Number(subtreeWeights.get(childId) || 1)
      const proportionalSpan = frame.span * (childWeight / Math.max(totalWeight, 1))
      const childSpan =
        children.length === 1 ? Math.min(frame.span * 0.74, Math.PI * 0.55) : Math.max(ORGANIC_MIN_CHILD_SPAN, proportionalSpan)
      const childAngle = cursor + proportionalSpan / 2
      const radius = ORGANIC_DEPTH_RADIUS + Math.max(0, frame.depth - 1) * ORGANIC_DEPTH_RADIUS_STEP

      this.assignOrganicBackbonePositions(
        childId,
        childrenById,
        subtreeWeights,
        positions,
        {
          x: frame.x + Math.cos(childAngle) * radius,
          y: frame.y + Math.sin(childAngle) * radius,
          angle: childAngle,
          span: Math.min(frame.span * 0.74, childSpan),
          depth: frame.depth + 1,
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

    for (let index = 0; index < graph.nodes.length; index += 1) {
      const node = graph.nodes[index]
      const nodeId = graphNodeId(node, index)
      if (excludedNodeIds.has(nodeId)) continue
      if (isUnplacedNode(node)) continue
      nodeIds.push(nodeId)
      nodeById.set(nodeId, node)
      adjacency.set(nodeId, new Set())
      depthById.set(nodeId, Number(node?.y || 0))
    }

    for (const edge of graph.edges) {
      const sourceId = edgeNodeId(graph, edge, "source")
      const targetId = edgeNodeId(graph, edge, "target")
      if (!sourceId || !targetId) continue
      if (!adjacency.has(sourceId) || !adjacency.has(targetId)) continue
      if (String(edge?.evidenceClass || "") === "endpoint-attachment") continue
      adjacency.get(sourceId).add(targetId)
      adjacency.get(targetId).add(sourceId)
    }

    return {nodeIds, nodeById, adjacency, depthById}
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

      const baseAngle = this.resolveEndpointProjectionAngle(nodes, nodeIndexById, cluster, anchorNode)
      const clusterAngle = this.endpointProjectionSlotAngle(baseAngle, cluster.slotIndex, cluster.slotCount)
      const hubDistance = this.endpointProjectionHubDistance(cluster.memberNodeIds.length, cluster.expanded)
      const hubOffset = rotatePoint(hubDistance, 0, clusterAngle)
      const hubX = anchorX + hubOffset.x
      const hubY = anchorY + hubOffset.y
      const summaryIndex = nodeIndexById.get(cluster.summaryNodeId)

      if (Number.isInteger(summaryIndex)) {
        nodes[summaryIndex] = {
          ...nodes[summaryIndex],
          x: hubX,
          y: hubY,
        }
      }

      if (!cluster.expanded || cluster.memberNodeIds.length === 0) continue

      const metrics = this.expandedClusterSpiralMetrics(cluster.memberNodeIds.length)

      for (let memberIndex = 0; memberIndex < cluster.memberNodeIds.length; memberIndex += 1) {
        const memberId = cluster.memberNodeIds[memberIndex]
        const graphIndex = nodeIndexById.get(memberId)
        if (!Number.isInteger(graphIndex)) continue

        const offset = this.expandedClusterSpiralOffset(memberIndex, metrics, memberId)
        const rotated = rotatePoint(offset.x, offset.y, clusterAngle)
        nodes[graphIndex] = {
          ...nodes[graphIndex],
          x: hubX + rotated.x,
          y: hubY + rotated.y,
        }
      }
    }

    return {
      ...graph,
      nodes,
    }
  },
  normalizeHorizontalLayout(graph) {
    if (!graph || !Array.isArray(graph.nodes) || graph.nodes.length === 0) return graph

    const coords = graph.nodes
      .map((node) => ({
        node,
        x: Number(node?.x),
        y: Number(node?.y),
      }))
      .filter((entry) => Number.isFinite(entry.x) && Number.isFinite(entry.y))

    if (coords.length < 2) return graph

    const xs = coords.map((entry) => entry.x)
    const ys = coords.map((entry) => entry.y)
    const minX = Math.min(...xs)
    const maxX = Math.max(...xs)
    const minY = Math.min(...ys)
    const maxY = Math.max(...ys)
    const xSpan = maxX - minX
    const ySpan = maxY - minY

    if (!Number.isFinite(xSpan) || !Number.isFinite(ySpan) || xSpan <= 0 || ySpan <= 0) return graph

    const targetYSpan = Math.max(220, xSpan * 0.72)
    if (ySpan <= targetYSpan) return graph

    const centerY = (minY + maxY) / 2
    const scaleY = targetYSpan / ySpan

    return {
      ...graph,
      nodes: graph.nodes.map((node) => {
        const y = Number(node?.y)
        if (!Number.isFinite(y)) return node

        return {
          ...node,
          y: centerY + ((y - centerY) * scaleY),
        }
      }),
    }
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
  endpointProjectionSlotAngle(baseAngle, slotIndex, slotCount) {
    const count = Math.max(1, Number(slotCount || 1))
    const index = Math.max(0, Number(slotIndex || 0))
    return baseAngle + (index - ((count - 1) / 2)) * 0.42
  },
  endpointProjectionHubDistance(memberCount, expanded) {
    const count = Math.max(1, Number(memberCount || 1))
    const base = expanded ? 156 : 82
    return base + Math.min(72, Math.sqrt(count) * (expanded ? 18 : 9))
  },
  expandedClusterSpiralMetrics(memberCount) {
    const count = Math.max(1, Number(memberCount || 1))
    return {
      forwardBase: 42 + Math.sqrt(count) * 14,
      baseRadius: 18,
      radiusStep: 34,
      angleStep: 1.02,
      lateralScale: 1.14,
    }
  },
  expandedClusterSpiralOffset(memberIndex, metrics, memberId) {
    const idx = Math.max(0, Number(memberIndex || 0))
    const radius = metrics.baseRadius + metrics.radiusStep * Math.sqrt(idx + 1)
    const theta = idx * metrics.angleStep + this.endpointAngleOffset(memberId) * 0.12
    return {
      x: metrics.forwardBase + radius * (1 + Math.cos(theta)) * 0.82,
      y: metrics.lateralScale * radius * Math.sin(theta),
    }
  },
  endpointAngleOffset(value) {
    const text = String(value || "")
    let hash = 0
    for (let i = 0; i < text.length; i += 1) hash = ((hash << 5) - hash + text.charCodeAt(i)) | 0
    return ((hash % 360) * Math.PI) / 180
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
