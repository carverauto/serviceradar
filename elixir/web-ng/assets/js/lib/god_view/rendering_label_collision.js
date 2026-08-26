export const TOPOLOGY_LABEL_PADDING_PX = 4

const ANCHORS = [
  "top",
  "right",
  "bottom",
  "left",
  "top-right",
  "bottom-right",
  "bottom-left",
  "top-left",
]
const EPSILON = 1e-9

function finiteNumber(value, fallback = 0) {
  const number = Number(value)
  return Number.isFinite(number) ? number : fallback
}

function stableCompare(left, right) {
  const leftValue = String(left)
  const rightValue = String(right)
  if (leftValue < rightValue) return -1
  if (leftValue > rightValue) return 1
  return 0
}

function roleRank(candidate) {
  const role = String(candidate?.role || candidate?.clusterKind || "").trim().toLowerCase()
  if (candidate?.infrastructure === true || role === "infrastructure" || role === "backbone") return 2
  if (candidate?.summary === true || role === "summary" || role === "endpoint-summary") return 1
  return 0
}

function operationalRank(candidate) {
  const explicit = Number(candidate?.operationalRelevance)
  if (Number.isFinite(explicit)) return explicit

  const state = Number(candidate?.state)
  const stateRank = state === 0 ? 3 : state === 1 ? 2 : candidate?.operUp === false || candidate?.operUp === 0 ? 1 : 0
  return (stateRank * 1_000_000_000) + Math.max(0, finiteNumber(candidate?.pps))
}

function compareCandidates(left, right) {
  const leftAttention = left?.selected === true || left?.focused === true ? 1 : 0
  const rightAttention = right?.selected === true || right?.focused === true ? 1 : 0
  if (leftAttention !== rightAttention) return rightAttention - leftAttention

  const roleDifference = roleRank(right) - roleRank(left)
  if (roleDifference !== 0) return roleDifference

  const operationalDifference = operationalRank(right) - operationalRank(left)
  if (operationalDifference !== 0) return operationalDifference

  return stableCompare(left?.nodeId, right?.nodeId)
}

function normalizedBox(box, fallbackPoint = [0, 0]) {
  const x = finiteNumber(fallbackPoint?.[0])
  const y = finiteNumber(fallbackPoint?.[1])
  const left = finiteNumber(box?.left, x - 10)
  const right = finiteNumber(box?.right, x + 10)
  const top = finiteNumber(box?.top, y - 10)
  const bottom = finiteNumber(box?.bottom, y + 10)
  return {
    left: Math.min(left, right),
    right: Math.max(left, right),
    top: Math.min(top, bottom),
    bottom: Math.max(top, bottom),
  }
}

function measuredTextBox(candidate, measureText) {
  const text = String(candidate?.text || "")
  const fontSize = Math.max(1, finiteNumber(candidate?.fontSize, 12))
  let measurement = null
  if (typeof measureText === "function") {
    try {
      measurement = measureText(text, candidate)
    } catch (_error) {
      measurement = null
    }
  }

  const measuredWidth = typeof measurement === "number" ? measurement : Number(measurement?.width)
  const measuredHeight = Number(measurement?.height)
  const metricsHeight = finiteNumber(measurement?.actualBoundingBoxAscent) + finiteNumber(measurement?.actualBoundingBoxDescent)
  const lines = text.split(/\r\n|\r|\n/u)
  const fallbackLineUnits = Math.max(
    1,
    ...lines.map((line) => Array.from(line).reduce((units, codePoint) => units + (codePoint === "\t" ? 4 : 1), 0)),
  )
  // One em per Unicode code point covers full-width/CJK and wide Latin
  // glyphs. Counting combining marks and emoji sequences separately is an
  // intentional overestimate when real canvas metrics are unavailable.
  const fallbackWidth = Math.ceil(fallbackLineUnits * fontSize)
  const fallbackHeight = Math.ceil(Math.max(1, lines.length) * fontSize * 1.25)

  return {
    width: Number.isFinite(measuredWidth) && measuredWidth >= 0 ? measuredWidth : fallbackWidth,
    height: Number.isFinite(measuredHeight) && measuredHeight > 0
      ? measuredHeight
      : metricsHeight > 0
        ? metricsHeight
        : fallbackHeight,
  }
}

function anchorPlacement(candidate, ownerGlyph, metrics, anchor) {
  const point = Array.isArray(candidate?.point) ? candidate.point : [0, 0]
  const x = finiteNumber(point[0])
  const y = finiteNumber(point[1])
  const padding = TOPOLOGY_LABEL_PADDING_PX
  const halfWidth = metrics.width / 2
  const halfHeight = metrics.height / 2

  switch (anchor) {
    case "right": {
      const offset = (ownerGlyph.right - x) + padding
      return {
        nodeId: String(candidate.nodeId),
        anchor,
        box: {
          left: ownerGlyph.right,
          top: y - halfHeight - padding,
          right: ownerGlyph.right + metrics.width + (padding * 2),
          bottom: y + halfHeight + padding,
        },
        pixelOffset: [offset, 0],
        textAnchor: "start",
        alignmentBaseline: "center",
      }
    }
    case "bottom": {
      const offset = (ownerGlyph.bottom - y) + padding
      return {
        nodeId: String(candidate.nodeId),
        anchor,
        box: {
          left: x - halfWidth - padding,
          top: ownerGlyph.bottom,
          right: x + halfWidth + padding,
          bottom: ownerGlyph.bottom + metrics.height + (padding * 2),
        },
        pixelOffset: [0, offset],
        textAnchor: "middle",
        alignmentBaseline: "top",
      }
    }
    case "left": {
      const offset = (ownerGlyph.left - x) - padding
      return {
        nodeId: String(candidate.nodeId),
        anchor,
        box: {
          left: ownerGlyph.left - metrics.width - (padding * 2),
          top: y - halfHeight - padding,
          right: ownerGlyph.left,
          bottom: y + halfHeight + padding,
        },
        pixelOffset: [offset, 0],
        textAnchor: "end",
        alignmentBaseline: "center",
      }
    }
    case "top-right": {
      return {
        nodeId: String(candidate.nodeId),
        anchor,
        box: {
          left: ownerGlyph.right,
          top: ownerGlyph.top - metrics.height - (padding * 2),
          right: ownerGlyph.right + metrics.width + (padding * 2),
          bottom: ownerGlyph.top,
        },
        pixelOffset: [(ownerGlyph.right - x) + padding, (ownerGlyph.top - y) - padding],
        textAnchor: "start",
        alignmentBaseline: "bottom",
      }
    }
    case "bottom-right": {
      return {
        nodeId: String(candidate.nodeId),
        anchor,
        box: {
          left: ownerGlyph.right,
          top: ownerGlyph.bottom,
          right: ownerGlyph.right + metrics.width + (padding * 2),
          bottom: ownerGlyph.bottom + metrics.height + (padding * 2),
        },
        pixelOffset: [(ownerGlyph.right - x) + padding, (ownerGlyph.bottom - y) + padding],
        textAnchor: "start",
        alignmentBaseline: "top",
      }
    }
    case "bottom-left": {
      return {
        nodeId: String(candidate.nodeId),
        anchor,
        box: {
          left: ownerGlyph.left - metrics.width - (padding * 2),
          top: ownerGlyph.bottom,
          right: ownerGlyph.left,
          bottom: ownerGlyph.bottom + metrics.height + (padding * 2),
        },
        pixelOffset: [(ownerGlyph.left - x) - padding, (ownerGlyph.bottom - y) + padding],
        textAnchor: "end",
        alignmentBaseline: "top",
      }
    }
    case "top-left": {
      return {
        nodeId: String(candidate.nodeId),
        anchor,
        box: {
          left: ownerGlyph.left - metrics.width - (padding * 2),
          top: ownerGlyph.top - metrics.height - (padding * 2),
          right: ownerGlyph.left,
          bottom: ownerGlyph.top,
        },
        pixelOffset: [(ownerGlyph.left - x) - padding, (ownerGlyph.top - y) - padding],
        textAnchor: "end",
        alignmentBaseline: "bottom",
      }
    }
    case "top":
    default: {
      const offset = (ownerGlyph.top - y) - padding
      return {
        nodeId: String(candidate.nodeId),
        anchor: "top",
        box: {
          left: x - halfWidth - padding,
          top: ownerGlyph.top - metrics.height - (padding * 2),
          right: x + halfWidth + padding,
          bottom: ownerGlyph.top,
        },
        pixelOffset: [0, offset],
        textAnchor: "middle",
        alignmentBaseline: "bottom",
      }
    }
  }
}

function boxesIntersect(left, right) {
  return (
    left.left < right.right - EPSILON &&
    left.right > right.left + EPSILON &&
    left.top < right.bottom - EPSILON &&
    left.bottom > right.top + EPSILON
  )
}

function boxInside(box, safeRect) {
  return (
    box.left >= safeRect.left - EPSILON &&
    box.right <= safeRect.right + EPSILON &&
    box.top >= safeRect.top - EPSILON &&
    box.bottom <= safeRect.bottom + EPSILON
  )
}

function pointSegmentDistance(point, start, end) {
  const dx = end[0] - start[0]
  const dy = end[1] - start[1]
  const lengthSquared = (dx * dx) + (dy * dy)
  const projection = lengthSquared <= EPSILON
    ? 0
    : Math.max(0, Math.min(1, (((point[0] - start[0]) * dx) + ((point[1] - start[1]) * dy)) / lengthSquared))
  return Math.hypot(point[0] - (start[0] + (projection * dx)), point[1] - (start[1] + (projection * dy)))
}

function orientation(first, second, third) {
  return ((second[0] - first[0]) * (third[1] - first[1])) - ((second[1] - first[1]) * (third[0] - first[0]))
}

function between(value, first, second) {
  return value >= Math.min(first, second) - EPSILON && value <= Math.max(first, second) + EPSILON
}

function segmentsIntersect(firstStart, firstEnd, secondStart, secondEnd) {
  const firstSideStart = orientation(firstStart, firstEnd, secondStart)
  const firstSideEnd = orientation(firstStart, firstEnd, secondEnd)
  const secondSideStart = orientation(secondStart, secondEnd, firstStart)
  const secondSideEnd = orientation(secondStart, secondEnd, firstEnd)

  if (
    ((firstSideStart > EPSILON && firstSideEnd < -EPSILON) || (firstSideStart < -EPSILON && firstSideEnd > EPSILON)) &&
    ((secondSideStart > EPSILON && secondSideEnd < -EPSILON) || (secondSideStart < -EPSILON && secondSideEnd > EPSILON))
  ) return true

  const onSegment = (start, point, end) =>
    Math.abs(orientation(start, end, point)) <= EPSILON &&
    between(point[0], start[0], end[0]) && between(point[1], start[1], end[1])

  return (
    onSegment(firstStart, secondStart, firstEnd) ||
    onSegment(firstStart, secondEnd, firstEnd) ||
    onSegment(secondStart, firstStart, secondEnd) ||
    onSegment(secondStart, firstEnd, secondEnd)
  )
}

function segmentDistance(firstStart, firstEnd, secondStart, secondEnd) {
  if (segmentsIntersect(firstStart, firstEnd, secondStart, secondEnd)) return 0
  return Math.min(
    pointSegmentDistance(firstStart, secondStart, secondEnd),
    pointSegmentDistance(firstEnd, secondStart, secondEnd),
    pointSegmentDistance(secondStart, firstStart, firstEnd),
    pointSegmentDistance(secondEnd, firstStart, firstEnd),
  )
}

function segmentBoxDistance(start, end, box) {
  const edges = [
    [[box.left, box.top], [box.right, box.top]],
    [[box.right, box.top], [box.right, box.bottom]],
    [[box.right, box.bottom], [box.left, box.bottom]],
    [[box.left, box.bottom], [box.left, box.top]],
  ]
  const inside = (point) =>
    point[0] >= box.left && point[0] <= box.right && point[1] >= box.top && point[1] <= box.bottom
  if (inside(start) || inside(end)) return 0
  return Math.min(...edges.map(([edgeStart, edgeEnd]) => segmentDistance(start, end, edgeStart, edgeEnd)))
}

function boxIntersectsRoute(box, route) {
  const points = Array.isArray(route?.points) ? route.points : []
  const radius = Math.max(0, finiteNumber(route?.strokeWidth, 1) / 2)
  for (let index = 1; index < points.length; index += 1) {
    const start = [finiteNumber(points[index - 1]?.[0]), finiteNumber(points[index - 1]?.[1])]
    const end = [finiteNumber(points[index]?.[0]), finiteNumber(points[index]?.[1])]
    if (segmentBoxDistance(start, end, box) < radius - EPSILON) return true
  }
  return false
}

function pointDistance(first, second) {
  return Math.hypot(
    finiteNumber(first?.[0]) - finiteNumber(second?.[0]),
    finiteNumber(first?.[1]) - finiteNumber(second?.[1]),
  )
}

function inflatedBox(box, amount) {
  return {
    left: finiteNumber(box?.left) - amount,
    top: finiteNumber(box?.top) - amount,
    right: finiteNumber(box?.right) + amount,
    bottom: finiteNumber(box?.bottom) + amount,
  }
}

function pointInsideBox(point, box) {
  return (
    point[0] >= box.left - EPSILON &&
    point[0] <= box.right + EPSILON &&
    point[1] >= box.top - EPSILON &&
    point[1] <= box.bottom + EPSILON
  )
}

// Distance travelled along `points` before the polyline first leaves `box`.
// Zero when it does not start inside. Only this leading run is exempt, so a
// route that leaves and later re-enters is still treated as an obstacle.
function leadingExitDistance(points, box) {
  if (!pointInsideBox(points[0], box)) return 0
  let travelled = 0
  for (let index = 1; index < points.length; index += 1) {
    const start = points[index - 1]
    const end = points[index]
    const segmentLength = pointDistance(start, end)
    if (!(segmentLength > EPSILON)) continue
    if (!pointInsideBox(end, box)) {
      let inside = 0
      let outside = 1
      for (let step = 0; step < 48; step += 1) {
        const mid = (inside + outside) / 2
        const probe = [
          start[0] + ((end[0] - start[0]) * mid),
          start[1] + ((end[1] - start[1]) * mid),
        ]
        if (pointInsideBox(probe, box)) inside = mid
        else outside = mid
      }
      return travelled + (segmentLength * inside)
    }
    travelled += segmentLength
  }
  return travelled
}

function clippedSegment(start, end, startDistance, endDistance, segmentStart, segmentEnd) {
  const segmentLength = segmentEnd - segmentStart
  if (!(segmentLength > EPSILON)) return null
  const startRatio = (startDistance - segmentStart) / segmentLength
  const endRatio = (endDistance - segmentStart) / segmentLength
  return [
    [
      start[0] + ((end[0] - start[0]) * startRatio),
      start[1] + ((end[1] - start[1]) * startRatio),
    ],
    [
      start[0] + ((end[0] - start[0]) * endRatio),
      start[1] + ((end[1] - start[1]) * endRatio),
    ],
  ]
}

function boxIntersectsIncidentRouteOutsideOwnerApproach(box, route, candidate, ownerGlyph) {
  const points = (Array.isArray(route?.points) ? route.points : []).map((point) => [
    finiteNumber(point?.[0]),
    finiteNumber(point?.[1]),
  ])
  if (points.length < 2) return false

  const ownerId = String(candidate?.nodeId ?? "")
  const sourceId = String(route?.sourceId ?? "")
  const targetId = String(route?.targetId ?? "")
  const routeRadius = Math.max(0, finiteNumber(route?.strokeWidth, 1) / 2)
  // Exempt exactly the run an incident route needs to clear the owner's own
  // glyph, measured against the glyph rectangle rather than a corner radius.
  // Anything beyond that is a real obstacle, so a label can never sit on top
  // of its own outgoing route.
  const contactBox = inflatedBox(ownerGlyph, TOPOLOGY_LABEL_PADDING_PX + routeRadius)
  const sourceApproach = sourceId === ownerId ? leadingExitDistance(points, contactBox) : 0
  const targetApproach = targetId === ownerId
    ? leadingExitDistance([...points].reverse(), contactBox)
    : 0

  const cumulative = [0]
  for (let index = 1; index < points.length; index += 1) {
    cumulative.push(cumulative.at(-1) + pointDistance(points[index - 1], points[index]))
  }
  const totalLength = cumulative.at(-1)
  const checkedStart = Math.min(totalLength, sourceApproach)
  const checkedEnd = Math.max(checkedStart, totalLength - targetApproach)

  for (let index = 1; index < points.length; index += 1) {
    const segmentStart = cumulative[index - 1]
    const segmentEnd = cumulative[index]
    const checkStart = Math.max(segmentStart, checkedStart)
    const checkEnd = Math.min(segmentEnd, checkedEnd)
    if (!(checkEnd > checkStart + EPSILON)) continue
    const clipped = clippedSegment(
      points[index - 1],
      points[index],
      checkStart,
      checkEnd,
      segmentStart,
      segmentEnd,
    )
    if (clipped && segmentBoxDistance(clipped[0], clipped[1], box) < routeRadius - EPSILON) return true
  }
  return false
}

function fixedObstacleFree(placement, candidate, glyphBoxes, routeCorridors, safeRect) {
  if (!boxInside(placement.box, safeRect)) return false
  if (glyphBoxes.some((glyph) => glyph.nodeId !== candidate.nodeId && boxesIntersect(placement.box, glyph.box))) return false
  if (routeCorridors.some((route) => {
    const sourceId = String(route?.sourceId ?? "")
    const targetId = String(route?.targetId ?? "")
    const incidentToOwner = sourceId === candidate.nodeId || targetId === candidate.nodeId
    return incidentToOwner
      ? boxIntersectsIncidentRouteOutsideOwnerApproach(
          placement.box,
          route,
          candidate,
          glyphBoxes.find((glyph) => glyph.nodeId === candidate.nodeId)?.box || normalizedBox(null, candidate.point),
        )
      : boxIntersectsRoute(placement.box, route)
  })) return false
  return true
}

/**
 * Deterministically admits fixed-pixel topology labels in CSS-pixel screen space.
 * Candidate budgets are intentionally applied by the caller before this function.
 */
export function admitTopologyLabels({
  candidates = [],
  glyphBoxes = [],
  routeCorridors = [],
  safeRect,
  maximumCount = Number.POSITIVE_INFINITY,
  requiredLabelIds,
  measureText,
} = {}) {
  const normalizedSafeRect = normalizedBox(safeRect, [0, 0])
  const glyphs = glyphBoxes
    .map((glyph) => ({nodeId: String(glyph?.nodeId || ""), box: normalizedBox(glyph)}))
    .filter((glyph) => glyph.nodeId !== "")
  const glyphByNodeId = new Map(glyphs.map((glyph) => [glyph.nodeId, glyph.box]))
  const ordered = candidates
    .filter((candidate) => String(candidate?.nodeId || "") !== "")
    .map((candidate) => ({...candidate, nodeId: String(candidate.nodeId)}))
    .sort(compareCandidates)
  const admitted = []
  const admittedCandidates = new Map()
  const detailsFallbackIds = []
  const parsedMaximumCount = Number(maximumCount)
  const labelLimit = Number.isFinite(parsedMaximumCount)
    ? Math.max(0, Math.floor(parsedMaximumCount))
    : Number.POSITIVE_INFINITY

  for (const candidate of ordered) {
    const point = Array.isArray(candidate.point) ? candidate.point : [0, 0]
    const ownerGlyph = glyphByNodeId.get(candidate.nodeId) || normalizedBox(candidate?.glyphBox, point)
    const metrics = measuredTextBox(candidate, measureText)
    const attention = candidate.selected === true || candidate.focused === true
    let placed = false

    if (admitted.length >= labelLimit) {
      if (attention) detailsFallbackIds.push(candidate.nodeId)
      continue
    }

    for (const anchor of ANCHORS) {
      const placement = anchorPlacement(candidate, ownerGlyph, metrics, anchor)
      if (!fixedObstacleFree(placement, candidate, glyphs, routeCorridors, normalizedSafeRect)) continue

      const conflicts = admitted.filter((item) => boxesIntersect(placement.box, item.box))
      if (conflicts.length === 0) {
        admitted.push(placement)
        admittedCandidates.set(candidate.nodeId, candidate)
        placed = true
        break
      }

      const lowerPriorityConflicts = attention && conflicts.every((item) => {
        const conflictingCandidate = admittedCandidates.get(item.nodeId)
        return conflictingCandidate && compareCandidates(candidate, conflictingCandidate) < 0
      })
      if (!lowerPriorityConflicts) continue

      const conflictingIds = new Set(conflicts.map((item) => item.nodeId))
      for (let index = admitted.length - 1; index >= 0; index -= 1) {
        if (!conflictingIds.has(admitted[index].nodeId)) continue
        admittedCandidates.delete(admitted[index].nodeId)
        admitted.splice(index, 1)
      }
      admitted.push(placement)
      admittedCandidates.set(candidate.nodeId, candidate)
      placed = true
      break
    }

    if (!placed && attention) detailsFallbackIds.push(candidate.nodeId)
  }

  admitted.sort((left, right) => compareCandidates(admittedCandidates.get(left.nodeId), admittedCandidates.get(right.nodeId)))
  detailsFallbackIds.sort((left, right) => stableCompare(left, right))
  const requiredIds = (Array.isArray(requiredLabelIds) ? requiredLabelIds : ordered.map((candidate) => candidate.nodeId))
    .map((nodeId) => String(nodeId || ""))
    .filter((nodeId) => nodeId !== "")
  const admittedIds = new Set(admitted.map((placement) => placement.nodeId))
  const missingRequiredLabelIds = [...new Set(requiredIds)]
    .filter((nodeId) => !admittedIds.has(nodeId))
    .sort(stableCompare)
  return {admitted, detailsFallbackIds, missingRequiredLabelIds}
}
