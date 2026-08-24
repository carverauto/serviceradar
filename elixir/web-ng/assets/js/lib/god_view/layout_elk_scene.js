const DEFAULT_VIEWPORT_WIDTH = 1280
const DEFAULT_VIEWPORT_HEIGHT = 720
const LANDSCAPE_ASPECT_THRESHOLD = 1.2
const COMPOUND_PADDING = 48
const SIBLING_SPACING = 96
// ELK works in world units while route strokes and glyph halos remain fixed CSS
// pixels. Matching the sibling corridor keeps fitted routes clear of 20px halos.
const ROUTE_CLEARANCE = 96
const INTERSECTION_EPSILON = 0.01
const FIXED_RANDOM_SEED = 1729

export const LANDSCAPE_PROFILE = Object.freeze({
  key: "landscape",
  direction: "RIGHT",
  targetAspectRatio: 1.6,
})

export const PORTRAIT_PROFILE = Object.freeze({
  key: "portrait",
  direction: "DOWN",
  targetAspectRatio: 0.75,
})

function finiteNonNegative(value) {
  const number = Number(value)
  return Number.isFinite(number) ? Math.max(0, number) : 0
}

export function viewportProfileForSize(width, height, safeInsets = {}) {
  const viewportWidth = Number.isFinite(Number(width)) && Number(width) > 0
    ? Number(width)
    : DEFAULT_VIEWPORT_WIDTH
  const viewportHeight = Number.isFinite(Number(height)) && Number(height) > 0
    ? Number(height)
    : DEFAULT_VIEWPORT_HEIGHT
  const usableWidth = Math.max(
    1,
    viewportWidth - finiteNonNegative(safeInsets?.left) - finiteNonNegative(safeInsets?.right),
  )
  const usableHeight = Math.max(
    1,
    viewportHeight - finiteNonNegative(safeInsets?.top) - finiteNonNegative(safeInsets?.bottom),
  )

  return usableWidth / usableHeight >= LANDSCAPE_ASPECT_THRESHOLD
    ? LANDSCAPE_PROFILE
    : PORTRAIT_PROFILE
}

function elkLayoutOptions(profile, kind) {
  return {
    "elk.algorithm": "layered",
    "elk.hierarchyHandling": "INCLUDE_CHILDREN",
    "elk.edgeRouting": "ORTHOGONAL",
    "elk.direction": profile.direction,
    "elk.aspectRatio": String(profile.targetAspectRatio),
    "elk.randomSeed": String(FIXED_RANDOM_SEED),
    "elk.spacing.nodeNode": String(SIBLING_SPACING),
    "elk.spacing.edgeNode": String(ROUTE_CLEARANCE),
    "elk.spacing.edgeEdge": String(ROUTE_CLEARANCE * 2),
    "elk.spacing.componentComponent": String(SIBLING_SPACING),
    "elk.layered.spacing.nodeNodeBetweenLayers": String(SIBLING_SPACING),
    "elk.layered.spacing.edgeNodeBetweenLayers": String(ROUTE_CLEARANCE),
    "elk.layered.spacing.edgeEdgeBetweenLayers": String(ROUTE_CLEARANCE * 2),
    "elk.layered.crossingMinimization.strategy": "LAYER_SWEEP",
    "elk.layered.nodePlacement.strategy": "NETWORK_SIMPLEX",
    "elk.padding": `[top=${COMPOUND_PADDING},left=${COMPOUND_PADDING},bottom=${COMPOUND_PADDING},right=${COMPOUND_PADDING}]`,
    ...(kind ? {"serviceradar.kind": kind} : {}),
  }
}

function dimensionsForNode(node) {
  // A collapsed summary can render a 45.875px halo. Its larger invisible ELK
  // envelope prevents fitted routes from entering that fixed-pixel glyph.
  if (node.kind === "endpoint-summary") return {width: 448, height: 448}
  if (node.kind === "endpoint-member") return {width: 96, height: 96}
  return {width: 112, height: 112}
}

function elkLeaf(node) {
  return {
    id: node.id,
    ...dimensionsForNode(node),
    layoutOptions: {
      "serviceradar.kind": node.kind,
      "serviceradar.render": String(node.render),
    },
  }
}

function relationEdge(relation, render) {
  return {
    id: relation.id,
    sources: [relation.sourceId],
    targets: [relation.targetId],
    layoutOptions: {
      "serviceradar.render": String(render),
    },
  }
}

export function buildElkSceneGraph(sceneInput, profile = LANDSCAPE_PROFILE) {
  const nodes = [...(sceneInput?.nodes || [])].sort((left, right) => left.id.localeCompare(right.id))
  const nodeById = new Map(nodes.map((node) => [node.id, node]))
  const expandedGroups = [...(sceneInput?.groups || [])]
    .filter((group) => group.expanded)
    .sort((left, right) => left.id.localeCompare(right.id))
  const expandedGroupIds = new Set(expandedGroups.map((group) => group.id))
  const groupedNodeIds = new Set()

  const compoundChildren = expandedGroups.map((group) => {
    const childIds = [group.gatewayId, ...(group.memberIds || [])]
      .filter((id) => nodeById.has(id))
      .sort((left, right) => left.localeCompare(right))
    childIds.forEach((id) => groupedNodeIds.add(id))

    return {
      id: group.id,
      layoutOptions: elkLayoutOptions(profile, "endpoint-group"),
      children: childIds.map((id) => elkLeaf(nodeById.get(id))),
    }
  })

  const rootLeaves = nodes
    .filter((node) => !groupedNodeIds.has(node.id) && !expandedGroupIds.has(node.groupId))
    .map(elkLeaf)
  const edges = [
    ...(sceneInput?.renderedRelations || []).map((relation) => relationEdge(relation, true)),
    ...(sceneInput?.layoutRelations || []).map((relation) => relationEdge(relation, false)),
  ].sort((left, right) => left.id.localeCompare(right.id))

  return {
    id: "god-view-root",
    layoutOptions: elkLayoutOptions(profile),
    children: [...rootLeaves, ...compoundChildren].sort((left, right) => left.id.localeCompare(right.id)),
    edges,
  }
}

function finiteOrNaN(value) {
  const number = Number(value)
  return Number.isFinite(number) ? number : Number.NaN
}

function indexElkResult(node, parentOrigin, elements, edgeOwners) {
  if (!node || typeof node !== "object") return
  const origin = {
    x: parentOrigin.x + finiteOrNaN(node.x ?? 0),
    y: parentOrigin.y + finiteOrNaN(node.y ?? 0),
  }
  elements.set(node.id, {node, origin})

  for (const edge of node.edges || []) {
    const candidates = edgeOwners.get(edge.id) || []
    candidates.push({edge, ownerId: node.id})
    edgeOwners.set(edge.id, candidates)
  }
  for (const child of node.children || []) indexElkResult(child, origin, elements, edgeOwners)
}

function decodedPoints(edge, ownerId, elements) {
  if (!edge || !Array.isArray(edge.sections) || edge.sections.length !== 1) return []
  const section = edge.sections[0]
  const origin = elements.get(edge.container || ownerId)?.origin || {x: Number.NaN, y: Number.NaN}
  const rawPoints = [section?.startPoint, ...(section?.bendPoints || []), section?.endPoint]

  return rawPoints.map((point) => ({
    x: origin.x + finiteOrNaN(point?.x),
    y: origin.y + finiteOrNaN(point?.y),
  }))
}

function renderedEdgeEndpointBindingError(edge, relation) {
  if (!edge) return null
  const sourcesMatch = Array.isArray(edge.sources)
    && edge.sources.length === 1
    && edge.sources[0] === relation.sourceId
  const targetsMatch = Array.isArray(edge.targets)
    && edge.targets.length === 1
    && edge.targets[0] === relation.targetId
  if (sourcesMatch && targetsMatch) return null
  return `route ${relation.id} has invalid ELK endpoint binding; expected exactly ${relation.sourceId} -> ${relation.targetId}`
}

function boxForNode(node) {
  return {
    minX: node.center.x - node.width / 2,
    minY: node.center.y - node.height / 2,
    maxX: node.center.x + node.width / 2,
    maxY: node.center.y + node.height / 2,
  }
}

function sceneBounds(nodes, groups, routes) {
  const values = []
  for (const node of nodes) values.push(boxForNode(node))
  for (const group of groups) values.push(group.bounds)
  for (const route of routes) {
    for (const point of route.points) {
      values.push({minX: point.x, minY: point.y, maxX: point.x, maxY: point.y})
    }
  }

  if (values.length === 0) return {minX: 0, minY: 0, maxX: 0, maxY: 0}
  return {
    minX: Math.min(...values.map((value) => value.minX)),
    minY: Math.min(...values.map((value) => value.minY)),
    maxX: Math.max(...values.map((value) => value.maxX)),
    maxY: Math.max(...values.map((value) => value.maxY)),
  }
}

export function decodeElkScene(elkResult, sceneInput) {
  const elements = new Map()
  const edgeOwners = new Map()
  indexElkResult(elkResult, {x: 0, y: 0}, elements, edgeOwners)

  const nodes = [...(sceneInput?.nodes || [])]
    .map((sceneNode) => {
      const decoded = elements.get(sceneNode.id)
      const width = finiteOrNaN(decoded?.node?.width)
      const height = finiteOrNaN(decoded?.node?.height)
      return {
        id: sceneNode.id,
        center: {
          x: decoded?.origin.x + width / 2,
          y: decoded?.origin.y + height / 2,
        },
        width,
        height,
        groupId: sceneNode.groupId,
        render: sceneNode.render,
      }
    })
    .sort((left, right) => left.id.localeCompare(right.id))

  const groups = [...(sceneInput?.groups || [])]
    .filter((group) => group.expanded)
    .map((group) => {
      const decoded = elements.get(group.id)
      const width = finiteOrNaN(decoded?.node?.width)
      const height = finiteOrNaN(decoded?.node?.height)
      const originX = finiteOrNaN(decoded?.origin?.x)
      const originY = finiteOrNaN(decoded?.origin?.y)
      return {
        id: group.id,
        bounds: {
          minX: originX,
          minY: originY,
          maxX: originX + width,
          maxY: originY + height,
        },
        memberIds: [...(group.memberIds || [])].sort((left, right) => left.localeCompare(right)),
        anchorId: group.anchorId,
        gatewayId: group.gatewayId,
      }
    })
    .sort((left, right) => left.id.localeCompare(right.id))

  const routes = [...(sceneInput?.renderedRelations || [])]
    .map((relation) => {
      const candidates = edgeOwners.get(relation.id) || []
      const decoded = candidates.length === 1 ? candidates[0] : null
      const endpointBindingError = renderedEdgeEndpointBindingError(decoded?.edge, relation)
      return {
        id: relation.id,
        sourceId: relation.sourceId,
        targetId: relation.targetId,
        points: decodedPoints(decoded?.edge, decoded?.ownerId, elements),
        relationIds: [...(relation.relationIds || [])].sort((left, right) => left.localeCompare(right)),
        metadata: relation.metadata && typeof relation.metadata === "object" ? {...relation.metadata} : {},
        ...(endpointBindingError ? {endpointBindingError} : {}),
      }
    })
    .sort((left, right) => left.id.localeCompare(right.id))

  return {
    nodes,
    groups,
    routes,
    bounds: sceneBounds(nodes, groups, routes),
  }
}

function finiteBox(box) {
  return [box?.minX, box?.minY, box?.maxX, box?.maxY].every(Number.isFinite)
}

function boxesOverlap(left, right) {
  return (
    Math.min(left.maxX, right.maxX) - Math.max(left.minX, right.minX) > INTERSECTION_EPSILON &&
    Math.min(left.maxY, right.maxY) - Math.max(left.minY, right.minY) > INTERSECTION_EPSILON
  )
}

function boxContains(outer, inner) {
  return (
    inner.minX >= outer.minX - INTERSECTION_EPSILON &&
    inner.minY >= outer.minY - INTERSECTION_EPSILON &&
    inner.maxX <= outer.maxX + INTERSECTION_EPSILON &&
    inner.maxY <= outer.maxY + INTERSECTION_EPSILON
  )
}

function segmentIntersectsOpenBox(start, end, box) {
  const interior = {
    minX: box.minX - ROUTE_CLEARANCE + INTERSECTION_EPSILON,
    minY: box.minY - ROUTE_CLEARANCE + INTERSECTION_EPSILON,
    maxX: box.maxX + ROUTE_CLEARANCE - INTERSECTION_EPSILON,
    maxY: box.maxY + ROUTE_CLEARANCE - INTERSECTION_EPSILON,
  }
  let lower = 0
  let upper = 1

  for (const axis of ["x", "y"]) {
    const delta = end[axis] - start[axis]
    const minimum = interior[`min${axis.toUpperCase()}`]
    const maximum = interior[`max${axis.toUpperCase()}`]
    if (Math.abs(delta) <= INTERSECTION_EPSILON) {
      if (start[axis] <= minimum || start[axis] >= maximum) return false
      continue
    }

    const first = (minimum - start[axis]) / delta
    const second = (maximum - start[axis]) / delta
    lower = Math.max(lower, Math.min(first, second))
    upper = Math.min(upper, Math.max(first, second))
    if (lower >= upper - INTERSECTION_EPSILON) return false
  }

  return upper > INTERSECTION_EPSILON && lower < 1 - INTERSECTION_EPSILON
}

function routeIntersectsBox(route, box) {
  for (let index = 1; index < route.points.length; index += 1) {
    if (segmentIntersectsOpenBox(route.points[index - 1], route.points[index], box)) return true
  }
  return false
}

function hasDistinctRoutePoints(points) {
  for (let leftIndex = 0; leftIndex < points.length; leftIndex += 1) {
    for (let rightIndex = leftIndex + 1; rightIndex < points.length; rightIndex += 1) {
      const deltaX = points[rightIndex].x - points[leftIndex].x
      const deltaY = points[rightIndex].y - points[leftIndex].y
      if (Math.hypot(deltaX, deltaY) > INTERSECTION_EPSILON) return true
    }
  }
  return false
}

function pointContactsBoxBoundary(point, box) {
  if (!point || !finiteBox(box)) return false
  const withinX = point.x >= box.minX - INTERSECTION_EPSILON
    && point.x <= box.maxX + INTERSECTION_EPSILON
  const withinY = point.y >= box.minY - INTERSECTION_EPSILON
    && point.y <= box.maxY + INTERSECTION_EPSILON
  if (!withinX || !withinY) return false

  return Math.abs(point.x - box.minX) <= INTERSECTION_EPSILON
    || Math.abs(point.x - box.maxX) <= INTERSECTION_EPSILON
    || Math.abs(point.y - box.minY) <= INTERSECTION_EPSILON
    || Math.abs(point.y - box.maxY) <= INTERSECTION_EPSILON
}

export function validateTopologyScene(scene) {
  const errors = []
  const nodes = Array.isArray(scene?.nodes) ? scene.nodes : []
  const groups = Array.isArray(scene?.groups) ? scene.groups : []
  const routes = Array.isArray(scene?.routes) ? scene.routes : []
  const nodeById = new Map(nodes.map((node) => [node.id, node]))
  const nodeBoxes = new Map()

  for (const node of nodes) {
    const values = [node.center?.x, node.center?.y, node.width, node.height]
    if (!values.every(Number.isFinite) || node.width <= 0 || node.height <= 0) {
      errors.push(`node ${node.id} has non-finite geometry`)
      continue
    }
    nodeBoxes.set(node.id, boxForNode(node))
  }

  for (const group of groups) {
    if (!finiteBox(group.bounds)) errors.push(`group ${group.id} has non-finite geometry`)
  }
  if (!finiteBox(scene?.bounds)) errors.push("scene bounds have non-finite geometry")

  for (let leftIndex = 0; leftIndex < nodes.length; leftIndex += 1) {
    for (let rightIndex = leftIndex + 1; rightIndex < nodes.length; rightIndex += 1) {
      const left = nodes[leftIndex]
      const right = nodes[rightIndex]
      const leftBox = nodeBoxes.get(left.id)
      const rightBox = nodeBoxes.get(right.id)
      if (leftBox && rightBox && boxesOverlap(leftBox, rightBox)) {
        errors.push(`non-nested nodes ${left.id} and ${right.id} overlap`)
      }
    }
  }

  for (let leftIndex = 0; leftIndex < groups.length; leftIndex += 1) {
    const left = groups[leftIndex]
    if (!finiteBox(left.bounds)) continue
    for (let rightIndex = leftIndex + 1; rightIndex < groups.length; rightIndex += 1) {
      const right = groups[rightIndex]
      if (finiteBox(right.bounds) && boxesOverlap(left.bounds, right.bounds)) {
        errors.push(`non-nested groups ${left.id} and ${right.id} overlap`)
      }
    }
    for (const node of nodes) {
      const nodeBox = nodeBoxes.get(node.id)
      if (node.groupId !== left.id && nodeBox && boxesOverlap(left.bounds, nodeBox)) {
        errors.push(`non-nested group ${left.id} and node ${node.id} overlap`)
      }
    }

    for (const nodeId of [left.gatewayId, ...(left.memberIds || [])]) {
      const memberBox = nodeBoxes.get(nodeId)
      if (!memberBox || !boxContains(left.bounds, memberBox)) {
        errors.push(`node ${nodeId} is outside group ${left.id}`)
      }
    }
  }

  for (const route of routes) {
    if (route.endpointBindingError) {
      errors.push(route.endpointBindingError)
      continue
    }
    if (!Array.isArray(route.points) || route.points.length < 2) {
      errors.push(`route ${route.id} must decode from exactly one continuous section`)
      continue
    }
    if (!route.points.every((point) => Number.isFinite(point?.x) && Number.isFinite(point?.y))) {
      errors.push(`route ${route.id} has non-finite geometry`)
      continue
    }
    if (!hasDistinctRoutePoints(route.points)) {
      errors.push(`route ${route.id} must decode from exactly one continuous section`)
      continue
    }

    const sourceBox = nodeBoxes.get(route.sourceId)
    const targetBox = nodeBoxes.get(route.targetId)
    if (!pointContactsBoxBoundary(route.points[0], sourceBox)) {
      errors.push(`route ${route.id} does not contact source endpoint ${route.sourceId} boundary within ${INTERSECTION_EPSILON}`)
    }
    if (!pointContactsBoxBoundary(route.points.at(-1), targetBox)) {
      errors.push(`route ${route.id} does not contact target endpoint ${route.targetId} boundary within ${INTERSECTION_EPSILON}`)
    }

    for (const node of nodes) {
      if (node.id === route.sourceId || node.id === route.targetId) continue
      const box = nodeBoxes.get(node.id)
      if (box && routeIntersectsBox(route, box)) {
        errors.push(`route ${route.id} intersects nonincident node ${node.id}`)
      }
    }

    for (const group of groups) {
      const sourceGroupId = nodeById.get(route.sourceId)?.groupId
      const targetGroupId = nodeById.get(route.targetId)?.groupId
      if (
        group.id === route.sourceId ||
        group.id === route.targetId ||
        group.id === sourceGroupId ||
        group.id === targetGroupId
      ) continue
      if (finiteBox(group.bounds) && routeIntersectsBox(route, group.bounds)) {
        errors.push(`route ${route.id} intersects nonincident group ${group.id}`)
      }
    }
  }

  return {ok: errors.length === 0, errors}
}

export async function layoutTopologyScene(
  sceneInput,
  {engine, profile = LANDSCAPE_PROFILE} = {},
) {
  if (!engine || typeof engine.layout !== "function") throw new Error("ELK layout engine is unavailable")
  const elkResult = await engine.layout(buildElkSceneGraph(sceneInput, profile))
  const decoded = decodeElkScene(elkResult, sceneInput)
  const validation = validateTopologyScene(decoded)
  if (!validation.ok) {
    throw new Error(`invalid topology scene: ${validation.errors.join("; ")}`)
  }

  return {
    ...decoded,
    key: `${sceneInput.graphKey}:${profile.key}`,
    graphKey: sceneInput.graphKey,
    profileKey: profile.key,
    manifest: {...sceneInput.manifest},
  }
}

export function applyTopologySceneToGraph(graph, scene) {
  const sceneNodeById = new Map((scene?.nodes || []).map((node) => [node.id, node]))
  const nodes = (graph?.nodes || []).map((node) => {
    const sceneNode = sceneNodeById.get(node.id)
    if (!sceneNode) return node
    return {
      ...node,
      x: sceneNode.center.x,
      y: sceneNode.center.y,
    }
  })

  return {
    ...graph,
    nodes,
    _topologyScene: scene,
    _layoutMode: "elk-scene",
  }
}
