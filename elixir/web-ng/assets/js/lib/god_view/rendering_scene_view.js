const SAFE_CHROME_GAP_PX = 8
const BROWSER_TOLERANCE_PX = 1
const DEFAULT_MIN_ZOOM = -3
const DEFAULT_MAX_ZOOM = 5
const ABSOLUTE_MIN_ZOOM = -24
const CONSERVATIVE_ROUTE_STROKE_PX = 38
const GOD_VIEW_SAFE_AREA_SELECTOR = "[data-god-view-safe-area], .sr-god-view-map-controls"
const GOD_VIEW_SAFE_ROOT_SELECTOR = "[data-god-view-safe-root]"

function finiteNumber(value, fallback = 0) {
  const number = Number(value)
  return Number.isFinite(number) ? number : fallback
}

function finiteRect(rect, fallbackWidth = 0, fallbackHeight = 0) {
  const left = finiteNumber(rect?.left)
  const top = finiteNumber(rect?.top)
  const positiveDimension = (...values) => {
    for (const value of values) {
      const number = Number(value)
      if (Number.isFinite(number) && number > 0) return number
    }
    return 0
  }
  const width = positiveDimension(rect?.width, finiteNumber(rect?.right) - left, fallbackWidth)
  const height = positiveDimension(rect?.height, finiteNumber(rect?.bottom) - top, fallbackHeight)
  return {left, top, right: left + width, bottom: top + height, width, height}
}

export function normalizeGodViewSafeRect(safeRect, viewport) {
  const width = Math.max(1, finiteNumber(viewport?.width, 1))
  const height = Math.max(1, finiteNumber(viewport?.height, 1))
  const rawLeft = Math.max(0, Math.min(width, finiteNumber(safeRect?.left)))
  const rawRight = Math.max(0, Math.min(width, finiteNumber(safeRect?.right, width)))
  const rawTop = Math.max(0, Math.min(height, finiteNumber(safeRect?.top)))
  const rawBottom = Math.max(0, Math.min(height, finiteNumber(safeRect?.bottom, height)))
  const [left, right] = rawRight - rawLeft >= 1 ? [rawLeft, rawRight] : [0, width]
  const [top, bottom] = rawBottom - rawTop >= 1 ? [rawTop, rawBottom] : [0, height]
  return {left, top, right, bottom}
}

export function godViewSafeAreaRoot(el) {
  return el?.closest?.(GOD_VIEW_SAFE_ROOT_SELECTOR) || el
}

export function godViewSafeAreaElements(el) {
  return Array.from(godViewSafeAreaRoot(el)?.querySelectorAll?.(GOD_VIEW_SAFE_AREA_SELECTOR) || [])
}

/**
 * Measures the canvas-local rectangle that does not sit under God-View chrome.
 * Chrome is assigned to its nearest container edge; vertical edges win corner
 * ties so the bottom status and map controls form one deterministic safe strip.
 */
export function measureGodViewSafeRect(el) {
  const container = finiteRect(el?.getBoundingClientRect?.(), finiteNumber(el?.clientWidth), finiteNumber(el?.clientHeight))
  const safe = {left: 0, top: 0, right: container.width, bottom: container.height}
  if (container.width <= 0 || container.height <= 0) return safe

  const chrome = godViewSafeAreaElements(el)
  for (const element of chrome) {
    const rect = finiteRect(element?.getBoundingClientRect?.())
    if (rect.width <= 0 || rect.height <= 0) continue
    const local = {
      left: Math.max(0, rect.left - container.left),
      top: Math.max(0, rect.top - container.top),
      right: Math.min(container.width, rect.right - container.left),
      bottom: Math.min(container.height, rect.bottom - container.top),
    }
    if (local.right <= local.left || local.bottom <= local.top) continue

    const edges = [
      {edge: "top", distance: Math.abs(local.top)},
      {edge: "bottom", distance: Math.abs(container.height - local.bottom)},
      {edge: "left", distance: Math.abs(local.left)},
      {edge: "right", distance: Math.abs(container.width - local.right)},
    ]
    edges.sort((left, right) => left.distance - right.distance)
    const declaredEdge = element?.getAttribute?.("data-god-view-safe-area")
    const edge = ["top", "bottom", "left", "right"].includes(declaredEdge)
      ? declaredEdge
      : edges[0].edge
    switch (edge) {
      case "top":
        safe.top = Math.max(safe.top, local.bottom + SAFE_CHROME_GAP_PX)
        break
      case "left":
        safe.left = Math.max(safe.left, local.right + SAFE_CHROME_GAP_PX)
        break
      case "right":
        safe.right = Math.min(safe.right, local.left - SAFE_CHROME_GAP_PX)
        break
      case "bottom":
      default:
        safe.bottom = Math.min(safe.bottom, local.top - SAFE_CHROME_GAP_PX)
        break
    }
  }

  safe.left = Math.max(0, Math.min(safe.left, container.width - 1))
  safe.top = Math.max(0, Math.min(safe.top, container.height - 1))
  safe.right = Math.max(safe.left + 1, Math.min(safe.right, container.width))
  safe.bottom = Math.max(safe.top + 1, Math.min(safe.bottom, container.height))
  return safe
}

function nodeWorldBox(node) {
  const centerX = finiteNumber(node?.center?.x)
  const centerY = finiteNumber(node?.center?.y)
  const halfWidth = Math.max(0, finiteNumber(node?.width) / 2)
  const halfHeight = Math.max(0, finiteNumber(node?.height) / 2)
  return {minX: centerX - halfWidth, minY: centerY - halfHeight, maxX: centerX + halfWidth, maxY: centerY + halfHeight}
}

function completeSceneBounds(scene) {
  const boxes = []
  if ([scene?.bounds?.minX, scene?.bounds?.minY, scene?.bounds?.maxX, scene?.bounds?.maxY].every(Number.isFinite)) {
    boxes.push(scene.bounds)
  }
  for (const node of scene?.nodes || []) boxes.push(nodeWorldBox(node))
  for (const group of scene?.groups || []) {
    if ([group?.bounds?.minX, group?.bounds?.minY, group?.bounds?.maxX, group?.bounds?.maxY].every(Number.isFinite)) {
      boxes.push(group.bounds)
    }
  }
  for (const route of scene?.physicalRoutes || scene?.routes || []) {
    for (const point of route?.points || []) {
      if (Number.isFinite(point?.x) && Number.isFinite(point?.y)) {
        boxes.push({minX: point.x, minY: point.y, maxX: point.x, maxY: point.y})
      }
    }
  }
  if (boxes.length === 0) return {minX: 0, minY: 0, maxX: 1, maxY: 1}
  return {
    minX: Math.min(...boxes.map((box) => box.minX)),
    minY: Math.min(...boxes.map((box) => box.minY)),
    maxX: Math.max(...boxes.map((box) => box.maxX)),
    maxY: Math.max(...boxes.map((box) => box.maxY)),
  }
}

function glyphVisualSpecs(scene, glyphBoxes) {
  const nodeById = new Map((scene?.nodes || []).map((node) => [String(node?.id || ""), node]))
  return (glyphBoxes || []).flatMap((glyph) => {
    const node = nodeById.get(String(glyph?.nodeId || ""))
    const worldX = Number.isFinite(Number(glyph?.worldX)) ? Number(glyph.worldX) : Number(node?.center?.x)
    const worldY = Number.isFinite(Number(glyph?.worldY)) ? Number(glyph.worldY) : Number(node?.center?.y)
    if (!Number.isFinite(worldX) || !Number.isFinite(worldY)) return []
    const radius = Math.max(0, finiteNumber(glyph?.radius))
    const width = Math.max(0, finiteNumber(glyph?.width, finiteNumber(glyph?.right) - finiteNumber(glyph?.left))) || radius * 2
    const height = Math.max(0, finiteNumber(glyph?.height, finiteNumber(glyph?.bottom) - finiteNumber(glyph?.top))) || radius * 2
    const leftPad = glyph?.leftPad == null ? width / 2 : Math.max(0, finiteNumber(glyph.leftPad))
    const rightPad = glyph?.rightPad == null ? width / 2 : Math.max(0, finiteNumber(glyph.rightPad))
    const topPad = glyph?.topPad == null ? height / 2 : Math.max(0, finiteNumber(glyph.topPad))
    const bottomPad = glyph?.bottomPad == null ? height / 2 : Math.max(0, finiteNumber(glyph.bottomPad))
    return [{nodeId: String(glyph?.nodeId || ""), worldX, worldY, leftPad, rightPad, topPad, bottomPad}]
  })
}

function baseVisualSpecs(scene, glyphBoxes, routeStrokeWidth) {
  const bounds = completeSceneBounds(scene)
  const routeSpecs = (scene?.physicalRoutes || scene?.routes || []).flatMap((route) => {
    const declaredRouteWidth = Number(routeStrokeWidth)
    const strokeWidth = Number.isFinite(declaredRouteWidth) && declaredRouteWidth > 0
      ? declaredRouteWidth
      : Math.max(0, finiteNumber(route?.strokeWidth, CONSERVATIVE_ROUTE_STROKE_PX))
    const strokeRadius = strokeWidth / 2
    return (route?.points || []).flatMap((point) => {
      if (!Number.isFinite(point?.x) || !Number.isFinite(point?.y)) return []
      return [{
        worldX: point.x,
        worldY: point.y,
        leftPad: strokeRadius,
        rightPad: strokeRadius,
        topPad: strokeRadius,
        bottomPad: strokeRadius,
      }]
    })
  })
  return [
    {worldX: bounds.minX, worldY: bounds.minY, leftPad: 0, rightPad: 0, topPad: 0, bottomPad: 0},
    {worldX: bounds.maxX, worldY: bounds.maxY, leftPad: 0, rightPad: 0, topPad: 0, bottomPad: 0},
    ...routeSpecs,
    ...glyphVisualSpecs(scene, glyphBoxes),
  ]
}

function axisExtents(specs, scale, axis) {
  const worldKey = axis === "x" ? "worldX" : "worldY"
  const lowerPad = axis === "x" ? "leftPad" : "topPad"
  const upperPad = axis === "x" ? "rightPad" : "bottomPad"
  return {
    min: Math.min(...specs.map((spec) => (spec[worldKey] * scale) - finiteNumber(spec[lowerPad]))),
    max: Math.max(...specs.map((spec) => (spec[worldKey] * scale) + finiteNumber(spec[upperPad]))),
  }
}

function fitVisualSpecs(specs, viewport, safeRect, previousViewState = {}) {
  const width = Math.max(1, finiteNumber(viewport?.width, 1))
  const height = Math.max(1, finiteNumber(viewport?.height, 1))
  const safe = normalizeGodViewSafeRect(safeRect, {width, height})
  const requestedMinZoom = finiteNumber(viewport?.minZoom ?? viewport?.viewState?.minZoom ?? previousViewState?.minZoom, DEFAULT_MIN_ZOOM)
  const maxZoom = Math.max(
    ABSOLUTE_MIN_ZOOM,
    finiteNumber(viewport?.maxZoom ?? viewport?.viewState?.maxZoom ?? previousViewState?.maxZoom, DEFAULT_MAX_ZOOM),
  )
  const absoluteMinScale = 2 ** ABSOLUTE_MIN_ZOOM
  const maxScale = 2 ** maxZoom
  const safeWidth = safe.right - safe.left
  const safeHeight = safe.bottom - safe.top
  const fits = (scale) => {
    const x = axisExtents(specs, scale, "x")
    const y = axisExtents(specs, scale, "y")
    return x.max - x.min <= safeWidth + 1e-9 && y.max - y.min <= safeHeight + 1e-9
  }
  const guaranteedScale = (axis, safeSpan) => {
    const worldKey = axis === "x" ? "worldX" : "worldY"
    const lowerPad = axis === "x" ? "leftPad" : "topPad"
    const upperPad = axis === "x" ? "rightPad" : "bottomPad"
    const worldValues = specs.map((spec) => finiteNumber(spec[worldKey]))
    const worldSpan = Math.max(...worldValues) - Math.min(...worldValues)
    const fixedSpan = Math.max(...specs.map((spec) => finiteNumber(spec[lowerPad]))) +
      Math.max(...specs.map((spec) => finiteNumber(spec[upperPad])))
    if (worldSpan <= 0) return fixedSpan <= safeSpan ? maxScale : 0
    return Math.max(0, (safeSpan - fixedSpan) / worldSpan)
  }

  let scale = maxScale
  if (!fits(maxScale)) {
    if (!fits(absoluteMinScale)) {
      throw new RangeError("topology scene cannot fit fixed-pixel visuals above the absolute Deck camera floor")
    }
    let lower = Math.max(absoluteMinScale, Math.min(
      maxScale,
      guaranteedScale("x", safeWidth),
      guaranteedScale("y", safeHeight),
    ))
    if (!(lower > 0) || !fits(lower)) {
      lower = absoluteMinScale
    }
    let upper = maxScale
    for (let pass = 0; pass < 56; pass += 1) {
      const middle = (lower + upper) / 2
      if (fits(middle)) lower = middle
      else upper = middle
    }
    scale = lower
  }

  const x = axisExtents(specs, scale, "x")
  const y = axisExtents(specs, scale, "y")
  const safeCenterX = (safe.left + safe.right) / 2
  const safeCenterY = (safe.top + safe.bottom) / 2
  const targetX = ((width / 2) + ((x.min + x.max) / 2) - safeCenterX) / scale
  const targetY = ((height / 2) + ((y.min + y.max) / 2) - safeCenterY) / scale
  const zoom = Math.log2(scale)
  const minZoom = Math.max(ABSOLUTE_MIN_ZOOM, Math.min(requestedMinZoom, zoom))
  return {
    ...previousViewState,
    target: [targetX, targetY, 0],
    zoom,
    minZoom,
    maxZoom,
  }
}

function projectPoint(point, viewState, viewport) {
  const scale = 2 ** viewState.zoom
  return [
    (finiteNumber(viewport?.width, 1) / 2) + ((finiteNumber(point?.x) - viewState.target[0]) * scale),
    (finiteNumber(viewport?.height, 1) / 2) + ((finiteNumber(point?.y) - viewState.target[1]) * scale),
  ]
}

function projectGlyphSpecs(specs, viewState, viewport) {
  return specs.map((spec) => {
    const [x, y] = projectPoint({x: spec.worldX, y: spec.worldY}, viewState, viewport)
    return {
      nodeId: spec.nodeId,
      left: x - spec.leftPad,
      right: x + spec.rightPad,
      top: y - spec.topPad,
      bottom: y + spec.bottomPad,
    }
  })
}

function normalizedAdmission(result) {
  const admitted = Array.isArray(result)
    ? result
    : (Array.isArray(result?.admitted) ? result.admitted : [])
  const missingRequiredLabelIds = Array.isArray(result?.missingRequiredLabelIds)
    ? [...new Set(result.missingRequiredLabelIds.map((nodeId) => String(nodeId || "")).filter(Boolean))]
      .sort((left, right) => left.localeCompare(right))
    : []
  return {admitted, missingRequiredLabelIds}
}

function boxInside(box, safeRect) {
  return (
    finiteNumber(box?.left) >= safeRect.left - BROWSER_TOLERANCE_PX &&
    finiteNumber(box?.top) >= safeRect.top - BROWSER_TOLERANCE_PX &&
    finiteNumber(box?.right) <= safeRect.right + BROWSER_TOLERANCE_PX &&
    finiteNumber(box?.bottom) <= safeRect.bottom + BROWSER_TOLERANCE_PX
  )
}

function labelVisualSpecs(scene, labels, viewState, viewport) {
  const nodeById = new Map((scene?.nodes || []).map((node) => [String(node?.id || ""), node]))
  return labels.flatMap((label) => {
    const box = label?.box
    if (![box?.left, box?.top, box?.right, box?.bottom].every(Number.isFinite)) return []
    const node = nodeById.get(String(label?.nodeId || ""))
    let worldX = Number(node?.center?.x)
    let worldY = Number(node?.center?.y)
    if (!Number.isFinite(worldX) || !Number.isFinite(worldY)) {
      const scale = 2 ** viewState.zoom
      worldX = viewState.target[0] + ((((box.left + box.right) / 2) - (viewport.width / 2)) / scale)
      worldY = viewState.target[1] + ((((box.top + box.bottom) / 2) - (viewport.height / 2)) / scale)
    }
    const [screenX, screenY] = projectPoint({x: worldX, y: worldY}, viewState, viewport)
    return [{
      worldX,
      worldY,
      leftPad: screenX - box.left,
      rightPad: box.right - screenX,
      topPad: screenY - box.top,
      bottomPad: box.bottom - screenY,
    }]
  })
}

function runAdmission(admitLabels, scene, viewport, safeRect, glyphSpecs, viewState) {
  if (typeof admitLabels !== "function") return {admitted: [], missingRequiredLabelIds: []}
  return normalizedAdmission(admitLabels({
    scene,
    viewport,
    safeRect,
    viewState,
    projectedGlyphBoxes: projectGlyphSpecs(glyphSpecs, viewState, viewport),
  }))
}

/**
 * Fits immutable scene geometry, then performs no more than one label-aware
 * refit. `previous` is deliberately not an input to the calculation, which
 * makes identical calls idempotent and prevents recursive label chasing.
 */
export function fitTopologyScene({
  scene,
  viewport = {},
  safeRect,
  glyphBoxes = [],
  routeStrokeWidth,
  admitLabels,
} = {}) {
  const safe = normalizeGodViewSafeRect(safeRect, viewport)
  const canvas = normalizeGodViewSafeRect(
    {left: 0, top: 0, right: viewport?.width, bottom: viewport?.height},
    viewport,
  )
  const glyphSpecs = glyphVisualSpecs(scene, glyphBoxes)
  const baseSpecs = baseVisualSpecs(scene, glyphBoxes, routeStrokeWidth)
  let viewState = fitVisualSpecs(
    baseSpecs,
    viewport,
    safe,
    viewport?.viewState || {},
  )
  let admission = runAdmission(admitLabels, scene, viewport, canvas, glyphSpecs, viewState)

  if (admission.admitted.some((label) => !boxInside(label?.box, safe))) {
    const labelSpecs = labelVisualSpecs(scene, admission.admitted, viewState, viewport)
    viewState = fitVisualSpecs(
      [...baseSpecs, ...labelSpecs],
      viewport,
      safe,
      viewState,
    )
    admission = runAdmission(admitLabels, scene, viewport, safe, glyphSpecs, viewState)
  }

  const admittedLabels = admission.admitted.filter((label) => boxInside(label?.box, safe))
  const missingRequiredLabelIds = [...admission.missingRequiredLabelIds]
  return {
    ok: missingRequiredLabelIds.length === 0,
    viewState,
    fitZoom: viewState.zoom,
    admittedLabels,
    missingRequiredLabelIds,
  }
}

function focusScene(scene, group) {
  const nodeById = new Map((scene?.nodes || []).map((node) => [String(node?.id || ""), node]))
  const descendants = new Set([
    group?.id,
    group?.anchorId,
    group?.gatewayId,
    ...(group?.memberIds || []),
  ].map(String))
  const trunks = (scene?.routes || []).filter((route) => {
    const sourceId = String(route?.sourceId || "")
    const targetId = String(route?.targetId || "")
    return descendants.has(sourceId) || descendants.has(targetId)
  })
  const nodeIds = new Set([
    group?.anchorId,
    group?.gatewayId,
    ...(group?.memberIds || []),
    ...trunks.flatMap((route) => [route?.sourceId, route?.targetId]),
  ].map(String))
  const trunkIds = new Set(trunks.map((route) => String(route?.id || "")))
  const physicalRoutes = (scene?.physicalRoutes || scene?.routes || []).filter((route) => (
    trunkIds.has(String(route?.id || "")) ||
    (route?.semanticRouteIds || []).some((routeId) => trunkIds.has(String(routeId)))
  ))
  const manifoldIds = new Set(physicalRoutes.flatMap((route) => [
    route?.sourceManifoldId,
    route?.targetManifoldId,
    String(route?.id || "").endsWith(":trunk") || String(route?.id || "").endsWith(":rail")
      ? String(route.id).replace(/:(?:trunk|rail)$/, "")
      : null,
  ]).filter(Boolean))
  const neighborhood = {
    nodes: [...nodeIds].map((id) => nodeById.get(id)).filter(Boolean),
    groups: [group],
    routes: trunks,
    manifolds: (scene?.manifolds || []).filter((manifold) => manifoldIds.has(manifold.id)),
    physicalRoutes,
  }
  return {...neighborhood, bounds: completeSceneBounds(neighborhood)}
}

export function topologyGroupFocusScene(scene, groupId, fallbackGroup = null) {
  const normalizedId = String(groupId || "").trim()
  const group = (scene?.groups || []).find((candidate) => String(candidate?.id || "") === normalizedId)
  if (group) return focusScene(scene, group)

  // The radial atlas has no compound groups -- expanding elaborates it in place -- so the only
  // lookup here found nothing and focus failed closed for every cluster in the overview. A
  // caller that knows the membership supplies it instead; focusScene is purely id-driven, so a
  // synthesized group frames the same neighborhood a compound group would have.
  const memberIds = (fallbackGroup?.memberIds || []).map(String).filter((id) => id !== "")
  if (memberIds.length === 0) return null
  return focusScene(scene, {...fallbackGroup, id: normalizedId, memberIds})
}

export function focusTopologyGroup({
  scene,
  groupId,
  viewport = {},
  safeRect,
  glyphBoxForNode,
  routeStrokeWidth,
  admitLabels,
  // Focus normally fails closed: the caller framed this set deliberately, so a label that
  // will not fit means the frame is wrong. A neighborhood built by expanding a cluster is
  // the exception -- its size is whatever the operator expanded, and no viewport labels 24
  // members -- so the caller marks it and takes the fit with its unplaced ids instead.
  degradeUnplaceableLabels = false,
  fallbackGroup = null,
} = {}) {
  const normalizedId = String(groupId || "").trim()
  const neighborhood = topologyGroupFocusScene(scene, normalizedId, fallbackGroup)
  if (!neighborhood) return null
  if (typeof glyphBoxForNode !== "function") {
    throw new TypeError("topology focus requires a renderer-derived glyph box resolver")
  }
  const glyphBoxes = neighborhood.nodes.filter((node) => node?.render !== false).map((node) => {
    const measured = glyphBoxForNode(node)
    if (!measured || typeof measured !== "object") {
      throw new RangeError(`topology focus has no renderer-derived glyph box for ${String(node?.id || "")}`)
    }
    return {nodeId: node.id, ...measured}
  })
  const fit = fitTopologyScene({
    scene: neighborhood,
    viewport,
    safeRect,
    glyphBoxes,
    routeStrokeWidth,
    admitLabels,
  })
  if (!fit.ok && !degradeUnplaceableLabels) {
    throw new RangeError(
      `topology focus is missing required labels: ${fit.missingRequiredLabelIds.join(", ")}`,
    )
  }
  return fit
}
