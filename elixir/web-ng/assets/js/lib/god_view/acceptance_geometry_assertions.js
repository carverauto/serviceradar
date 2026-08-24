const GEOMETRY_EPSILON = 0.01

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

export function routeStrokeHitsBox(route, box, boxPadding = 0) {
  const points = Array.isArray(route?.projectedPoints) ? route.projectedPoints : []
  const radius = Math.max(0, Number(route?.strokeWidth) || 0) / 2
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
  const points = Array.isArray(route?.projectedPoints) ? route.projectedPoints : []
  if (points.length === 0) return false
  const radius = Math.max(0, Number(route?.strokeWidth) || 0) / 2
  return points.every((point) => point.x - radius >= safeRect.left - epsilon
    && point.y - radius >= safeRect.top - epsilon
    && point.x + radius <= safeRect.right + epsilon
    && point.y + radius <= safeRect.bottom + epsilon)
}

function semanticEndpoint(route, nodeId) {
  const points = Array.isArray(route?.points) ? route.points : []
  if (nodeId === route?.sourceId) return points[0]
  if (nodeId === route?.targetId) return points.at(-1)
  return null
}

function isGenuineSharedEndpoint(routeA, routeB, point) {
  const sharedIds = [routeA?.sourceId, routeA?.targetId]
    .filter((id) => id && (id === routeB?.sourceId || id === routeB?.targetId))
  return sharedIds.some((id) => {
    const endpointA = semanticEndpoint(routeA, id)
    const endpointB = semanticEndpoint(routeB, id)
    return endpointA && endpointB && samePoint(endpointA, endpointB) && samePoint(point, endpointA)
  })
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
      if (contacts.some((point) => !isGenuineSharedEndpoint(routeA, routeB, point))) return true
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
