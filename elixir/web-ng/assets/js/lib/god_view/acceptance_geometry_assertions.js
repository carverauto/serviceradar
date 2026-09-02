const GEOMETRY_EPSILON = 0.01

function routeIdCounts(routeIds) {
  const counts = new Map()
  for (const routeId of routeIds || []) {
    const normalized = String(routeId || "")
    counts.set(normalized, (counts.get(normalized) || 0) + 1)
  }
  return counts
}

function transportRouteFamily(layerId) {
  const normalized = String(layerId || "")
  if (normalized.startsWith("god-view-edges-mantle")) return "mantle"
  if (normalized.startsWith("god-view-edges-crust")) return "crust"
  return null
}

function routeIdMultisetsEqual(left, right) {
  const leftCounts = routeIdCounts(left)
  const rightCounts = routeIdCounts(right)
  const routeIds = new Set([...leftCounts.keys(), ...rightCounts.keys()])
  return [...routeIds].every((routeId) => leftCounts.get(routeId) === rightCounts.get(routeId))
}

export function transportLayerRouteIdViolations(snapshot) {
  const expectedRouteIds = Array.isArray(snapshot?.scenePhysicalRouteIds)
    ? snapshot.scenePhysicalRouteIds.map((routeId) => String(routeId || ""))
    : []
  const renderedLayers = Array.isArray(snapshot?.renderedPhysicalRouteLayers)
    ? snapshot.renderedPhysicalRouteLayers
    : []
  const enabledFamilies = new Set(Array.isArray(snapshot?.enabledTransportRouteFamilies)
    ? snapshot.enabledTransportRouteFamilies.map(String)
    : renderedLayers.map((layer) => transportRouteFamily(layer?.layerId)).filter(Boolean))
  const expectedCounts = routeIdCounts(expectedRouteIds)
  const renderedByFamily = new Map(["mantle", "crust"].map((family) => [family, []]))
  const violations = []

  for (const layer of renderedLayers) {
    const routeIds = Array.isArray(layer?.routeIds) ? layer.routeIds.map((routeId) => String(routeId || "")) : []
    const routeCount = Number(layer?.routeCount)
    if (routeCount !== routeIds.length) {
      violations.push(`layer ${String(layer?.layerId || "")} reports ${routeCount} routes but exposes ${routeIds.length} route IDs`)
    }
    const family = transportRouteFamily(layer?.layerId)
    if (family) renderedByFamily.get(family).push(...routeIds)
  }

  for (const family of ["mantle", "crust"]) {
    if (!enabledFamilies.has(family)) continue
    const renderedCounts = routeIdCounts(renderedByFamily.get(family))
    const routeIds = [...new Set([...expectedCounts.keys(), ...renderedCounts.keys()])]
      .sort((left, right) => left.localeCompare(right))
    for (const routeId of routeIds) {
      const expectedCount = expectedCounts.get(routeId) || 0
      const renderedCount = renderedCounts.get(routeId) || 0
      if (renderedCount === expectedCount) continue
      const displayRouteId = routeId === "" ? "<missing routeId>" : routeId
      violations.push(`${family} route ${displayRouteId} is rendered ${renderedCount} times; expected ${expectedCount}`)
    }
  }

  if (enabledFamilies.has("mantle") && enabledFamilies.has("crust")
    && !routeIdMultisetsEqual(renderedByFamily.get("mantle"), renderedByFamily.get("crust"))) {
    violations.push("mantle and crust route ID multisets differ")
  }
  return violations
}

function orientation(a, b, c) {
  return ((b.x - a.x) * (c.y - a.y)) - ((b.y - a.y) * (c.x - a.x))
}

function samePoint(a, b, epsilon = GEOMETRY_EPSILON) {
  return Math.abs(a.x - b.x) <= epsilon && Math.abs(a.y - b.y) <= epsilon
}

function pointOnSegment(point, start, end, epsilon = GEOMETRY_EPSILON) {
  return Math.abs(orientation(start, end, point)) <= epsilon
    && point.x >= Math.min(start.x, end.x) - epsilon
    && point.x <= Math.max(start.x, end.x) + epsilon
    && point.y >= Math.min(start.y, end.y) - epsilon
    && point.y <= Math.max(start.y, end.y) + epsilon
}

function properSegmentIntersection(a, b, c, d, epsilon = GEOMETRY_EPSILON) {
  const abC = orientation(a, b, c)
  const abD = orientation(a, b, d)
  const cdA = orientation(c, d, a)
  const cdB = orientation(c, d, b)
  return ((abC > epsilon && abD < -epsilon) || (abC < -epsilon && abD > epsilon))
    && ((cdA > epsilon && cdB < -epsilon) || (cdA < -epsilon && cdB > epsilon))
}

function collinearOverlap(a, b, c, d, epsilon = GEOMETRY_EPSILON) {
  if (Math.abs(orientation(a, b, c)) > epsilon || Math.abs(orientation(a, b, d)) > epsilon) return false
  const axis = Math.abs(b.x - a.x) >= Math.abs(b.y - a.y) ? "x" : "y"
  const overlap = Math.min(Math.max(a[axis], b[axis]), Math.max(c[axis], d[axis]))
    - Math.max(Math.min(a[axis], b[axis]), Math.min(c[axis], d[axis]))
  return overlap > epsilon
}

function pointSegmentDistance(point, start, end) {
  const deltaX = end.x - start.x
  const deltaY = end.y - start.y
  const lengthSquared = (deltaX * deltaX) + (deltaY * deltaY)
  if (lengthSquared <= GEOMETRY_EPSILON * GEOMETRY_EPSILON) return Math.hypot(point.x - start.x, point.y - start.y)
  const ratio = Math.max(0, Math.min(1,
    (((point.x - start.x) * deltaX) + ((point.y - start.y) * deltaY)) / lengthSquared,
  ))
  return Math.hypot(point.x - (start.x + (ratio * deltaX)), point.y - (start.y + (ratio * deltaY)))
}

function segmentsTouch(a, b, c, d) {
  if (properSegmentIntersection(a, b, c, d)) return true
  return pointOnSegment(a, c, d)
    || pointOnSegment(b, c, d)
    || pointOnSegment(c, a, b)
    || pointOnSegment(d, a, b)
}

function segmentDistance(a, b, c, d) {
  if (segmentsTouch(a, b, c, d)) return 0
  return Math.min(
    pointSegmentDistance(a, c, d),
    pointSegmentDistance(b, c, d),
    pointSegmentDistance(c, a, b),
    pointSegmentDistance(d, a, b),
  )
}

export function segmentAabbDistance(start, end, box) {
  const inside = (point) => point.x >= box.left && point.x <= box.right
    && point.y >= box.top && point.y <= box.bottom
  if (inside(start) || inside(end)) return 0
  const corners = [
    {x: box.left, y: box.top},
    {x: box.right, y: box.top},
    {x: box.right, y: box.bottom},
    {x: box.left, y: box.bottom},
  ]
  return Math.min(...corners.map((corner, index) =>
    segmentDistance(start, end, corner, corners[(index + 1) % corners.length])))
}

function routeStrokeRadius(route) {
  const strokeWidth = route?.strokeWidth
  if (!Number.isFinite(strokeWidth) || strokeWidth <= 0) {
    throw new RangeError("route must expose a finite positive strokeWidth")
  }
  return strokeWidth / 2
}

export function routeStrokeHitsBox(route, box, boxPadding = 0) {
  const points = Array.isArray(route?.projectedPoints) ? route.projectedPoints : []
  const radius = routeStrokeRadius(route)
  const inflated = {
    left: box.left - boxPadding,
    top: box.top - boxPadding,
    right: box.right + boxPadding,
    bottom: box.bottom + boxPadding,
  }
  for (let index = 1; index < points.length; index += 1) {
    if (segmentAabbDistance(points[index - 1], points[index], inflated) <= radius + GEOMETRY_EPSILON) return true
  }
  return false
}

export function routeInsideSafeRect(route, safeRect, epsilon = GEOMETRY_EPSILON) {
  const radius = routeStrokeRadius(route)
  const points = Array.isArray(route?.projectedPoints) ? route.projectedPoints : []
  if (points.length === 0) return false
  return points.every((point) => point.x - radius >= safeRect.left - epsilon
    && point.y - radius >= safeRect.top - epsilon
    && point.x + radius <= safeRect.right + epsilon
    && point.y + radius <= safeRect.bottom + epsilon)
}

function projectedRouteContactPoints(route) {
  const points = Array.isArray(route?.projectedPoints) ? route.projectedPoints : []
  const contacts = new Map()
  const add = (id, point) => {
    const normalizedId = String(id || "")
    if (normalizedId === "" || !Number.isFinite(point?.x) || !Number.isFinite(point?.y)) return
    contacts.set(normalizedId, point)
  }
  add(route?.sourceContactId || route?.sourceId, points[0])
  add(route?.targetContactId || route?.targetId, points.at(-1))
  for (const junction of route?.junctions || []) {
    add(junction?.id, junction?.projectedPoint)
  }
  return contacts
}

function sharedProjectedJunctions(routeA, routeB) {
  const first = projectedRouteContactPoints(routeA)
  const second = projectedRouteContactPoints(routeB)
  return [...first].flatMap(([id, point]) => {
    const other = second.get(id)
    return other && samePoint(point, other) ? [point] : []
  })
}

function pointAlongSegment(start, end, ratio) {
  return {
    x: start.x + ((end.x - start.x) * ratio),
    y: start.y + ((end.y - start.y) * ratio),
  }
}

function segmentPiecesOutsideJunctions(start, end, junctions, radius) {
  const deltaX = end.x - start.x
  const deltaY = end.y - start.y
  const lengthSquared = (deltaX * deltaX) + (deltaY * deltaY)
  if (lengthSquared <= GEOMETRY_EPSILON * GEOMETRY_EPSILON) return []
  let intervals = [[0, 1]]
  for (const junction of junctions) {
    const offsetX = start.x - junction.x
    const offsetY = start.y - junction.y
    const linear = 2 * ((offsetX * deltaX) + (offsetY * deltaY))
    const constant = (offsetX * offsetX) + (offsetY * offsetY) - (radius * radius)
    const discriminant = (linear * linear) - (4 * lengthSquared * constant)
    if (discriminant < 0) continue
    const root = Math.sqrt(Math.max(0, discriminant))
    const insideStart = Math.max(0, (-linear - root) / (2 * lengthSquared))
    const insideEnd = Math.min(1, (-linear + root) / (2 * lengthSquared))
    if (insideEnd <= insideStart) continue
    intervals = intervals.flatMap(([from, to]) => {
      if (insideEnd <= from || insideStart >= to) return [[from, to]]
      return [
        ...(insideStart > from ? [[from, Math.min(to, insideStart)]] : []),
        ...(insideEnd < to ? [[Math.max(from, insideEnd), to]] : []),
      ]
    })
  }
  return intervals
    .filter(([from, to]) => to - from > GEOMETRY_EPSILON)
    .map(([from, to]) => [
      pointAlongSegment(start, end, from),
      pointAlongSegment(start, end, to),
    ])
}

function projectedRouteSegmentsOutsideSharedJunctions(route, junctions, radius) {
  const points = Array.isArray(route?.projectedPoints) ? route.projectedPoints : []
  const segments = []
  for (let index = 1; index < points.length; index += 1) {
    segments.push(...segmentPiecesOutsideJunctions(
      points[index - 1],
      points[index],
      junctions,
      radius,
    ))
  }
  return segments
}

// Two routes leaving a shared node in different directions necessarily overlap in the
// convergence zone around it: the radial atlas fans two dozen members off a single anchor, so
// every adjacent pair runs together where they leave it. They do not share a projected point --
// each route departs its own place on the anchor's perimeter -- so the exact-junction exclusion
// never saw them. Centre the zone on the meeting place instead and size it by how sharply the
// two diverge: past that distance strokes of this combined width can be clear, so any overlap
// there is a real one. A near-collinear pair is skipped entirely, which is what keeps two routes
// genuinely running along each other detectable.
const MIN_DIVERGENCE_RADIANS = (2 * Math.PI) / 180

function projectedDepartureDirection(route, point) {
  const points = Array.isArray(route?.projectedPoints) ? route.projectedPoints : []
  for (const [from, to] of [[points[0], points[1]], [points.at(-1), points.at(-2)]]) {
    if (!from || !to || !samePoint(point, from)) continue
    const deltaX = to.x - from.x
    const deltaY = to.y - from.y
    const length = Math.hypot(deltaX, deltaY)
    if (length <= GEOMETRY_EPSILON) continue
    return {x: deltaX / length, y: deltaY / length}
  }
  return null
}

function sharedContactConvergences(routeA, routeB, combinedRadius, epsilon) {
  const first = projectedRouteContactPoints(routeA)
  const second = projectedRouteContactPoints(routeB)
  const convergences = []
  for (const [id, point] of first) {
    const other = second.get(id)
    if (!other) continue
    const directionA = projectedDepartureDirection(routeA, point)
    const directionB = projectedDepartureDirection(routeB, other)
    if (!directionA || !directionB) continue
    const dot = Math.min(1, Math.max(-1, (directionA.x * directionB.x) + (directionA.y * directionB.y)))
    const divergence = Math.acos(dot)
    if (divergence < MIN_DIVERGENCE_RADIANS) continue
    const separation = Math.hypot(point.x - other.x, point.y - other.y)
    convergences.push({
      point: {x: (point.x + other.x) / 2, y: (point.y + other.y) / 2},
      radius: (combinedRadius / (2 * Math.sin(divergence / 2))) + separation + epsilon,
    })
  }
  return convergences
}

export function routeStrokesOverlap(routeA, routeB, epsilon = GEOMETRY_EPSILON) {
  const combinedRadius = routeStrokeRadius(routeA) + routeStrokeRadius(routeB)
  const convergences = sharedContactConvergences(routeA, routeB, combinedRadius, epsilon)
  const exclusionPoints = [...sharedProjectedJunctions(routeA, routeB), ...convergences.map((entry) => entry.point)]
  const exclusionRadius = Math.max(combinedRadius + epsilon, ...convergences.map((entry) => entry.radius))
  const firstSegments = projectedRouteSegmentsOutsideSharedJunctions(routeA, exclusionPoints, exclusionRadius)
  const secondSegments = projectedRouteSegmentsOutsideSharedJunctions(routeB, exclusionPoints, exclusionRadius)
  for (const [firstStart, firstEnd] of firstSegments) {
    for (const [secondStart, secondEnd] of secondSegments) {
      if (segmentDistance(firstStart, firstEnd, secondStart, secondEnd) < combinedRadius - epsilon) {
        return true
      }
    }
  }
  return false
}

function routeContactIdsAtPoint(route, point) {
  const points = Array.isArray(route?.points) ? route.points : []
  const ids = new Set()
  if (samePoint(point, points[0])) ids.add(route?.sourceContactId || route?.sourceId)
  if (samePoint(point, points.at(-1))) ids.add(route?.targetContactId || route?.targetId)
  for (const junction of route?.junctions || []) {
    if (junction?.id && samePoint(point, junction.point)) ids.add(junction.id)
  }
  ids.delete(undefined)
  ids.delete("")
  return ids
}

function isDeclaredSharedContact(routeA, routeB, point) {
  const first = routeContactIdsAtPoint(routeA, point)
  const second = routeContactIdsAtPoint(routeB, point)
  return [...first].some((id) => second.has(id))
}

export function routeInteriorsIntersect(routeA, routeB) {
  const pointsA = Array.isArray(routeA?.points) ? routeA.points : []
  const pointsB = Array.isArray(routeB?.points) ? routeB.points : []
  for (let aIndex = 1; aIndex < pointsA.length; aIndex += 1) {
    for (let bIndex = 1; bIndex < pointsB.length; bIndex += 1) {
      const [aStart, aEnd] = [pointsA[aIndex - 1], pointsA[aIndex]]
      const [bStart, bEnd] = [pointsB[bIndex - 1], pointsB[bIndex]]
      if (properSegmentIntersection(aStart, aEnd, bStart, bEnd)) return true
      if (collinearOverlap(aStart, aEnd, bStart, bEnd)) return true

      const contacts = [aStart, aEnd, bStart, bEnd]
        .filter((point, index, all) => all.findIndex((candidate) => samePoint(candidate, point)) === index)
        .filter((point) => pointOnSegment(point, aStart, aEnd) && pointOnSegment(point, bStart, bEnd))
      if (contacts.some((point) => !isDeclaredSharedContact(routeA, routeB, point))) return true
    }
  }
  return false
}

function boxesOverlap(a, b, epsilon = 0.5) {
  return Math.min(a.right, b.right) - Math.max(a.left, b.left) > epsilon
    && Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > epsilon
}

function boxContains(outer, inner, epsilon = 0.5) {
  return inner.left >= outer.left - epsilon
    && inner.top >= outer.top - epsilon
    && inner.right <= outer.right + epsilon
    && inner.bottom <= outer.bottom + epsilon
}

export function groupGeometryViolations(snapshot) {
  const groups = Array.isArray(snapshot?.groups) ? snapshot.groups : []
  const nodes = Array.isArray(snapshot?.nodes) ? snapshot.nodes : []
  const groupById = new Map(groups.map((group) => [group.id, group]))
  const nodeById = new Map(nodes.map((node) => [node.id, node]))
  const isAncestor = (ancestorId, descendantId) => {
    const visited = new Set()
    let current = groupById.get(descendantId)
    while (current?.parentGroupId && !visited.has(current.id)) {
      if (current.parentGroupId === ancestorId) return true
      visited.add(current.id)
      current = groupById.get(current.parentGroupId)
    }
    return false
  }

  const violations = []
  for (let leftIndex = 0; leftIndex < groups.length; leftIndex += 1) {
    const group = groups[leftIndex]
    for (let rightIndex = leftIndex + 1; rightIndex < groups.length; rightIndex += 1) {
      const other = groups[rightIndex]
      if (isAncestor(group.id, other.id) || isAncestor(other.id, group.id)) continue
      if (boxesOverlap(group.box, other.box)) violations.push(`groups ${group.id} and ${other.id} overlap`)
    }

    for (const node of nodes) {
      if (node.groupId === group.id || isAncestor(group.id, node.groupId)) continue
      if (boxesOverlap(group.box, node.box)) violations.push(`group ${group.id} overlaps nonmember ${node.id}`)
    }

    for (const nodeId of [group.gatewayId, ...(group.memberIds || [])].filter(Boolean)) {
      const node = nodeById.get(nodeId)
      if (!node || !boxContains(group.box, node.box)) {
        violations.push(`declared member ${nodeId} is outside group ${group.id}`)
      }
    }
  }
  return violations
}
