import {
  fitTopologyScene,
  focusTopologyGroup,
  measureGodViewSafeRect,
  normalizeGodViewSafeRect,
  topologyGroupFocusScene,
} from "./rendering_scene_view"
import {ROUTE_CLEARANCE} from "./layout_elk_scene"
import {
  MANAGED_VISUAL_DENSITY_PREFERENCE,
  managedNodeVisualRole,
  managedVisualDensityContract,
} from "./rendering_managed_visual_density"
import {hasExpandedCluster, hasManagedTopologyScene, topologySemanticLevel} from "./topology_layout_mode"

const MANAGED_DENSITY_LAYOUT_CACHE_LIMIT = 8
const MANAGED_ABSOLUTE_MIN_ZOOM = -24

function nodeDetails(node) {
  return node?.details && typeof node.details === "object" ? node.details : {}
}

function clusterKindForNode(node) {
  const clusterKind = nodeDetails(node).cluster_kind
  return typeof clusterKind === "string" && clusterKind.trim() !== "" ? clusterKind.trim() : ""
}

function isEndpointMemberNode(node) {
  return clusterKindForNode(node) === "endpoint-member"
}

function isExpandedEndpointMemberNode(node) {
  return isEndpointMemberNode(node) && nodeDetails(node).cluster_expanded === true
}

function isEndpointSummaryNode(node) {
  return clusterKindForNode(node) === "endpoint-summary"
}

function isEndpointAnchorNode(node) {
  return clusterKindForNode(node) === "endpoint-anchor"
}

function isUnplacedNode(node) {
  const details = nodeDetails(node)
  return details.topology_unplaced === true || String(details.topology_plane || "").trim() === "unplaced"
}

function frameNodeRadius(node) {
  if (isEndpointSummaryNode(node)) return 44
  if (isEndpointAnchorNode(node)) return 32
  if (isExpandedEndpointMemberNode(node)) return 36
  if (isEndpointMemberNode(node)) return 16
  return 28
}

function isInfrastructureOverviewNode(node) {
  return !isEndpointMemberNode(node) && !isEndpointSummaryNode(node) && !isUnplacedNode(node)
}

function preferredAutoFitZoomTier(graph) {
  return graph?._layoutMode === "client-radial" ? "local" : null
}

function managedGraphNodes(graph) {
  return new Map((graph?.nodes || []).map((node, index) => [String(node?.id || ""), {node, index}]))
}

function managedGlyphBox(context, graphNodes, sceneNode, managedVisualDensity) {
  const nodeId = String(sceneNode?.id || "")
  const graphNode = graphNodes.get(nodeId)?.node
  if (!graphNode || typeof context.nodeVisibleOuterRadiusPixels !== "function") {
    throw new RangeError(`managed topology node ${nodeId} has no renderer-derived glyph extents`)
  }
  const radius = Number(context.nodeVisibleOuterRadiusPixels(graphNode, {managedVisualDensity}))
  if (!Number.isFinite(radius) || radius <= 0) {
    throw new RangeError(`managed topology node ${nodeId} has invalid renderer-derived glyph extents`)
  }
  return {nodeId: sceneNode.id, width: radius * 2, height: radius * 2}
}

function managedGlyphSpecs(context, graph, graphNodes, managedVisualDensity) {
  return (graph?._topologyScene?.nodes || []).flatMap((sceneNode) => {
    if (sceneNode?.render === false) return []
    const entry = graphNodes.get(String(sceneNode?.id || ""))
    if (!entry) return []
    const glyph = managedGlyphBox(context, graphNodes, sceneNode, managedVisualDensity)
    return [{
      nodeId: String(sceneNode.id || ""),
      role: managedNodeVisualRole(entry.node),
      worldX: Number(sceneNode?.center?.x),
      worldY: Number(sceneNode?.center?.y),
      halfWidth: Number(glyph.width) / 2,
      halfHeight: Number(glyph.height) / 2,
    }]
  })
}

function managedGlyphSeparationConstraint(specs) {
  let limiting = {
    scale: 0,
    leftId: "",
    rightId: "",
    axis: "x",
    limitingRolePair: [],
  }
  for (let leftIndex = 0; leftIndex < specs.length; leftIndex += 1) {
    for (let rightIndex = leftIndex + 1; rightIndex < specs.length; rightIndex += 1) {
      const left = specs[leftIndex]
      const right = specs[rightIndex]
      const distanceX = Math.abs(right.worldX - left.worldX)
      const distanceY = Math.abs(right.worldY - left.worldY)
      const requiredX = left.halfWidth + right.halfWidth
      const requiredY = left.halfHeight + right.halfHeight
      const scaleX = distanceX > 0 ? requiredX / distanceX : Number.POSITIVE_INFINITY
      const scaleY = distanceY > 0 ? requiredY / distanceY : Number.POSITIVE_INFINITY
      const axis = scaleX <= scaleY ? "x" : "y"
      const scale = Math.min(scaleX, scaleY)
      if (scale > limiting.scale) {
        limiting = {
          scale,
          leftId: left.nodeId,
          rightId: right.nodeId,
          axis,
          limitingRolePair: [left.role, right.role],
        }
      }
    }
  }
  return limiting
}

function closestPointOnSegment(point, start, end) {
  const segmentX = end.x - start.x
  const segmentY = end.y - start.y
  const lengthSquared = (segmentX * segmentX) + (segmentY * segmentY)
  if (!(lengthSquared > 0)) return null
  const projection = (
    ((point.x - start.x) * segmentX) +
    ((point.y - start.y) * segmentY)
  ) / lengthSquared
  const t = Math.max(0, Math.min(1, projection))
  return {x: start.x + (segmentX * t), y: start.y + (segmentY * t)}
}

function finiteRoutePoints(route) {
  return (route?.points || []).flatMap((point) => {
    const x = Number(point?.x)
    const y = Number(point?.y)
    return Number.isFinite(x) && Number.isFinite(y) ? [{x, y}] : []
  })
}

function pointToSegmentSeparation(point, start, end) {
  const closest = closestPointOnSegment(point, start, end)
  return closest
    ? {distance: Math.hypot(point.x - closest.x, point.y - closest.y), point, closest}
    : {distance: Number.POSITIVE_INFINITY, point, closest: null}
}

function segmentSeparation(leftStart, leftEnd, rightStart, rightEnd) {
  const leftVector = {x: leftEnd.x - leftStart.x, y: leftEnd.y - leftStart.y}
  const rightVector = {x: rightEnd.x - rightStart.x, y: rightEnd.y - rightStart.y}
  const betweenStarts = {x: leftStart.x - rightStart.x, y: leftStart.y - rightStart.y}
  const dot = (left, right) => (left.x * right.x) + (left.y * right.y)
  const leftLengthSquared = dot(leftVector, leftVector)
  const rightLengthSquared = dot(rightVector, rightVector)

  if (!(leftLengthSquared > 0)) {
    const result = pointToSegmentSeparation(leftStart, rightStart, rightEnd)
    return {distance: result.distance, leftPoint: leftStart, rightPoint: result.closest}
  }
  if (!(rightLengthSquared > 0)) {
    const result = pointToSegmentSeparation(rightStart, leftStart, leftEnd)
    return {distance: result.distance, leftPoint: result.closest, rightPoint: rightStart}
  }

  const vectorDot = dot(leftVector, rightVector)
  const leftStartDot = dot(leftVector, betweenStarts)
  const rightStartDot = dot(rightVector, betweenStarts)
  const denominator = (leftLengthSquared * rightLengthSquared) - (vectorDot * vectorDot)
  const denominatorTolerance = Number.EPSILON * Math.max(
    1,
    Math.abs(leftLengthSquared * rightLengthSquared),
    Math.abs(vectorDot * vectorDot),
  ) * 64
  let leftNumerator
  let leftDenominator = denominator
  let rightNumerator
  let rightDenominator = denominator

  if (Math.abs(denominator) <= denominatorTolerance) {
    leftNumerator = 0
    leftDenominator = 1
    rightNumerator = rightStartDot
    rightDenominator = rightLengthSquared
  } else {
    leftNumerator = (vectorDot * rightStartDot) - (rightLengthSquared * leftStartDot)
    rightNumerator = (leftLengthSquared * rightStartDot) - (vectorDot * leftStartDot)
    if (leftNumerator < 0) {
      leftNumerator = 0
      rightNumerator = rightStartDot
      rightDenominator = rightLengthSquared
    } else if (leftNumerator > leftDenominator) {
      leftNumerator = leftDenominator
      rightNumerator = rightStartDot + vectorDot
      rightDenominator = rightLengthSquared
    }
  }

  if (rightNumerator < 0) {
    rightNumerator = 0
    if (-leftStartDot < 0) {
      leftNumerator = 0
    } else if (-leftStartDot > leftLengthSquared) {
      leftNumerator = leftDenominator
    } else {
      leftNumerator = -leftStartDot
      leftDenominator = leftLengthSquared
    }
  } else if (rightNumerator > rightDenominator) {
    rightNumerator = rightDenominator
    if ((-leftStartDot + vectorDot) < 0) {
      leftNumerator = 0
    } else if ((-leftStartDot + vectorDot) > leftLengthSquared) {
      leftNumerator = leftDenominator
    } else {
      leftNumerator = -leftStartDot + vectorDot
      leftDenominator = leftLengthSquared
    }
  }

  const leftParameter = leftNumerator === 0 ? 0 : leftNumerator / leftDenominator
  const rightParameter = rightNumerator === 0 ? 0 : rightNumerator / rightDenominator
  const leftPoint = {
    x: leftStart.x + (leftParameter * leftVector.x),
    y: leftStart.y + (leftParameter * leftVector.y),
  }
  const rightPoint = {
    x: rightStart.x + (rightParameter * rightVector.x),
    y: rightStart.y + (rightParameter * rightVector.y),
  }
  const rawDistance = Math.hypot(leftPoint.x - rightPoint.x, leftPoint.y - rightPoint.y)
  const coordinateScale = Math.max(
    1,
    Math.abs(leftStart.x),
    Math.abs(leftStart.y),
    Math.abs(leftEnd.x),
    Math.abs(leftEnd.y),
    Math.abs(rightStart.x),
    Math.abs(rightStart.y),
    Math.abs(rightEnd.x),
    Math.abs(rightEnd.y),
  )
  const numericContactTolerance = Number.EPSILON * coordinateScale * 64
  return {
    distance: rawDistance <= numericContactTolerance ? 0 : rawDistance,
    leftPoint,
    rightPoint,
  }
}

function managedRouteGlyphClearanceConstraint(graph, specs, managedVisualDensity) {
  const routeRadius = managedVisualDensityContract(managedVisualDensity).routeMaxWidth / 2
  let limiting = {
    scale: 0,
    leftId: "",
    rightId: "",
    axis: "normal",
    limitingRolePair: [],
  }

  for (const route of graph?._topologyScene?.physicalRoutes || graph?._topologyScene?.routes || []) {
    const routeId = String(route?.id || "")
    const sourceId = String(route?.sourceId || "")
    const targetId = String(route?.targetId || "")
    const incidentNodeIds = new Set(route?.incidentNodeIds || [sourceId, targetId])
    const points = finiteRoutePoints(route)
    for (const spec of specs) {
      if (incidentNodeIds.has(spec.nodeId)) continue
      for (let pointIndex = 1; pointIndex < points.length; pointIndex += 1) {
        const closest = closestPointOnSegment(
          {x: spec.worldX, y: spec.worldY},
          points[pointIndex - 1],
          points[pointIndex],
        )
        if (!closest) continue
        const offsetX = spec.worldX - closest.x
        const offsetY = spec.worldY - closest.y
        const worldDistance = Math.hypot(offsetX, offsetY)
        const requiredPixels = worldDistance > 0
          ? (
              (Math.abs(offsetX / worldDistance) * spec.halfWidth) +
              (Math.abs(offsetY / worldDistance) * spec.halfHeight) +
              routeRadius
            )
          : spec.halfWidth + spec.halfHeight + routeRadius
        const scale = worldDistance > 0
          ? requiredPixels / worldDistance
          : Number.POSITIVE_INFINITY
        if (scale > limiting.scale) {
          limiting = {
            scale,
            leftId: routeId,
            rightId: spec.nodeId,
            axis: "normal",
            limitingRolePair: ["route", spec.role],
            limitingKind: "route-glyph",
            routeId,
            nodeId: spec.nodeId,
          }
        }
      }
    }
  }

  return limiting
}

function routePathMetrics(points) {
  const cumulativeLengths = [0]
  for (let pointIndex = 1; pointIndex < points.length; pointIndex += 1) {
    cumulativeLengths.push(
      cumulativeLengths.at(-1) + Math.hypot(
        points[pointIndex].x - points[pointIndex - 1].x,
        points[pointIndex].y - points[pointIndex - 1].y,
      ),
    )
  }
  return {cumulativeLengths, totalLength: cumulativeLengths.at(-1) || 0}
}

function endpointEnvelopeRadii(scene) {
  const radii = new Map()
  for (const node of scene?.nodes || []) {
    const width = Math.max(0, Number(node?.width) || 0)
    const height = Math.max(0, Number(node?.height) || 0)
    radii.set(String(node?.id || ""), Math.hypot(width, height) / 2)
  }
  for (const group of scene?.groups || []) {
    const width = Math.max(0, Number(group?.bounds?.maxX) - Number(group?.bounds?.minX))
    const height = Math.max(0, Number(group?.bounds?.maxY) - Number(group?.bounds?.minY))
    radii.set(String(group?.id || ""), Math.hypot(width, height) / 2)
  }
  return radii
}

function sharedEndpointApproachLimit(route, endpointId, envelopeRadii, maximumFraction) {
  const endpointRadius = Math.max(0, Number(envelopeRadii.get(endpointId)) || 0)
  const geometricLimit = Math.min(
    ROUTE_CLEARANCE * 2,
    Math.max(ROUTE_CLEARANCE, endpointRadius + ROUTE_CLEARANCE),
  )
  const sourceTerminalEnd = Math.min(2, route.cumulativeLengths.length - 1)
  const targetTerminalStart = Math.max(0, route.cumulativeLengths.length - 3)
  const terminalApproachLength = route.sourceId === endpointId
    ? route.cumulativeLengths[sourceTerminalEnd]
    : route.totalLength - route.cumulativeLengths[targetTerminalStart]
  // The shared port funnel ends at the first of the terminal bend or the
  // endpoint chrome envelope. A long terminal leg must not turn most of a
  // nearly overlapping route into exempt endpoint contact. Always retain a
  // non-funnel tail; routes sharing both semantic endpoints retain a middle
  // between their two bounded funnels.
  return Math.min(
    geometricLimit,
    terminalApproachLength,
    route.totalLength * maximumFraction,
  )
}

function routeSegmentsOutsideSharedEndpointApproaches(route, sharedEndpointIds, envelopeRadii) {
  const sharesSource = sharedEndpointIds.includes(route.sourceId)
  const sharesTarget = sharedEndpointIds.includes(route.targetId)
  const maximumFraction = sharesSource && sharesTarget ? 0.45 : 0.9
  const sourceLimit = sharesSource
    ? sharedEndpointApproachLimit(route, route.sourceId, envelopeRadii, maximumFraction)
    : 0
  const targetLimit = sharesTarget
    ? sharedEndpointApproachLimit(route, route.targetId, envelopeRadii, maximumFraction)
    : 0
  const lowerDistance = sourceLimit
  const upperDistance = Math.max(lowerDistance, route.totalLength - targetLimit)
  const segments = []

  for (let pointIndex = 1; pointIndex < route.points.length; pointIndex += 1) {
    const segmentStartDistance = route.cumulativeLengths[pointIndex - 1]
    const segmentEndDistance = route.cumulativeLengths[pointIndex]
    const segmentLength = segmentEndDistance - segmentStartDistance
    if (!(segmentLength > 0)) continue
    const clippedStartDistance = Math.max(segmentStartDistance, lowerDistance)
    const clippedEndDistance = Math.min(segmentEndDistance, upperDistance)
    if (!(clippedEndDistance > clippedStartDistance)) continue
    const startRatio = (clippedStartDistance - segmentStartDistance) / segmentLength
    const endRatio = (clippedEndDistance - segmentStartDistance) / segmentLength
    const start = route.points[pointIndex - 1]
    const end = route.points[pointIndex]
    segments.push({
      index: pointIndex - 1,
      start: {
        x: start.x + ((end.x - start.x) * startRatio),
        y: start.y + ((end.y - start.y) * startRatio),
      },
      end: {
        x: start.x + ((end.x - start.x) * endRatio),
        y: start.y + ((end.y - start.y) * endRatio),
      },
    })
  }
  return segments
}

function routeDistanceAtPoint(route, point) {
  for (let pointIndex = 1; pointIndex < route.points.length; pointIndex += 1) {
    const start = route.points[pointIndex - 1]
    const end = route.points[pointIndex]
    const dx = end.x - start.x
    const dy = end.y - start.y
    const lengthSquared = (dx * dx) + (dy * dy)
    if (!(lengthSquared > 0)) continue
    const parameter = Math.max(0, Math.min(1, (
      ((point.x - start.x) * dx) + ((point.y - start.y) * dy)
    ) / lengthSquared))
    const closest = {x: start.x + (parameter * dx), y: start.y + (parameter * dy)}
    if (Math.hypot(point.x - closest.x, point.y - closest.y) <= 0.01) {
      return route.cumulativeLengths[pointIndex - 1] + (Math.sqrt(lengthSquared) * parameter)
    }
  }
  return null
}

function routeSegmentsOutsideDeclaredJunctionApproaches(route, sharedJunctionIds) {
  const excluded = (route.junctions || []).flatMap((junction) => {
    if (!sharedJunctionIds.includes(String(junction?.id || ""))) return []
    const distance = routeDistanceAtPoint(route, junction.point)
    if (!Number.isFinite(distance)) return []
    return [{
      start: Math.max(0, distance - (ROUTE_CLEARANCE * 2)),
      end: Math.min(route.totalLength, distance + (ROUTE_CLEARANCE * 2)),
    }]
  }).sort((left, right) => left.start - right.start)
  const allowed = []
  let cursor = 0
  for (const interval of excluded) {
    if (interval.start > cursor) allowed.push({start: cursor, end: interval.start})
    cursor = Math.max(cursor, interval.end)
  }
  if (cursor < route.totalLength) allowed.push({start: cursor, end: route.totalLength})

  const segments = []
  for (let pointIndex = 1; pointIndex < route.points.length; pointIndex += 1) {
    const segmentStartDistance = route.cumulativeLengths[pointIndex - 1]
    const segmentEndDistance = route.cumulativeLengths[pointIndex]
    const segmentLength = segmentEndDistance - segmentStartDistance
    if (!(segmentLength > 0)) continue
    for (const interval of allowed) {
      const clippedStartDistance = Math.max(segmentStartDistance, interval.start)
      const clippedEndDistance = Math.min(segmentEndDistance, interval.end)
      if (!(clippedEndDistance > clippedStartDistance)) continue
      const startRatio = (clippedStartDistance - segmentStartDistance) / segmentLength
      const endRatio = (clippedEndDistance - segmentStartDistance) / segmentLength
      const start = route.points[pointIndex - 1]
      const end = route.points[pointIndex]
      segments.push({
        index: pointIndex - 1,
        start: {x: start.x + ((end.x - start.x) * startRatio), y: start.y + ((end.y - start.y) * startRatio)},
        end: {x: start.x + ((end.x - start.x) * endRatio), y: start.y + ((end.y - start.y) * endRatio)},
      })
    }
  }
  return segments
}

function managedRouteSeparationConstraint(graph, managedVisualDensity) {
  const requiredPixels = managedVisualDensityContract(managedVisualDensity).routeMaxWidth
  const scene = graph?._topologyScene
  const envelopeRadii = endpointEnvelopeRadii(scene)
  const routes = (graph?._topologyScene?.physicalRoutes || graph?._topologyScene?.routes || []).map((route) => ({
    id: String(route?.id || ""),
    sourceId: String(route?.sourceContactId || route?.sourceId || ""),
    targetId: String(route?.targetContactId || route?.targetId || ""),
    points: finiteRoutePoints(route),
    junctions: (route?.junctions || []).map((junction) => ({
      id: String(junction?.id || ""),
      point: {x: Number(junction?.point?.x), y: Number(junction?.point?.y)},
    })),
  })).map((route) => ({...route, ...routePathMetrics(route.points)}))
  let limiting = {
    scale: 0,
    leftId: "",
    rightId: "",
    axis: "normal",
    limitingRolePair: [],
  }

  for (let leftIndex = 0; leftIndex < routes.length; leftIndex += 1) {
    for (let rightIndex = leftIndex + 1; rightIndex < routes.length; rightIndex += 1) {
      const left = routes[leftIndex]
      const right = routes[rightIndex]
      const sharedEndpointIds = [left.sourceId, left.targetId]
        .filter((endpointId) => endpointId !== "" && (endpointId === right.sourceId || endpointId === right.targetId))
      const rightJunctionIds = new Set(right.junctions.map((junction) => junction.id))
      const sharedJunctionIds = left.junctions
        .map((junction) => junction.id)
        .filter((junctionId) => junctionId !== "" && rightJunctionIds.has(junctionId))
      const leftSegments = sharedJunctionIds.length > 0
        ? routeSegmentsOutsideDeclaredJunctionApproaches(left, sharedJunctionIds)
        : routeSegmentsOutsideSharedEndpointApproaches(left, sharedEndpointIds, envelopeRadii)
      const rightSegments = sharedJunctionIds.length > 0
        ? routeSegmentsOutsideDeclaredJunctionApproaches(right, sharedJunctionIds)
        : routeSegmentsOutsideSharedEndpointApproaches(right, sharedEndpointIds, envelopeRadii)
      let minimumDistance = Number.POSITIVE_INFINITY
      let minimumLeftSegment = null
      let minimumRightSegment = null
      for (const leftSegment of leftSegments) {
        for (const rightSegment of rightSegments) {
          const separation = segmentSeparation(
            leftSegment.start,
            leftSegment.end,
            rightSegment.start,
            rightSegment.end,
          )
          if (separation.distance > 0) {
            if (separation.distance < minimumDistance) {
              minimumDistance = separation.distance
              minimumLeftSegment = leftSegment.index
              minimumRightSegment = rightSegment.index
            }
          }
        }
      }
      if (!Number.isFinite(minimumDistance)) continue
      const scale = requiredPixels / minimumDistance
      if (scale > limiting.scale) {
        limiting = {
          scale,
          leftId: left.id,
          rightId: right.id,
          axis: "normal",
          limitingRolePair: ["route", "route"],
          limitingKind: "route-route",
          routeIds: [left.id, right.id],
          segmentIndexes: [minimumLeftSegment, minimumRightSegment],
        }
      }
    }
  }

  return limiting
}

function strongerManagedConstraint(left, right) {
  return right.scale > left.scale ? right : left
}

function stableManagedDensityCacheKey(graph, specsByDensity) {
  // The accepted layout key owns immutable scene geometry. Include renderer
  // glyph extents so presentation-policy changes cannot reuse stale floors.
  const layoutKey = String(graph?._layoutCacheKey || "").trim()
  const sceneKey = String(graph?._topologyScene?.key || "").trim()
  const stableSceneKey = layoutKey !== ""
    ? `layout:${layoutKey}`
    : (sceneKey !== "" ? `scene:${sceneKey}:${String(graph?._topologyScene?.profileKey || "")}` : "")
  if (stableSceneKey === "") return null
  const glyphSignature = MANAGED_VISUAL_DENSITY_PREFERENCE.map((managedVisualDensity) => [
    managedVisualDensity,
    ...(specsByDensity[managedVisualDensity] || []).map((spec) => [
      spec.nodeId,
      spec.role,
      spec.worldX,
      spec.worldY,
      spec.halfWidth,
      spec.halfHeight,
    ]),
  ])
  return `${stableSceneKey}:glyphs:${JSON.stringify(glyphSignature)}`
}

function rememberStableManagedDensityConstraints(context, cacheKey, constraints) {
  if (!context?.state || cacheKey === null) return
  const current = context.state.managedTopologyDensityConstraintsLayoutCache
  const next = current instanceof Map ? new Map(current) : new Map()
  next.delete(cacheKey)
  next.set(cacheKey, constraints)
  while (next.size > MANAGED_DENSITY_LAYOUT_CACHE_LIMIT) {
    next.delete(next.keys().next().value)
  }
  context.state.managedTopologyDensityConstraintsLayoutCache = next
}

function managedDensityConstraints(context, graph) {
  const cached = context?.state?.managedTopologyDensityConstraintsCache
  if (cached?.graph === graph && cached?.scene === graph?._topologyScene) {
    return cached.constraints
  }
  const graphNodes = managedGraphNodes(graph)
  const specsByDensity = Object.fromEntries(MANAGED_VISUAL_DENSITY_PREFERENCE.map((managedVisualDensity) => [
    managedVisualDensity,
    managedGlyphSpecs(context, graph, graphNodes, managedVisualDensity),
  ]))
  const stableCacheKey = stableManagedDensityCacheKey(graph, specsByDensity)
  const stableCache = context?.state?.managedTopologyDensityConstraintsLayoutCache
  const stableConstraints = stableCacheKey === null || !(stableCache instanceof Map)
    ? null
    : stableCache.get(stableCacheKey)
  if (stableConstraints) {
    context.state.managedTopologyDensityConstraintsCache = {
      graph,
      scene: graph?._topologyScene,
      constraints: stableConstraints,
    }
    rememberStableManagedDensityConstraints(context, stableCacheKey, stableConstraints)
    return stableConstraints
  }
  const constraints = Object.fromEntries(MANAGED_VISUAL_DENSITY_PREFERENCE.map((managedVisualDensity) => {
    const specs = specsByDensity[managedVisualDensity]
    const glyphConstraint = managedGlyphSeparationConstraint(specs)
    const routeConstraint = managedRouteGlyphClearanceConstraint(graph, specs, managedVisualDensity)
    const routeSeparation = managedRouteSeparationConstraint(graph, managedVisualDensity)
    const routeWidth = (
      graph?._topologyScene?.physicalRoutes || graph?._topologyScene?.routes || []
    ).length > 0
      ? managedVisualDensityContract(managedVisualDensity).routeMaxWidth
      : 0
    const limitingConstraint = strongerManagedConstraint(
      strongerManagedConstraint(glyphConstraint, routeConstraint),
      routeSeparation,
    )
    return [managedVisualDensity, {
      ...limitingConstraint,
      minimumSafeWidth: Math.max(routeWidth, ...specs.map((spec) => spec.halfWidth * 2), 0),
      minimumSafeHeight: Math.max(routeWidth, ...specs.map((spec) => spec.halfHeight * 2), 0),
    }]
  }))
  if (context?.state) {
    context.state.managedTopologyDensityConstraintsCache = {
      graph,
      scene: graph?._topologyScene,
      constraints,
    }
  }
  rememberStableManagedDensityConstraints(context, stableCacheKey, constraints)
  return constraints
}

function currentManagedSafeRect(context, explicitSafeRect = null) {
  const state = context?.state
  const rawSafeRect = explicitSafeRect || state?.topologyLabelSafeRect || (
    state?.el ? measureGodViewSafeRect(state.el) : null
  )
  if (!rawSafeRect) return null
  const width = Math.max(
    1,
    Number(state?.viewportWidth) || 0,
    Number(state?.el?.clientWidth) || 0,
    Number(rawSafeRect?.right) || 0,
  )
  const height = Math.max(
    1,
    Number(state?.viewportHeight) || 0,
    Number(state?.el?.clientHeight) || 0,
    Number(rawSafeRect?.bottom) || 0,
  )
  return normalizeGodViewSafeRect(rawSafeRect, {width, height})
}

function managedSafeDimensions(safeRect) {
  if (!safeRect) return null
  return {
    width: Math.max(0, Number(safeRect.right) - Number(safeRect.left)),
    height: Math.max(0, Number(safeRect.bottom) - Number(safeRect.top)),
  }
}

function managedConstraintFitsSafeRect(constraint, safeDimensions) {
  if (!safeDimensions) return true
  return (
    safeDimensions.width + 1e-9 >= Number(constraint?.minimumSafeWidth || 0) &&
    safeDimensions.height + 1e-9 >= Number(constraint?.minimumSafeHeight || 0)
  )
}

function selectManagedDensityForScale(
  constraints,
  scale,
  requiredManagedVisualDensity = null,
  safeRect = null,
) {
  const cameraScale = Number(scale)
  if (!Number.isFinite(cameraScale) || cameraScale <= 0) {
    throw new RangeError(`managed topology camera scale must be finite and positive; scale=${String(scale)}`)
  }
  if (
    requiredManagedVisualDensity !== null &&
    !MANAGED_VISUAL_DENSITY_PREFERENCE.includes(requiredManagedVisualDensity)
  ) {
    throw new RangeError(`unknown managed visual density ${String(requiredManagedVisualDensity)}`)
  }
  const candidates = requiredManagedVisualDensity === null
    ? MANAGED_VISUAL_DENSITY_PREFERENCE
    : [requiredManagedVisualDensity]
  const safeDimensions = managedSafeDimensions(safeRect)
  for (const managedVisualDensity of candidates) {
    if (
      managedConstraintFitsSafeRect(constraints[managedVisualDensity], safeDimensions) &&
      cameraScale + 1e-9 >= constraints[managedVisualDensity].scale
    ) {
      return managedVisualDensity
    }
  }
  if (requiredManagedVisualDensity !== null) {
    const required = constraints[requiredManagedVisualDensity]
    throw new RangeError(
      `managed visual density ${requiredManagedVisualDensity} requires scale=${required.scale}, ` +
      `safe=${required.minimumSafeWidth || 0}x${required.minimumSafeHeight || 0}; ` +
      `scale=${cameraScale}, available=${safeDimensions?.width ?? "unknown"}x${safeDimensions?.height ?? "unknown"}`,
    )
  }
  const overview = constraints.overview
  throw new RangeError(
    `no feasible managed visual density at scale=${cameraScale}; overview requires scale=${overview.scale} ` +
    `and safe=${overview.minimumSafeWidth || 0}x${overview.minimumSafeHeight || 0}; ` +
    `available=${safeDimensions?.width ?? "unknown"}x${safeDimensions?.height ?? "unknown"}; ` +
    `for ${overview.leftId}(${overview.limitingRolePair[0] || "unknown"}) and ` +
    `${overview.rightId}(${overview.limitingRolePair[1] || "unknown"}) on axis=${overview.axis}`,
  )
}

function managedLabelAdmission(context, graph, graphNodes, width, height, managedVisualDensity) {
  if (typeof context.admitNodeLabelsForViewport !== "function" || typeof context.selectNodeLabels !== "function") {
    return undefined
  }
  return ({scene, viewState, safeRect}) => {
    const protectedNodes = (scene?.nodes || []).flatMap((sceneNode) => {
      if (sceneNode?.render === false) return []
      const entry = graphNodes.get(String(sceneNode?.id || ""))
      if (!entry) return []
      return [{
        ...entry.node,
        index: entry.index,
        position: [Number(sceneNode?.center?.x) || 0, Number(sceneNode?.center?.y) || 0, 0],
      }]
    })
    const viewport = {
      width,
      height,
      project: ([x, y]) => {
        const scale = 2 ** viewState.zoom
        return [
          (width / 2) + ((Number(x) - viewState.target[0]) * scale),
          (height / 2) + ((Number(y) - viewState.target[1]) * scale),
        ]
      },
    }
    const candidates = context.selectNodeLabels(
      protectedNodes,
      graph?.shape,
      {managedVisualDensity},
    )
    return context.admitNodeLabelsForViewport(
      {...graph, _topologyScene: scene},
      candidates,
      protectedNodes,
      {viewport, safeRect, managedVisualDensity},
    )
  }
}

function fitManagedSceneAtDensity(
  context,
  graph,
  scene,
  viewport,
  safeRect,
  graphNodes,
  managedVisualDensity,
  {admitLabels = true} = {},
) {
  const glyphBoxes = (scene.nodes || [])
    .filter((sceneNode) => sceneNode?.render !== false)
    .map((sceneNode) => managedGlyphBox(context, graphNodes, sceneNode, managedVisualDensity))
  return fitTopologyScene({
    scene,
    viewport,
    safeRect,
    glyphBoxes,
    routeStrokeWidth: managedVisualDensityContract(managedVisualDensity).routeMaxWidth,
    admitLabels: admitLabels
      ? managedLabelAdmission(
        context,
        graph,
        graphNodes,
        viewport.width,
        viewport.height,
        managedVisualDensity,
      )
      : undefined,
  })
}

function managedDensityHolds(constraint, safeDimensions, fit) {
  const fittedScale = 2 ** Number(fit?.viewState?.zoom)
  return (
    managedConstraintFitsSafeRect(constraint, safeDimensions) &&
    Number.isFinite(fittedScale) &&
    fittedScale + 1e-9 >= Number(constraint?.scale || 0)
  )
}

// Whether a density holds depends on the scale the scene fits into, and that scale depends
// on the density's own glyph extents -- so it cannot be answered before fitting. Reading the
// density straight off the semantic level is what let detail overlap glyphs on a viewport
// too small for it.
//
// Measure each candidate with a label-free probe, then fit once at the winner. The probe is
// exact for this question: fitTopologyScene fits glyph and route extents first and refits
// only when an admitted label escapes the safe rect, so the label pass it skips cannot change
// the scale the separation constraint is defined against. Probing rather than fitting for
// real matters because scenes that must step down are the common case, not the exception --
// keeping the preferred fit instead measured slower (444s vs 426s over the acceptance suite),
// since a rejected density's full fit is wasted. A scene already at overview has one
// candidate and takes the single fit it always took.
function selectFeasibleManagedDensity(
  context,
  graph,
  scene,
  viewport,
  safeRect,
  graphNodes,
  preferred,
  constraints,
  safeDimensions,
) {
  const candidates = MANAGED_VISUAL_DENSITY_PREFERENCE.slice(
    MANAGED_VISUAL_DENSITY_PREFERENCE.indexOf(preferred),
  )
  if (candidates.length < 2) return preferred

  for (const candidate of candidates) {
    const probe = fitManagedSceneAtDensity(
      context,
      graph,
      scene,
      viewport,
      safeRect,
      graphNodes,
      candidate,
      {admitLabels: false},
    )
    if (managedDensityHolds(constraints[candidate], safeDimensions, probe)) return candidate
  }
  // Nothing held. Take the TIGHTEST candidate rather than the preferred one: returning the
  // widest is what made the ladder inert for exactly the scenes that needed it, since a graph
  // dense enough to fail every tier would snap back to the roomiest and overlap hardest.
  // Keeping the whole graph visible and degrading the glyphs is the deliberate trade here --
  // the alternative is framing a subset and making the operator pan to find the rest.
  return candidates[candidates.length - 1]
}

function fitManagedTopologyScene(context, graph, scene, viewport, safeRect, graphNodes) {
  const semanticLevel = topologySemanticLevel(graph)
  const managedVisualDensity = selectFeasibleManagedDensity(
    context,
    graph,
    scene,
    viewport,
    safeRect,
    graphNodes,
    semanticLevel === "detail" ? "detail" : "overview",
    managedDensityConstraints(context, graph),
    managedSafeDimensions(safeRect),
  )
  const fit = fitManagedSceneAtDensity(
    context,
    graph,
    scene,
    viewport,
    safeRect,
    graphNodes,
    managedVisualDensity,
  )

  // A bounded, deliberately framed scene fails closed. Everything else degrades:
  // fitTopologyScene always returns a usable viewState plus the labels it could place,
  // so the camera still fits and the surface still renders without the labels that would
  // not fit. Expansion is the unbounded case and must degrade even though it derives
  // detail -- see the note in rendering_graph_layer_node_methods.js.
  if (!fit.ok && semanticLevel === "detail" && !hasExpandedCluster(graph)) {
    throw new RangeError(
      `managed topology ${semanticLevel} is missing required labels: ${fit.missingRequiredLabelIds.join(", ")}`,
    )
  }
  return {...fit, managedVisualDensity}
}

// The overview carries clusters as node membership rather than as compound groups, so build the
// group the focus scene needs from the graph itself. Without it focusClusterNeighborhood returns
// false in the radial atlas and the camera never frames a cluster the operator just expanded.
function managedClusterGroup(graph, clusterId) {
  const normalizedId = String(clusterId || "").trim()
  if (normalizedId === "") return null
  const sceneNodeIds = new Set((graph?._topologyScene?.nodes || []).map((node) => String(node?.id || "")))
  const memberIds = []
  let anchorId = ""
  for (const node of graph?.nodes || []) {
    const details = node?.details || {}
    if (String(details.cluster_id || "").trim() !== normalizedId) continue
    if (anchorId === "") anchorId = String(details.cluster_anchor_id || "").trim()
    const id = String(node?.id || "")
    if (sceneNodeIds.has(id)) memberIds.push(id)
  }
  if (memberIds.length === 0) return null
  return {id: normalizedId, anchorId, gatewayId: anchorId, memberIds}
}

function focusManagedTopologyGroup(context, graph, groupId, viewport, safeRect, graphNodes) {
  const clusterGroup = managedClusterGroup(graph, groupId)
  const focusScene = topologyGroupFocusScene(graph?._topologyScene, groupId, clusterGroup)
  if (!focusScene) return null
  const focusNodeIds = new Set((focusScene.nodes || []).map((node) => String(node?.id || "")))
  const layoutCacheKey = String(graph?._layoutCacheKey || "").trim()
  const focusGraph = {
    ...graph,
    _layoutCacheKey: layoutCacheKey === "" ? "" : `${layoutCacheKey}:focus:${String(groupId)}`,
    _topologyScene: focusScene,
    nodes: (graph?.nodes || []).filter((node) => focusNodeIds.has(String(node?.id || ""))),
  }
  const constraints = managedDensityConstraints(context, focusGraph)
  // Focus frames the densest thing in the scene -- an opened cluster's entire ring -- so it has
  // to honour the density the fit stepped down to instead of assuming the semantic default.
  const focusSemanticDefault = topologySemanticLevel(graph) === "detail" ? "detail" : "overview"
  const focusStoredDensity = context?.state?.managedTopologyVisualDensity
  const managedVisualDensity = MANAGED_VISUAL_DENSITY_PREFERENCE.includes(focusStoredDensity)
    ? focusStoredDensity
    : focusSemanticDefault
  const fit = focusTopologyGroup({
    scene: graph._topologyScene,
    groupId,
    fallbackGroup: clusterGroup,
    viewport,
    safeRect,
    glyphBoxForNode: (sceneNode) => managedGlyphBox(
      context,
      graphNodes,
      sceneNode,
      managedVisualDensity,
    ),
    routeStrokeWidth: managedVisualDensityContract(managedVisualDensity).routeMaxWidth,
    admitLabels: managedLabelAdmission(
      context,
      graph,
      graphNodes,
      viewport.width,
      viewport.height,
      managedVisualDensity,
    ),
    degradeUnplaceableLabels: hasExpandedCluster(graph),
  })
  return fit ? {...fit, managedVisualDensity, constraints} : null
}

function managedSceneFloorKey(graph) {
  const layoutKey = String(graph?._layoutCacheKey || "").trim()
  if (layoutKey !== "") return `layout:${layoutKey}`
  const sceneKey = String(graph?._topologyScene?.key || "").trim()
  return sceneKey === "" ? null : `scene:${sceneKey}`
}

export const godViewRenderingGraphViewMethods = {
  managedVisualDensityForViewScale(graph, scale, options = {}) {
    if (!hasManagedTopologyScene(graph)) {
      throw new RangeError("managed visual density requires an accepted ELK topology scene")
    }
    const constraints = managedDensityConstraints(this, graph)
    const safeRect = currentManagedSafeRect(this, options?.safeRect)
    return {
      managedVisualDensity: selectManagedDensityForScale(constraints, scale, null, safeRect),
      constraints,
    }
  },
  managedViewStateForCamera(graph, viewState, options = {}) {
    if (!hasManagedTopologyScene(graph)) {
      return {viewState, managedVisualDensity: null, constraints: null}
    }

    const constraints = options?.densityConstraints || managedDensityConstraints(this, graph)
    const requestedMaxZoom = Number(viewState?.maxZoom)
    const requestedZoom = Number(viewState?.zoom)
    const requestedMinZoom = Number(viewState?.minZoom)
    const fittedContainmentZoom = Number(options?.fittedContainmentZoom)
    const storedSceneMinZoom = Number(this.state.managedTopologySceneMinZoom)
    const sceneFloorKey = managedSceneFloorKey(graph)
    const storedSceneMatches = sceneFloorKey === null
      ? this.state.managedTopologySceneForMinZoom === graph._topologyScene
      : this.state.managedTopologySceneMinZoomKey === sceneFloorKey
    let minZoom
    if (Number.isFinite(fittedContainmentZoom)) {
      minZoom = Math.max(
        MANAGED_ABSOLUTE_MIN_ZOOM,
        Math.min(Number.isFinite(requestedMinZoom) ? requestedMinZoom : MANAGED_ABSOLUTE_MIN_ZOOM, fittedContainmentZoom),
      )
      this.state.managedTopologySceneMinZoom = minZoom
      this.state.managedTopologySceneMinZoomKey = sceneFloorKey
      this.state.managedTopologySceneForMinZoom = graph._topologyScene
    } else if (storedSceneMatches && Number.isFinite(storedSceneMinZoom)) {
      minZoom = Math.max(
        MANAGED_ABSOLUTE_MIN_ZOOM,
        Math.min(Number.isFinite(requestedMinZoom) ? requestedMinZoom : MANAGED_ABSOLUTE_MIN_ZOOM, storedSceneMinZoom),
      )
    } else {
      minZoom = Math.max(
        MANAGED_ABSOLUTE_MIN_ZOOM,
        Number.isFinite(requestedMinZoom) ? requestedMinZoom : MANAGED_ABSOLUTE_MIN_ZOOM,
      )
    }
    const maxZoom = Math.max(minZoom, Number.isFinite(requestedMaxZoom) ? requestedMaxZoom : 5)
    const zoom = Math.max(minZoom, Math.min(maxZoom, Number.isFinite(requestedZoom) ? requestedZoom : 0))
    const managedVisualDensity = options?.fittedManagedVisualDensity ?? (
      topologySemanticLevel(graph) === "detail" ? "detail" : "overview"
    )

    return {
      viewState: {...viewState, zoom, minZoom, maxZoom},
      managedVisualDensity,
      constraints,
    }
  },
  fitViewPadding(width, height) {
    const safeWidth = Math.max(1, Number(width) || 1)
    const safeHeight = Math.max(1, Number(height) || 1)

    return {
      left: Math.min(72, Math.max(32, safeWidth * 0.06)),
      right: Math.min(260, Math.max(120, safeWidth * 0.18)),
      top: Math.min(120, Math.max(56, safeHeight * 0.09)),
      bottom: Math.min(144, Math.max(72, safeHeight * 0.12)),
    }
  },
  boundsForNodes(nodes) {
    let minX = Number.POSITIVE_INFINITY
    let maxX = Number.NEGATIVE_INFINITY
    let minY = Number.POSITIVE_INFINITY
    let maxY = Number.NEGATIVE_INFINITY

    for (const node of nodes) {
      const x = Number(node?.x)
      const y = Number(node?.y)
      if (!Number.isFinite(x) || !Number.isFinite(y)) continue
      const radius = frameNodeRadius(node)
      minX = Math.min(minX, x - radius)
      maxX = Math.max(maxX, x + radius)
      minY = Math.min(minY, y - radius)
      maxY = Math.max(maxY, y + radius)
    }

    if (!Number.isFinite(minX) || !Number.isFinite(minY)) return null
    return {minX, maxX, minY, maxY}
  },
  autoFitBounds(graph) {
    if (!graph || !Array.isArray(graph.nodes) || graph.nodes.length === 0) return null

    const finiteNodes = graph.nodes.filter((node) => {
      const x = Number(node?.x)
      const y = Number(node?.y)
      return Number.isFinite(x) && Number.isFinite(y)
    })
    if (finiteNodes.length === 0) return null

    if (graph._layoutMode !== "client-radial") return this.boundsForNodes(finiteNodes)

    const overviewNodes = finiteNodes.filter(
      (node) => (!isEndpointMemberNode(node) || isExpandedEndpointMemberNode(node)) && !isUnplacedNode(node),
    )
    const radialOverviewNodes = overviewNodes.filter(
      (node) =>
        isInfrastructureOverviewNode(node) ||
        isEndpointSummaryNode(node) ||
        isEndpointAnchorNode(node) ||
        isExpandedEndpointMemberNode(node),
    )
    const framedNodes = radialOverviewNodes.length > 0 ? radialOverviewNodes : overviewNodes.length > 0 ? overviewNodes : finiteNodes
    return this.boundsForNodes(framedNodes)
  },
  autoFitViewState(graph, options = {}) {
    if (!this.state.deck || !graph || !Array.isArray(graph.nodes)) return
    const managedScene = hasManagedTopologyScene(graph) ? graph._topologyScene : null
    if (this.state.userCameraLocked) {
      if (managedScene) {
        const selection = this.managedViewStateForCamera(graph, this.state.viewState)
        this.state.managedTopologyVisualDensity = selection.managedVisualDensity
      }
      return
    }
    if (!options.force && this.state.hasAutoFit) return

    if (managedScene) {
      // A surface that has not been laid out yet reports 0. Glyph extents are fixed pixels,
      // so once that 0 is clamped to 1 nothing fits at any zoom, and the fit correctly calls
      // the scene impossible -- but what it is describing is an unmeasured container, not an
      // unfittable scene. Throwing there is caught as a camera failure, which rolls the
      // camera back and leaves the surface reporting "topology render unavailable" with the
      // graph parked off-screen at a default camera.
      //
      // Defer instead, leaving hasAutoFit false so the resize observer fits as soon as the
      // surface has a size. A measured-but-tiny surface still fails closed: that is a real
      // condition worth surfacing, and it is not this race.
      const measuredWidth = Number(this.state.el?.clientWidth) || 0
      const measuredHeight = Number(this.state.el?.clientHeight) || 0
      if (measuredWidth <= 0 || measuredHeight <= 0) return

      const width = Math.max(1, measuredWidth)
      const height = Math.max(1, measuredHeight)
      const safeRect = this.state.topologyLabelSafeRect || measureGodViewSafeRect(this.state.el)
      const graphNodes = managedGraphNodes(graph)
      const fitted = fitManagedTopologyScene(
        this,
        graph,
        managedScene,
        {...this.state.viewState, width, height, viewState: this.state.viewState},
        safeRect,
        graphNodes,
      )

      const selected = this.managedViewStateForCamera(
        graph,
        fitted.viewState,
        {
          fittedContainmentZoom: fitted.viewState.zoom,
          fittedManagedVisualDensity: fitted.managedVisualDensity,
        },
      )
      this.state.viewState = selected.viewState
      this.state.managedTopologyVisualDensity = selected.managedVisualDensity
      this.state.hasAutoFit = true
      this.state.isProgrammaticViewUpdate = true
      this.state.deck.setProps({viewState: this.state.viewState})
      if (this.state.zoomMode === "auto") this.deps.setZoomTier("local", true)
      return
    }

    if (graph.nodes.length === 0) return

    const bounds = this.autoFitBounds(graph)
    if (!bounds) return
    const {minX, maxX, minY, maxY} = bounds

    const width = Math.max(1, this.state.el.clientWidth || 1)
    const height = Math.max(1, this.state.el.clientHeight || 1)
    const padding = this.fitViewPadding(width, height)
    const availableWidth = Math.max(1, width - padding.left - padding.right)
    const availableHeight = Math.max(1, height - padding.top - padding.bottom)
    const spanX = Math.max(1, maxX - minX)
    const spanY = Math.max(1, maxY - minY)
    const zoomX = Math.log2(availableWidth / spanX)
    const zoomY = Math.log2(availableHeight / spanY)
    const zoom = Math.max(this.state.viewState.minZoom, Math.min(this.state.viewState.maxZoom, Math.min(zoomX, zoomY)))
    const scale = Math.pow(2, zoom)
    const targetX = ((minX + maxX) / 2) + ((padding.right - padding.left) / (2 * scale))
    const targetY = ((minY + maxY) / 2) + ((padding.bottom - padding.top) / (2 * scale))

    this.state.viewState = {
      ...this.state.viewState,
      target: [targetX, targetY, 0],
      zoom,
    }

    this.state.hasAutoFit = true
    this.state.isProgrammaticViewUpdate = true
    this.state.deck.setProps({viewState: this.state.viewState})
    if (this.state.zoomMode === "auto") {
      this.deps.setZoomTier(preferredAutoFitZoomTier(graph) || this.deps.resolveZoomTier(zoom), true)
    }
  },
  focusClusterNeighborhood(graph, clusterId) {
    const normalizedClusterId = typeof clusterId === "string" ? clusterId.trim() : ""
    if (!this.state.deck || !graph || !Array.isArray(graph.nodes) || normalizedClusterId === "") return false
    if (this.state.userCameraLocked) return false

    if (hasManagedTopologyScene(graph)) {
      const width = Math.max(1, this.state.el.clientWidth || 1)
      const height = Math.max(1, this.state.el.clientHeight || 1)
      const graphNodes = managedGraphNodes(graph)
      const focused = focusManagedTopologyGroup(
        this,
        graph,
        normalizedClusterId,
        {...this.state.viewState, width, height, viewState: this.state.viewState},
        this.state.topologyLabelSafeRect || measureGodViewSafeRect(this.state.el),
        graphNodes,
      )
      if (!focused) return false
      const selected = this.managedViewStateForCamera(
        graph,
        focused.viewState,
        {
          fittedContainmentZoom: focused.viewState.zoom,
          fittedManagedVisualDensity: focused.managedVisualDensity,
          densityConstraints: focused.constraints,
        },
      )
      this.state.viewState = selected.viewState
      this.state.managedTopologyVisualDensity = selected.managedVisualDensity
      this.state.isProgrammaticViewUpdate = true
      this.state.deck.setProps({viewState: this.state.viewState})
      if (this.state.zoomMode === "auto") this.deps.setZoomTier("local", true)
      return true
    }

    const clusterNodes = graph.nodes.filter((node) => {
      const details = node?.details || {}
      return node?.id === normalizedClusterId || details?.cluster_id === normalizedClusterId
    })
    if (clusterNodes.length === 0) return false

    const anchorIds = new Set(
      clusterNodes
        .map((node) => String(node?.details?.cluster_anchor_id || "").trim())
        .filter((id) => id !== ""),
    )

    const neighborhood = graph.nodes.filter((node) => {
      const details = node?.details || {}
      const nodeId = String(node?.id || "").trim()
      const nodeClusterId = String(details?.cluster_id || "").trim()
      return nodeId === normalizedClusterId || nodeClusterId === normalizedClusterId || anchorIds.has(nodeId)
    })
    if (neighborhood.length === 0) return false

    const bounds = this.boundsForNodes(neighborhood)
    if (!bounds) return false
    const {minX, maxX, minY, maxY} = bounds

    const width = Math.max(1, this.state.el.clientWidth || 1)
    const height = Math.max(1, this.state.el.clientHeight || 1)
    const basePadding = this.fitViewPadding(width, height)
    const padding = {
      left: Math.max(32, basePadding.left * 0.65),
      right: Math.max(112, basePadding.right * 0.7),
      top: Math.max(56, basePadding.top * 0.8),
      bottom: Math.max(104, basePadding.bottom * 1.15),
    }
    const availableWidth = Math.max(1, width - padding.left - padding.right)
    const availableHeight = Math.max(1, height - padding.top - padding.bottom)
    const spanX = Math.max(96, (maxX - minX) * 1.18)
    const spanY = Math.max(120, (maxY - minY) * 1.22)
    const zoomX = Math.log2(availableWidth / spanX)
    const zoomY = Math.log2(availableHeight / spanY)
    const zoom = Math.max(
      this.state.viewState.minZoom,
      Math.min(this.state.viewState.maxZoom, Math.min(zoomX, zoomY) + 0.08),
    )
    const scale = Math.pow(2, zoom)
    const targetX = ((minX + maxX) / 2) + ((padding.right - padding.left) / (2 * scale))
    const targetY = ((minY + maxY) / 2) - ((padding.bottom - padding.top) / (2 * scale))

    this.state.viewState = {
      ...this.state.viewState,
      target: [targetX, targetY, 0],
      zoom,
    }
    this.state.isProgrammaticViewUpdate = true
    this.state.deck.setProps({viewState: this.state.viewState})
    if (this.state.zoomMode === "auto") {
      this.deps.setZoomTier(this.deps.resolveZoomTier(zoom), true)
    }
    return true
  },
}
