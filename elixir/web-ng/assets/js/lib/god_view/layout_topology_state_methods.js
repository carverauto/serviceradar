import ELK from "elkjs/lib/elk.bundled.js"

import {
  applyTopologySceneToGraph,
  layoutTopologyScene,
  viewportProfileForSize,
} from "./layout_elk_scene"
import {prepareTopologySceneInput} from "./topology_scene_graph"

let defaultLayoutEngine = null
const MAX_LAYOUT_CACHE_ENTRIES = 12
const LAYOUT_WIDTH = 640
const LAYOUT_HEIGHT = 320
const LAYOUT_PAD = 20

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
  return typeof node?.id === "string" && node.id.trim() !== ""
    ? node.id.trim()
    : `node-${fallbackIndex + 1}`
}

function graphNodeDetails(node) {
  return node?.details && typeof node.details === "object" ? node.details : {}
}

function expandedFlag(value) {
  return value === true || value === "true" || value === 1
}

function mergeGraphNodes(existing, incoming) {
  const existingDetails = graphNodeDetails(existing)
  const incomingDetails = graphNodeDetails(incoming)
  return {
    ...incoming,
    ...existing,
    details: {
      ...incomingDetails,
      ...existingDetails,
      cluster_expanded:
        expandedFlag(existingDetails.cluster_expanded) ||
        expandedFlag(incomingDetails.cluster_expanded),
    },
  }
}

function edgeNodeId(graph, edge, side) {
  const index = Number(edge?.[side])
  if (!Number.isInteger(index) || index < 0 || index >= (graph?.nodes || []).length) return null
  return graphNodeId(graph.nodes[index], index)
}

function stringHash(value) {
  const text = String(value || "")
  let hash = 0
  for (let index = 0; index < text.length; index += 1) {
    hash = ((hash << 5) - hash + text.charCodeAt(index)) | 0
  }
  return hash
}

function layoutErrorMessage(error) {
  if (error instanceof Error && error.message) return error.message
  return String(error || "unknown ELK layout error")
}

function stripCoordinates(graph) {
  return {
    ...graph,
    nodes: (graph?.nodes || []).map((node) => {
      const {x: _x, y: _y, ...withoutCoordinates} = node
      return withoutCoordinates
    }),
  }
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
    const sceneInput = prepareTopologySceneInput(deduped)
    const profile = viewportProfileForSize(
      state.viewportWidth,
      state.viewportHeight,
      state.viewportSafeInsets,
    )
    const layoutKey = this.graphLayoutCacheKey(sceneInput, revision, topologyStamp, profile)
    const cached = this.getCachedGraphLayout(layoutKey)

    if (cached) {
      state.layoutMode = cached._layoutMode
      state.layoutRevision = revision
      state.lastLayoutKey = layoutKey
      return cached
    }

    const finalGraph = await this.computeClientTopologyLayout(
      deduped,
      sceneInput,
      layoutKey,
      profile,
      revision,
    )

    if (finalGraph._topologyScene && !finalGraph._layoutError) {
      this.storeCachedGraphLayout(layoutKey, finalGraph)
    }
    state.layoutMode = finalGraph._layoutMode
    state.layoutRevision = revision
    state.lastLayoutKey = layoutKey
    return finalGraph
  },

  graphLayoutCacheKey(sceneInput, revision, topologyStamp, profile) {
    const revisionToken = Number.isFinite(revision) ? revision : "na"
    return `${revisionToken}:${String(topologyStamp || "na")}:${profile.key}:${sceneInput.graphKey}`
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
      state.layoutCache.delete(state.layoutCache.keys().next().value)
    }
  },

  async computeClientTopologyLayout(graph, sceneInput, layoutKey, profile, revision) {
    try {
      const engine = this.state.layoutEngine || getDefaultLayoutEngine()
      const scene = await layoutTopologyScene(sceneInput, {engine, profile})
      return {
        ...applyTopologySceneToGraph(graph, scene),
        _layoutRevision: revision,
        _layoutCacheKey: layoutKey,
      }
    } catch (error) {
      const diagnostic = layoutErrorMessage(error)
      const previousGraph = this.state.lastGraph
      const compatible =
        previousGraph?._layoutCacheKey === layoutKey && previousGraph?._topologyScene

      if (compatible) {
        return {
          ...previousGraph,
          _layoutError: diagnostic,
        }
      }

      return {
        ...stripCoordinates(graph),
        _layoutMode: "elk-scene-error",
        _layoutRevision: revision,
        _layoutCacheKey: layoutKey,
        _layoutError: diagnostic,
      }
    }
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
      const explicitId = typeof edge?.id === "string" && edge.id.trim() !== "" ? edge.id.trim() : null
      const edgeKey = explicitId
        ? `id:${explicitId}`
        : [
            source,
            target,
            String(edge?.topologyClass || ""),
            String(edge?.label || ""),
            String(edge?.protocol || ""),
            String(edge?.evidenceClass || ""),
          ].join("|")
      if (seenEdgeKeys.has(edgeKey)) continue
      seenEdgeKeys.add(edgeKey)
      edges.push({...edge, source, target})
    }

    return {
      ...graph,
      nodes,
      edges,
      edgeSourceIndex: Uint32Array.from(edges.map((edge) => edge.source)),
      edgeTargetIndex: Uint32Array.from(edges.map((edge) => edge.target)),
    }
  },

  graphTopologyStamp(graph) {
    if (!graph || !Array.isArray(graph.nodes) || !Array.isArray(graph.edges)) return "0:0"
    const nodeIds = graph.nodes.map((node, index) => graphNodeId(node, index)).sort()
    const edgeKeys = graph.edges
      .map((edge) => {
        const sourceId = edgeNodeId(graph, edge, "source")
        const targetId = edgeNodeId(graph, edge, "target")
        const left = sourceId || String(edge?.sourceCluster || edge?.source || "")
        const right = targetId || String(edge?.targetCluster || edge?.target || "")
        return left <= right ? `${left}::${right}` : `${right}::${left}`
      })
      .sort()
    return `${graph.nodes.length}:${graph.edges.length}:${stringHash(nodeIds.join("|"))}:${stringHash(edgeKeys.join("|"))}`
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
}
