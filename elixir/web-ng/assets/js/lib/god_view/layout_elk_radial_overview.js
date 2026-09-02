const SEMANTIC_ENVELOPE = 112
const SYNTHETIC_ENVELOPE = 0
const NODE_SPACING = 96
const SCENE_PADDING = 64
const EPSILON = 0.01
const RADIAL_BASE_RADIUS = SEMANTIC_ENVELOPE * 2
const RADIAL_RADIUS_ATTEMPTS = Object.freeze([
  RADIAL_BASE_RADIUS,
  RADIAL_BASE_RADIUS * 2,
  RADIAL_BASE_RADIUS * 4,
])

class RetryableRadialGeometryError extends Error {
  constructor(message) {
    super(message)
    this.name = "RetryableRadialGeometryError"
  }
}

function isFinitePoint(point) {
  return Number.isFinite(point?.x) && Number.isFinite(point?.y)
}

function canonicalNodeId(value) {
  return value == null ? "" : String(value).trim()
}

function deepFreeze(value) {
  if (!value || typeof value !== "object" || Object.isFrozen(value)) return value
  Object.freeze(value)
  for (const child of Object.values(value)) deepFreeze(child)
  return value
}

function clone(value) {
  if (Array.isArray(value)) return value.map(clone)
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, clone(child)]))
  }
  return value
}

function sortedById(values) {
  return [...(values || [])].sort((left, right) => String(left?.id || "").localeCompare(String(right?.id || "")))
}

function expectedNodes(input) {
  return sortedById(input?.nodes).filter((node) => node && String(node.id || "") !== "")
}

function syntheticIds(input) {
  return new Set(input?.synthetic?.nodeIds || [])
}

function semanticNodes(input) {
  const synthetic = syntheticIds(input)
  return expectedNodes(input).filter((node) => !node.synthetic && !synthetic.has(node.id))
}

function expectedRelations(input) {
  return sortedById(input?.treeRelations).filter((relation) => relation && String(relation.id || "") !== "")
}

function semanticRelations(input) {
  const synthetic = new Set(input?.synthetic?.relationIds || [])
  return expectedRelations(input).filter((relation) => !relation.synthetic && !synthetic.has(relation.id))
}

function nodeDimensions(node, input) {
  const synthetic = Boolean(node.synthetic || syntheticIds(input).has(node.id))
  return {width: synthetic ? SYNTHETIC_ENVELOPE : SEMANTIC_ENVELOPE, height: synthetic ? SYNTHETIC_ENVELOPE : SEMANTIC_ENVELOPE}
}

function assertInput(input) {
  const nodes = expectedNodes(input)
  const nodeIds = new Set()
  for (const node of nodes) {
    if (nodeIds.has(node.id)) throw new Error(`duplicate overview node ${node.id}`)
    nodeIds.add(node.id)
  }

  for (const rootId of input?.roots || []) {
    if (!nodeIds.has(rootId)) throw new Error(`overview root ${rootId} is not represented by a node`)
  }

  for (const relation of expectedRelations(input)) {
    if (!nodeIds.has(relation.sourceId) || !nodeIds.has(relation.targetId)) {
      throw new Error(`overview relation ${relation.id} has an unknown endpoint`)
    }
  }
}

function nodeBox(node) {
  return {
    minX: node.center.x - (node.width / 2),
    minY: node.center.y - (node.height / 2),
    maxX: node.center.x + (node.width / 2),
    maxY: node.center.y + (node.height / 2),
  }
}

function boxesOverlap(left, right) {
  return Math.min(left.maxX, right.maxX) - Math.max(left.minX, right.minX) > EPSILON
    && Math.min(left.maxY, right.maxY) - Math.max(left.minY, right.minY) > EPSILON
}

function pointInOpenBox(point, box) {
  return point.x > box.minX + EPSILON && point.x < box.maxX - EPSILON
    && point.y > box.minY + EPSILON && point.y < box.maxY - EPSILON
}

function orientation(start, end, point) {
  return ((end.x - start.x) * (point.y - start.y)) - ((end.y - start.y) * (point.x - start.x))
}

function pointOnSegment(point, start, end) {
  return Math.abs(orientation(start, end, point)) <= EPSILON
    && point.x >= Math.min(start.x, end.x) - EPSILON
    && point.x <= Math.max(start.x, end.x) + EPSILON
    && point.y >= Math.min(start.y, end.y) - EPSILON
    && point.y <= Math.max(start.y, end.y) + EPSILON
}

function pointsContact(left, right) {
  return Math.hypot(left.x - right.x, left.y - right.y) <= EPSILON
}

function properSegmentIntersection(firstStart, firstEnd, secondStart, secondEnd) {
  const firstStartSide = orientation(secondStart, secondEnd, firstStart)
  const firstEndSide = orientation(secondStart, secondEnd, firstEnd)
  const secondStartSide = orientation(firstStart, firstEnd, secondStart)
  const secondEndSide = orientation(firstStart, firstEnd, secondEnd)
  return ((firstStartSide > EPSILON && firstEndSide < -EPSILON)
    || (firstStartSide < -EPSILON && firstEndSide > EPSILON))
    && ((secondStartSide > EPSILON && secondEndSide < -EPSILON)
      || (secondStartSide < -EPSILON && secondEndSide > EPSILON))
}

function collinearlyOverlap(firstStart, firstEnd, secondStart, secondEnd) {
  if (Math.abs(orientation(firstStart, firstEnd, secondStart)) > EPSILON
    || Math.abs(orientation(firstStart, firstEnd, secondEnd)) > EPSILON) return false
  const axis = Math.abs(firstEnd.x - firstStart.x) >= Math.abs(firstEnd.y - firstStart.y) ? "x" : "y"
  const overlap = Math.min(Math.max(firstStart[axis], firstEnd[axis]), Math.max(secondStart[axis], secondEnd[axis]))
    - Math.max(Math.min(firstStart[axis], firstEnd[axis]), Math.min(secondStart[axis], secondEnd[axis]))
  return overlap > EPSILON
}

function routeEndpointContact(route, nodeId) {
  if (route.sourceId === nodeId) return route.points[0]
  if (route.targetId === nodeId) return route.points.at(-1)
  return null
}

function isSharedSemanticEndpointContact(first, second, point) {
  const commonNodeIds = [first.sourceId, first.targetId].filter((id) => id === second.sourceId || id === second.targetId)
  return commonNodeIds.some((nodeId) => {
    const firstContact = routeEndpointContact(first, nodeId)
    const secondContact = routeEndpointContact(second, nodeId)
    return firstContact && secondContact && pointsContact(point, firstContact) && pointsContact(point, secondContact)
  })
}

function routePairConflict(first, second) {
  for (let firstIndex = 1; firstIndex < first.points.length; firstIndex += 1) {
    const firstStart = first.points[firstIndex - 1]
    const firstEnd = first.points[firstIndex]
    for (let secondIndex = 1; secondIndex < second.points.length; secondIndex += 1) {
      const secondStart = second.points[secondIndex - 1]
      const secondEnd = second.points[secondIndex]
      if (collinearlyOverlap(firstStart, firstEnd, secondStart, secondEnd)) return "overlap"
      if (properSegmentIntersection(firstStart, firstEnd, secondStart, secondEnd)) return "cross"
      const contacts = [firstStart, firstEnd, secondStart, secondEnd]
        .filter((point) => pointOnSegment(point, firstStart, firstEnd) && pointOnSegment(point, secondStart, secondEnd))
      if (contacts.some((point) => !isSharedSemanticEndpointContact(first, second, point))) return "cross"
    }
  }
  return null
}

function segmentIntersectsOpenBox(start, end, box) {
  if (pointInOpenBox(start, box) || pointInOpenBox(end, box)) return true
  const corners = [
    {x: box.minX, y: box.minY},
    {x: box.maxX, y: box.minY},
    {x: box.maxX, y: box.maxY},
    {x: box.minX, y: box.maxY},
  ]
  for (let index = 0; index < corners.length; index += 1) {
    const first = corners[index]
    const second = corners[(index + 1) % corners.length]
    const firstSide = orientation(start, end, first)
    const secondSide = orientation(start, end, second)
    const startSide = orientation(first, second, start)
    const endSide = orientation(first, second, end)
    if (((firstSide > EPSILON && secondSide < -EPSILON) || (firstSide < -EPSILON && secondSide > EPSILON))
      && ((startSide > EPSILON && endSide < -EPSILON) || (startSide < -EPSILON && endSide > EPSILON))) return true
    if (pointOnSegment(first, start, end) || pointOnSegment(second, start, end)) return true
  }
  return false
}

function clippedPoint(from, toward, width, height) {
  const deltaX = toward.x - from.x
  const deltaY = toward.y - from.y
  const candidates = []
  if (Math.abs(deltaX) > EPSILON) candidates.push((width / 2) / Math.abs(deltaX))
  if (Math.abs(deltaY) > EPSILON) candidates.push((height / 2) / Math.abs(deltaY))
  const scale = Math.min(...candidates)
  return {x: from.x + (deltaX * scale), y: from.y + (deltaY * scale)}
}

function chordForRelation(relation, nodeById) {
  const source = nodeById.get(relation.sourceId)
  const target = nodeById.get(relation.targetId)
  if (!source || !target) throw new Error(`relation ${relation.id} has no semantic geometry endpoint`)
  const identicalCenters = Math.abs(source.center.x - target.center.x) <= EPSILON
    && Math.abs(source.center.y - target.center.y) <= EPSILON
  if (identicalCenters) throw new RetryableRadialGeometryError(`relation ${relation.id} has coincident semantic geometry`)
  return [
    clippedPoint(source.center, target.center, source.width, source.height),
    clippedPoint(target.center, source.center, target.width, target.height),
  ]
}

function sceneBounds(nodes, routes) {
  const values = [
    ...nodes.flatMap((node) => {
      const box = nodeBox(node)
      return [{x: box.minX, y: box.minY}, {x: box.maxX, y: box.maxY}]
    }),
    ...routes.flatMap((route) => route.points),
  ]
  if (values.length === 0) return {minX: 0, minY: 0, maxX: 0, maxY: 0}
  return {
    minX: Math.min(...values.map((point) => point.x)),
    minY: Math.min(...values.map((point) => point.y)),
    maxX: Math.max(...values.map((point) => point.x)),
    maxY: Math.max(...values.map((point) => point.y)),
  }
}

function finiteBox(box) {
  return [box?.minX, box?.minY, box?.maxX, box?.maxY].every(Number.isFinite)
    && box.minX <= box.maxX && box.minY <= box.maxY
}

function containsPoint(box, point) {
  return point.x >= box.minX - EPSILON && point.x <= box.maxX + EPSILON
    && point.y >= box.minY - EPSILON && point.y <= box.maxY + EPSILON
}

function indexElkLayout(node, origin, records, edges, isRoot = false) {
  if (!node || typeof node !== "object") return
  const x = isRoot ? (Number.isFinite(node.x) ? node.x : 0) : node.x
  const y = isRoot ? (Number.isFinite(node.y) ? node.y : 0) : node.y
  if (!isRoot && (!Number.isFinite(x) || !Number.isFinite(y))) {
    throw new Error(`missing finite coordinates for node ${node.id}`)
  }
  const currentOrigin = {x: origin.x + x, y: origin.y + y}
  if (!isRoot && node.id) {
    const entries = records.get(node.id) || []
    entries.push({node, origin: currentOrigin})
    records.set(node.id, entries)
  }
  for (const edge of node.edges || []) edges.push(edge)
  for (const child of node.children || []) indexElkLayout(child, currentOrigin, records, edges)
}

export function buildElkRadialOverviewGraph(input, {radius = RADIAL_BASE_RADIUS} = {}) {
  assertInput(input)
  const nodes = expectedNodes(input)
  const semantic = semanticNodes(input)
  const orderById = new Map(semantic.map((node, index) => [node.id, index]))
  const graph = {
    id: "topology-overview",
    layoutOptions: {
      "elk.algorithm": "radial",
      "org.eclipse.elk.radial.centerOnRoot": "true",
      "org.eclipse.elk.radial.sorter": "ID",
      "org.eclipse.elk.radial.radius": String(radius),
      "org.eclipse.elk.radial.compactor": "NONE",
      // Allocate each subtree's wedge by how many leaves it carries, not by the size of the
      // node at its root. Under NODE_SIZE an anchor got the same narrow wedge whether it had
      // one child or an expanded cluster's twenty-four, so the members were crammed into a few
      // degrees and their routes ran together into a single bright fan.
      "org.eclipse.elk.radial.wedgeCriteria": "LEAF_NUMBER",
      "elk.spacing.nodeNode": String(NODE_SPACING),
      "elk.padding": `[top=${SCENE_PADDING},left=${SCENE_PADDING},bottom=${SCENE_PADDING},right=${SCENE_PADDING}]`,
    },
    children: nodes.map((node) => ({
      id: node.id,
      ...nodeDimensions(node, input),
      layoutOptions: {
        "org.eclipse.elk.radial.orderId": orderById.get(node.id) ?? semantic.length,
        "serviceradar.synthetic": String(Boolean(node.synthetic || syntheticIds(input).has(node.id))),
      },
    })),
    edges: expectedRelations(input).map((relation) => ({
      id: relation.id,
      sources: [relation.sourceId],
      targets: [relation.targetId],
    })),
  }
  return graph
}

export function decodeElkRadialOverview(layout, input) {
  assertInput(input)
  const expectedNodeById = new Map(expectedNodes(input).map((node) => [node.id, node]))
  const semanticNodeList = semanticNodes(input)
  const expectedRelationById = new Map(expectedRelations(input).map((relation) => [relation.id, relation]))
  const semanticRelationList = semanticRelations(input)
  const records = new Map()
  const elkEdges = []
  indexElkLayout(layout, {x: 0, y: 0}, records, elkEdges, true)

  for (const [id, entries] of records) {
    if (!expectedNodeById.has(id)) throw new Error(`unknown ELK node ${id}`)
    if (entries.length > 1) {
      const descriptor = syntheticIds(input).has(id) ? "synthetic node" : "semantic node"
      throw new Error(`duplicate ELK geometry for ${descriptor} ${id}`)
    }
  }

  const nodes = semanticNodeList.map((sourceNode) => {
    const entry = records.get(sourceNode.id)?.[0]
    if (!entry) throw new Error(`missing geometry for semantic node ${sourceNode.id}`)
    const width = entry.node.width
    const height = entry.node.height
    if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
      throw new Error(`missing finite dimensions for node ${sourceNode.id}`)
    }
    if (Math.abs(width - SEMANTIC_ENVELOPE) > EPSILON || Math.abs(height - SEMANTIC_ENVELOPE) > EPSILON) {
      throw new Error(`unexpected ELK envelope for node ${sourceNode.id}`)
    }
    return {
      id: sourceNode.id,
      center: {x: entry.origin.x + (width / 2), y: entry.origin.y + (height / 2)},
      width,
      height,
      groupId: null,
      render: true,
      label: sourceNode.label || sourceNode.id,
      role: sourceNode.role,
      type: sourceNode.type,
    }
  })

  const seenEdges = new Map()
  for (const edge of elkEdges) {
    const relation = expectedRelationById.get(edge?.id)
    if (!relation) throw new Error(`unknown ELK edge ${edge?.id}`)
    const entries = seenEdges.get(edge.id) || []
    entries.push(edge)
    seenEdges.set(edge.id, entries)
    if (!Array.isArray(edge.sources) || !Array.isArray(edge.targets)
      || edge.sources.length !== 1 || edge.targets.length !== 1
      || edge.sources[0] !== relation.sourceId || edge.targets[0] !== relation.targetId) {
      throw new Error(`ELK edge ${edge.id} has an invalid semantic binding`)
    }
  }
  for (const relation of semanticRelationList) {
    const entries = seenEdges.get(relation.id) || []
    if (entries.length === 0) throw new Error(`missing ELK geometry for semantic relation ${relation.id}`)
    if (entries.length > 1) throw new Error(`duplicate ELK geometry for semantic relation ${relation.id}`)
  }

  const nodeById = new Map(nodes.map((node) => [node.id, node]))
  const routes = semanticRelationList.map((relation) => ({
    id: relation.id,
    sourceId: relation.sourceId,
    targetId: relation.targetId,
    relationIds: clone(relation.semanticRelationIds || []),
    semanticRelationIds: clone(relation.semanticRelationIds || []),
    evidence: clone(relation.evidence || []),
    pairId: relation.pairId,
    points: chordForRelation(relation, nodeById),
  }))
  const scene = {
    nodes,
    groups: [],
    routes,
    physicalRoutes: routes,
    manifolds: [],
    crossLinks: clone(input?.crossLinks || []),
    bounds: sceneBounds(nodes, routes),
    key: `${input?.graphKey || ""}:radial-overview`,
    graphKey: input?.graphKey,
    profileKey: "radial-overview",
    manifest: clone(input?.manifest || {}),
  }
  return deepFreeze(scene)
}

export function validateTopologyOverview(scene, input) {
  const errors = []
  const expectedNodeIds = new Set(semanticNodes(input).map((node) => node.id))
  const expectedRouteIds = new Set(semanticRelations(input).map((relation) => relation.id))
  const crossLinkIds = new Set((input?.crossLinks || []).map((relation) => relation.id))
  const nodes = Array.isArray(scene?.nodes) ? scene.nodes : []
  const routes = Array.isArray(scene?.routes) ? scene.routes : []
  const physicalRoutes = Array.isArray(scene?.physicalRoutes) ? scene.physicalRoutes : routes
  const nodeById = new Map()

  if (!Array.isArray(scene?.groups) || scene.groups.length !== 0) errors.push("overview scene must not expose groups")
  if (!Array.isArray(scene?.manifolds) || scene.manifolds.length !== 0) errors.push("overview scene must not expose manifolds")
  if (!finiteBox(scene?.bounds)) errors.push("overview bounds have non-finite geometry")

  for (const node of nodes) {
    if (!expectedNodeIds.has(node?.id)) errors.push(`synthetic or unknown node ${node?.id} leaked into overview scene`)
    if (nodeById.has(node?.id)) errors.push(`duplicate semantic geometry for node ${node?.id}`)
    nodeById.set(node?.id, node)
    if (!isFinitePoint(node?.center) || !Number.isFinite(node?.width) || !Number.isFinite(node?.height)
      || node.width <= 0 || node.height <= 0) errors.push(`node ${node?.id} has non-finite geometry`)
  }
  for (const id of expectedNodeIds) {
    if (!nodeById.has(id)) errors.push(`missing semantic geometry for node ${id}`)
  }
  if (nodes.length !== expectedNodeIds.size) errors.push("overview scene has an unexpected semantic glyph count")

  for (let index = 0; index < nodes.length; index += 1) {
    const left = nodes[index]
    if (!isFinitePoint(left?.center) || !Number.isFinite(left?.width) || !Number.isFinite(left?.height)) continue
    const leftBox = nodeBox(left)
    if (!containsPoint(scene.bounds, {x: leftBox.minX, y: leftBox.minY})
      || !containsPoint(scene.bounds, {x: leftBox.maxX, y: leftBox.maxY})) errors.push(`bounds omit node ${left.id} envelope`)
    for (const right of nodes.slice(index + 1)) {
      if (isFinitePoint(right?.center) && Number.isFinite(right?.width) && Number.isFinite(right?.height)
        && boxesOverlap(leftBox, nodeBox(right))) errors.push(`semantic nodes ${left.id} and ${right.id} overlap`)
    }
  }

  const routeCounts = new Map()
  for (const route of physicalRoutes) {
    routeCounts.set(route?.id, (routeCounts.get(route?.id) || 0) + 1)
    if (crossLinkIds.has(route?.id) || !expectedRouteIds.has(route?.id)) {
      errors.push(`synthetic, cross-link, or unknown route ${route?.id} leaked into overview scene`)
    }
    if (!Array.isArray(route?.points) || route.points.length !== 2 || !route.points.every(isFinitePoint)) {
      errors.push(`route ${route?.id} has non-finite geometry`)
      continue
    }
    if (Math.hypot(route.points[0].x - route.points[1].x, route.points[0].y - route.points[1].y) <= EPSILON) {
      errors.push(`route ${route.id} has coincident points`)
    }
    for (const point of route.points) {
      if (!containsPoint(scene.bounds, point)) errors.push(`bounds omit route ${route.id}`)
    }
    for (const node of nodes) {
      if (node.id === route.sourceId || node.id === route.targetId) continue
      if (isFinitePoint(node?.center) && Number.isFinite(node?.width) && Number.isFinite(node?.height)
        && segmentIntersectsOpenBox(route.points[0], route.points[1], nodeBox(node))) {
        errors.push(`route ${route.id} intersects nonincident node ${node.id}`)
      }
    }
  }
  for (const id of expectedRouteIds) {
    const count = routeCounts.get(id) || 0
    if (count !== 1) errors.push(`expected semantic route ${id} has ${count} geometry records`)
  }
  if (routes.length !== expectedRouteIds.size || physicalRoutes.length !== expectedRouteIds.size) {
    errors.push("overview scene has an unexpected semantic route count")
  }
  for (let leftIndex = 0; leftIndex < physicalRoutes.length; leftIndex += 1) {
    const left = physicalRoutes[leftIndex]
    if (!Array.isArray(left?.points) || !left.points.every(isFinitePoint)) continue
    for (const right of physicalRoutes.slice(leftIndex + 1)) {
      if (!Array.isArray(right?.points) || !right.points.every(isFinitePoint)) continue
      const conflict = routePairConflict(left, right)
      if (conflict === "overlap") errors.push(`routes ${left.id} and ${right.id} have overlapping interiors`)
      if (conflict === "cross") errors.push(`routes ${left.id} and ${right.id} cross`)
    }
  }

  return deepFreeze({ok: errors.length === 0, errors})
}

// The fixed ladder was sized for a backbone-only atlas. An expanded cluster puts its members
// on the rings too, and a ring only holds so much: with N nodes competing for one circle the
// circumference has to clear N * (envelope + spacing), or ELK packs them tight enough that
// routes start clipping the nodes they pass and the scene fails validation. Grow the base
// radius with the graph and keep the ladder as escalation from there.
function radialRadiusAttempts(input) {
  const nodeCount = Math.max(1, expectedNodes(input).length)
  const circumferenceRadius = Math.ceil((nodeCount * (SEMANTIC_ENVELOPE + NODE_SPACING)) / (2 * Math.PI))
  const base = Math.max(RADIAL_BASE_RADIUS, circumferenceRadius)
  return [base, base * 2, base * 4]
}

export async function layoutTopologyOverview(input, elk) {
  if (!elk || typeof elk.layout !== "function") throw new Error("ELK layout engine is unavailable")
  let lastFailure = "unknown geometry failure"
  for (const radius of radialRadiusAttempts(input)) {
    const layout = await elk.layout(buildElkRadialOverviewGraph(input, {radius}))
    try {
      const scene = decodeElkRadialOverview(layout, input)
      const validation = validateTopologyOverview(scene, input)
      if (validation.ok) return scene
      lastFailure = validation.errors.join("; ") || lastFailure
    } catch (error) {
      if (!(error instanceof RetryableRadialGeometryError)) throw error
      lastFailure = error.message
    }
  }
  throw new Error(`invalid radial topology overview: ${lastFailure}`)
}

export function applyTopologyOverviewToGraph(graph, scene) {
  const sceneNodeById = new Map((scene?.nodes || []).map((node) => [canonicalNodeId(node.id), node]))
  const copiedGraph = clone(graph || {})
  const nodes = (copiedGraph.nodes || []).map((node) => {
    const geometry = sceneNodeById.get(canonicalNodeId(node?.id))
    return geometry ? {...node, x: geometry.center.x, y: geometry.center.y} : {...node}
  })
  return deepFreeze({
    ...copiedGraph,
    nodes,
    _topologyScene: scene,
    _layoutMode: "elk-radial-overview",
  })
}
