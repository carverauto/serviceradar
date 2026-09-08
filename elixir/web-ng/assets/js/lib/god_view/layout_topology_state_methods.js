import ELK from "elkjs/lib/elk.bundled.js"

import {
  applyTopologySceneToGraph,
  layoutTopologyScene,
  viewportProfileForSize,
} from "./layout_elk_scene"
import {
  applyTopologyOverviewToGraph,
  layoutTopologyOverview,
} from "./layout_elk_radial_overview"
import {prepareTopologyOverviewInput} from "./topology_overview_projection"
import {prepareTopologySceneInput} from "./topology_scene_graph"
import {
  hasManagedTopologyScene,
  TOPOLOGY_DETAIL_MODE,
  TOPOLOGY_OVERVIEW_MODE,
  topologySemanticLevel,
} from "./topology_layout_mode"
import {topologyRelationId} from "./topology_relation_identity"

let defaultLayoutEngine = null
const MAX_LAYOUT_CACHE_ENTRIES = 12
const LAYOUT_WIDTH = 640
const LAYOUT_HEIGHT = 320
const LAYOUT_PAD = 20
const RADIAL_OVERVIEW_PROFILE = Object.freeze({key: "radial-overview"})

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
  const existingX = Number(existing?.x)
  const existingY = Number(existing?.y)
  const incomingX = Number(incoming?.x)
  const incomingY = Number(incoming?.y)
  return {
    ...existing,
    ...incoming,
    x: Number.isFinite(existingX) ? existingX : (Number.isFinite(incomingX) ? incomingX : 0),
    y: Number.isFinite(existingY) ? existingY : (Number.isFinite(incomingY) ? incomingY : 0),
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
    details: {
      ...existingDetails,
      ...incomingDetails,
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

function immutableTopologyScene(value) {
  if (!value || typeof value !== "object" || Object.isFrozen(value)) return value
  for (const child of Object.values(value)) immutableTopologyScene(child)
  return Object.freeze(value)
}

function cloneTopologyValue(value) {
  if (Array.isArray(value)) return value.map(cloneTopologyValue)
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, child]) => [key, cloneTopologyValue(child)]),
    )
  }
  return value
}

function overviewGeometryGraphKey(input) {
  const nodes = (input?.nodes || [])
    .map((node) => ({id: node.id, synthetic: node.synthetic === true}))
    .sort((left, right) => left.id.localeCompare(right.id))
  const treeRelations = (input?.treeRelations || [])
    .map((relation) => ({
      id: relation.id,
      sourceId: relation.sourceId,
      targetId: relation.targetId,
      synthetic: relation.synthetic === true,
    }))
    .sort((left, right) => left.id.localeCompare(right.id))
  return JSON.stringify({
    nodes,
    roots: [...(input?.roots || [])].sort((left, right) => left.localeCompare(right)),
    treeRelations,
  })
}

function topologySceneGeometry(scene) {
  if (!scene || typeof scene !== "object") return null
  return {
    nodes: (scene.nodes || []).map((node) => ({
      id: node.id,
      center: {...node.center},
      width: node.width,
      height: node.height,
    })),
    groups: (scene.groups || []).map((group) => ({
      id: group.id,
      bounds: {...group.bounds},
    })),
    routes: (scene.routes || []).map((route) => ({
      id: route.id,
      points: (route.points || []).map((point) => ({...point})),
      sourceContactId: route.sourceContactId,
      targetContactId: route.targetContactId,
      sourceManifoldId: route.sourceManifoldId,
      targetManifoldId: route.targetManifoldId,
      junctions: (route.junctions || []).map((junction) => ({
        id: junction.id,
        point: {...junction.point},
      })),
    })),
    manifolds: (scene.manifolds || []).map((manifold) => ({
      ...manifold,
      nodeContact: {...manifold.nodeContact},
      trunkContact: {...manifold.trunkContact},
      trunkPoints: (manifold.trunkPoints || []).map((point) => ({...point})),
      railPoints: (manifold.railPoints || []).map((point) => ({...point})),
      branchContacts: (manifold.branchContacts || []).map((branch) => ({
        ...branch,
        point: {...branch.point},
      })),
      relationIds: undefined,
    })),
    auxiliaryRoutes: (scene.physicalRoutes || []).filter((route) => route.auxiliary).map((route) => ({
      ...route,
      points: (route.points || []).map((point) => ({...point})),
      junctions: (route.junctions || []).map((junction) => ({
        id: junction.id,
        point: {...junction.point},
      })),
      relationIds: undefined,
      metadata: undefined,
    })),
    bounds: {...scene.bounds},
  }
}

function detailTopologySceneFromGeometry(sceneInput, profile, geometry) {
  if (!geometry || typeof geometry !== "object") return null

  const nodeGeometry = new Map((geometry.nodes || []).map((node) => [node.id, node]))
  const groupGeometry = new Map((geometry.groups || []).map((group) => [group.id, group]))
  const routeGeometry = new Map((geometry.routes || []).map((route) => [route.id, route]))
  const currentNodes = Array.isArray(sceneInput?.nodes) ? sceneInput.nodes : []
  const currentGroups = (sceneInput?.groups || []).filter((group) => group.expanded)
  const currentRoutes = Array.isArray(sceneInput?.renderedRelations) ? sceneInput.renderedRelations : []

  if (
    nodeGeometry.size !== currentNodes.length ||
    groupGeometry.size !== currentGroups.length ||
    routeGeometry.size !== currentRoutes.length
  ) return null

  const nodes = currentNodes.map((node) => {
    const cached = nodeGeometry.get(node.id)
    if (!cached) return null
    return {
      id: node.id,
      center: cached.center,
      width: cached.width,
      height: cached.height,
      groupId: node.groupId,
      render: node.render,
    }
  })
  const groups = currentGroups.map((group) => {
    const cached = groupGeometry.get(group.id)
    if (!cached) return null
    return {
      id: group.id,
      bounds: cached.bounds,
      memberIds: [...(group.memberIds || [])].sort((left, right) => left.localeCompare(right)),
      anchorId: group.anchorId,
      gatewayId: group.gatewayId,
    }
  })
  const routes = currentRoutes.map((route) => {
    const cached = routeGeometry.get(route.id)
    if (!cached) return null
    return {
      id: route.id,
      sourceId: route.sourceId,
      targetId: route.targetId,
      points: cached.points,
      sourceContactId: cached.sourceContactId,
      targetContactId: cached.targetContactId,
      ...(cached.sourceManifoldId ? {sourceManifoldId: cached.sourceManifoldId} : {}),
      ...(cached.targetManifoldId ? {targetManifoldId: cached.targetManifoldId} : {}),
      junctions: cached.junctions || [],
      relationIds: [...(route.relationIds || [])].sort((left, right) => left.localeCompare(right)),
      metadata: route.metadata && typeof route.metadata === "object" ? {...route.metadata} : {},
    }
  })
  if (nodes.includes(null) || groups.includes(null) || routes.includes(null)) return null

  const currentRouteById = new Map(routes.map((route) => [route.id, route]))
  const relationIdsForRoutes = (routeIds) => Array.from(new Set((routeIds || []).flatMap(
    (routeId) => currentRouteById.get(routeId)?.relationIds || [],
  ))).sort((left, right) => left.localeCompare(right))
  const manifolds = (geometry.manifolds || []).map((manifold) => ({
    ...manifold,
    relationIds: relationIdsForRoutes(manifold.semanticRouteIds),
  }))
  const auxiliaryRoutes = (geometry.auxiliaryRoutes || []).map((route) => ({
    ...route,
    relationIds: relationIdsForRoutes(route.semanticRouteIds),
    metadata: {},
  }))
  const physicalRoutes = [...routes, ...auxiliaryRoutes]

  return immutableTopologyScene({
    nodes,
    groups,
    routes,
    manifolds,
    physicalRoutes,
    bounds: geometry.bounds,
    key: `${sceneInput.graphKey}:${profile.key}`,
    graphKey: sceneInput.graphKey,
    profileKey: profile.key,
    manifest: {...sceneInput.manifest},
  })
}

function overviewTopologySceneFromGeometry(sceneInput, profile, geometry) {
  if (!geometry || typeof geometry !== "object") return null

  const syntheticNodeIds = new Set(sceneInput?.synthetic?.nodeIds || [])
  const syntheticRelationIds = new Set(sceneInput?.synthetic?.relationIds || [])
  const currentNodes = (sceneInput?.nodes || [])
    .filter((node) => !node?.synthetic && !syntheticNodeIds.has(node?.id))
    .sort((left, right) => left.id.localeCompare(right.id))
  const currentRoutes = (sceneInput?.treeRelations || [])
    .filter((route) => !route?.synthetic && !syntheticRelationIds.has(route?.id))
    .sort((left, right) => left.id.localeCompare(right.id))
  const nodeGeometry = new Map((geometry.nodes || []).map((node) => [node.id, node]))
  const routeGeometry = new Map((geometry.routes || []).map((route) => [route.id, route]))
  if (nodeGeometry.size !== currentNodes.length || routeGeometry.size !== currentRoutes.length) return null

  const nodes = currentNodes.map((node) => {
    const cached = nodeGeometry.get(node.id)
    if (!cached) return null
    return {
      id: node.id,
      center: cached.center,
      width: cached.width,
      height: cached.height,
      groupId: null,
      render: true,
      label: node.label || node.id,
      role: node.role,
      type: node.type,
    }
  })
  const routes = currentRoutes.map((route) => {
    const cached = routeGeometry.get(route.id)
    if (!cached) return null
    return {
      id: route.id,
      sourceId: route.sourceId,
      targetId: route.targetId,
      relationIds: cloneTopologyValue(route.semanticRelationIds || []),
      semanticRelationIds: cloneTopologyValue(route.semanticRelationIds || []),
      evidence: cloneTopologyValue(route.evidence || []),
      pairId: route.pairId,
      points: cached.points,
    }
  })
  if (nodes.includes(null) || routes.includes(null)) return null

  return immutableTopologyScene({
    nodes,
    groups: [],
    routes,
    physicalRoutes: routes,
    manifolds: [],
    crossLinks: cloneTopologyValue(sceneInput?.crossLinks || []),
    bounds: geometry.bounds,
    key: `${sceneInput.graphKey}:${profile.key}`,
    graphKey: sceneInput.graphKey,
    profileKey: profile.key,
    manifest: cloneTopologyValue(sceneInput?.manifest || {}),
  })
}

function topologySceneFromGeometry(sceneInput, profile, geometry, semanticLevel) {
  return semanticLevel === "detail"
    ? detailTopologySceneFromGeometry(sceneInput, profile, geometry)
    : overviewTopologySceneFromGeometry(sceneInput, profile, geometry)
}

function topologyLayoutAdapter(graph, state) {
  const semanticLevel = topologySemanticLevel(graph)
  if (semanticLevel === "detail") {
    const profile = viewportProfileForSize(
      state.viewportWidth,
      state.viewportHeight,
      state.viewportSafeInsets,
    )
    return {
      semanticLevel,
      mode: TOPOLOGY_DETAIL_MODE,
      errorMode: `${TOPOLOGY_DETAIL_MODE}-error`,
      input: prepareTopologySceneInput(graph),
      profile,
      apply: applyTopologySceneToGraph,
      layout: (input, engine) => layoutTopologyScene(input, {engine, profile}),
    }
  }

  return {
    semanticLevel,
    mode: TOPOLOGY_OVERVIEW_MODE,
    errorMode: `${TOPOLOGY_OVERVIEW_MODE}-error`,
    input: prepareTopologyOverviewInput(graph),
    profile: RADIAL_OVERVIEW_PROFILE,
    apply: applyTopologyOverviewToGraph,
    layout: (input, engine) => layoutTopologyOverview(input, engine),
  }
}

function stripCoordinates(graph) {
  const {
    _topologyScene,
    _layoutMode,
    _layoutCacheKey,
    _layoutRevision,
    _layoutError,
    ...withoutLayoutAnnotations
  } = graph || {}
  return {
    ...withoutLayoutAnnotations,
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

  async prepareGraphLayout(graph, revision, topologyStamp, {commit = true} = {}) {
    const {state} = this
    if (!graph || !Array.isArray(graph.nodes) || !Array.isArray(graph.edges)) return graph

    const deduped = this.dedupeGraphById(graph)
    const adapter = topologyLayoutAdapter(deduped, state)
    const {input: sceneInput, profile, semanticLevel} = adapter
    const cacheGraphKey = semanticLevel === "overview"
      ? overviewGeometryGraphKey(sceneInput)
      : sceneInput.graphKey
    const layoutKey = this.graphLayoutCacheKey(
      sceneInput,
      profile,
      semanticLevel,
      cacheGraphKey,
    )
    const cachedGeometry = this.getCachedGraphLayout(layoutKey)
    const cachedScene = topologySceneFromGeometry(sceneInput, profile, cachedGeometry, semanticLevel)

    if (cachedScene) {
      const cachedGraph = {
        ...adapter.apply(stripCoordinates(deduped), cachedScene),
        _layoutRevision: revision,
        _layoutCacheKey: layoutKey,
      }
      if (hasManagedTopologyScene(cachedGraph)) {
        if (commit) {
          state.layoutMode = cachedGraph._layoutMode
          state.layoutRevision = revision
          state.lastLayoutKey = layoutKey
        }
        return cachedGraph
      }
    }

    const finalGraph = await this.computeClientTopologyLayout(
      deduped,
      sceneInput,
      layoutKey,
      profile,
      revision,
      adapter,
    )

    if (finalGraph._topologyScene && !finalGraph._layoutError) {
      this.storeCachedGraphLayout(layoutKey, finalGraph._topologyScene)
    }
    if (commit) {
      state.layoutMode = finalGraph._layoutMode
      state.layoutRevision = revision
      state.lastLayoutKey = layoutKey
    }
    return finalGraph
  },

  graphLayoutCacheKey(sceneInput, profile, semanticLevel, graphKey = sceneInput.graphKey) {
    return `${semanticLevel}:${profile.key}:${graphKey}`
  },

  getCachedGraphLayout(layoutKey) {
    const cache = this.state.layoutCache
    if (!(cache instanceof Map)) return null
    return cache.get(layoutKey) || null
  },

  storeCachedGraphLayout(layoutKey, scene) {
    const {state} = this
    if (!(state.layoutCache instanceof Map)) state.layoutCache = new Map()
    const geometry = topologySceneGeometry(scene)
    if (!geometry) return
    state.layoutCache.set(layoutKey, immutableTopologyScene(geometry))
    while (state.layoutCache.size > MAX_LAYOUT_CACHE_ENTRIES) {
      state.layoutCache.delete(state.layoutCache.keys().next().value)
    }
  },

  async computeClientTopologyLayout(graph, sceneInput, layoutKey, profile, revision, adapter) {
    try {
      const engine = this.state.layoutEngine || getDefaultLayoutEngine()
      const scene = immutableTopologyScene(await adapter.layout(sceneInput, engine))
      return {
        ...adapter.apply(stripCoordinates(graph), scene),
        _layoutRevision: revision,
        _layoutCacheKey: layoutKey,
      }
    } catch (error) {
      const diagnostic = layoutErrorMessage(error)
      const previousGraph = this.state.lastGraph
      const compatible =
        previousGraph?._layoutCacheKey === layoutKey &&
        previousGraph?._layoutMode === adapter.mode &&
        topologySemanticLevel(previousGraph) === adapter.semanticLevel &&
        hasManagedTopologyScene(previousGraph)
      const previousGeometry = compatible
        ? topologySceneGeometry(previousGraph._topologyScene)
        : null
      const recoveredScene = topologySceneFromGeometry(
        sceneInput,
        profile,
        previousGeometry,
        adapter.semanticLevel,
      )

      if (recoveredScene) {
        const recoveredGraph = {
          ...adapter.apply(stripCoordinates(graph), recoveredScene),
          _layoutRevision: revision,
          _layoutCacheKey: layoutKey,
          _layoutError: diagnostic,
        }
        if (hasManagedTopologyScene(recoveredGraph)) return recoveredGraph
      }

      return {
        ...stripCoordinates(graph),
        _layoutMode: adapter.errorMode,
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
    for (const edge of graph.edges) {
      const source = originalToDeduped[Number(edge?.source)]
      const target = originalToDeduped[Number(edge?.target)]
      if (!Number.isInteger(source) || !Number.isInteger(target) || source === target) continue
      const remapped = {...edge, source, target}
      edges.push({...remapped, id: topologyRelationId(remapped, nodes)})
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
