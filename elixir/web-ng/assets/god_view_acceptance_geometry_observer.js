import {topologySemanticLevel} from "./js/lib/god_view/topology_layout_mode"

const ACCEPTANCE_FLAG = "__SR_GOD_VIEW_ACCEPTANCE__"
const GEOMETRY_HOOK = "__SR_GOD_VIEW_GEOMETRY__"

function finiteNumber(value, fallback = 0) {
  const number = Number(value)
  return Number.isFinite(number) ? number : fallback
}

function plainBox(box = {}) {
  return {
    left: finiteNumber(box.left ?? box.minX),
    top: finiteNumber(box.top ?? box.minY),
    right: finiteNumber(box.right ?? box.maxX),
    bottom: finiteNumber(box.bottom ?? box.maxY),
  }
}

function deepFreeze(value) {
  if (value === null || typeof value !== "object" || Object.isFrozen(value)) return value
  for (const child of Object.values(value)) deepFreeze(child)
  return Object.freeze(value)
}

function nodeWorldBox(node) {
  const centerX = finiteNumber(node?.center?.x)
  const centerY = finiteNumber(node?.center?.y)
  const halfWidth = Math.max(0, finiteNumber(node?.width) / 2)
  const halfHeight = Math.max(0, finiteNumber(node?.height) / 2)
  return {
    left: centerX - halfWidth,
    top: centerY - halfHeight,
    right: centerX + halfWidth,
    bottom: centerY + halfHeight,
  }
}

function projectedRoute(viewport, points) {
  if (typeof viewport?.project !== "function") return []
  return (points || []).flatMap((point) => {
    const projected = viewport.project([finiteNumber(point?.x), finiteNumber(point?.y), 0])
    const x = Number(projected?.[0])
    const y = Number(projected?.[1])
    return Number.isFinite(x) && Number.isFinite(y) ? [{x, y}] : []
  })
}

function projectedPoint(viewport, point) {
  return projectedRoute(viewport, [point])[0] || {x: Number.NaN, y: Number.NaN}
}

function projectedWorldBox(viewport, box) {
  const points = projectedRoute(viewport, [
    {x: box?.minX, y: box?.minY},
    {x: box?.maxX, y: box?.minY},
    {x: box?.maxX, y: box?.maxY},
    {x: box?.minX, y: box?.maxY},
  ])
  if (points.length !== 4) return {left: Number.NaN, top: Number.NaN, right: Number.NaN, bottom: Number.NaN}
  return {
    left: Math.min(...points.map((point) => point.x)),
    top: Math.min(...points.map((point) => point.y)),
    right: Math.max(...points.map((point) => point.x)),
    bottom: Math.max(...points.map((point) => point.y)),
  }
}

function layerData(layers, id) {
  const layer = (layers || []).find((candidate) => candidate?.id === id)
  return Array.isArray(layer?.props?.data) ? layer.props.data : []
}

function sortedUniqueIds(values) {
  return [...new Set((values || []).map((value) => String(value || "")).filter((value) => value !== ""))]
    .sort((left, right) => left.localeCompare(right))
}

function topologyTransportLayers(layers) {
  return (layers || []).filter((layer) => (
    layer?.id?.startsWith("god-view-edges-mantle") ||
    layer?.id?.startsWith("god-view-edges-crust")
  ))
}

function plainPath(path) {
  return (Array.isArray(path) ? path : []).flatMap((point) => {
    const x = Number(Array.isArray(point) ? point[0] : point?.x)
    const y = Number(Array.isArray(point) ? point[1] : point?.y)
    return Number.isFinite(x) && Number.isFinite(y) ? [{x, y}] : []
  })
}

function renderedPhysicalRouteRecords(layers) {
  const records = new Map()
  for (const layer of topologyTransportLayers(layers)) {
    const props = layer?.props || {}
    for (const edge of Array.isArray(props.data) ? props.data : []) {
      const routeId = String(edge?.routeId || "")
      if (routeId === "") continue
      const path = typeof props.getPath === "function" ? props.getPath(edge) : edge?.path
      const record = records.get(routeId) || {edge, layerPaths: []}
      record.layerPaths.push({layerId: String(layer.id || ""), points: plainPath(path)})
      records.set(routeId, record)
    }
  }
  return records
}

function renderedPhysicalRouteLayers(layers) {
  return topologyTransportLayers(layers).map((layer) => {
    const routeIds = (Array.isArray(layer?.props?.data) ? layer.props.data : [])
      .map((edge) => String(edge?.routeId || ""))
    return {
      layerId: String(layer?.id || ""),
      routeCount: routeIds.length,
      routeIds,
    }
  })
}

function enabledTransportRouteFamilies(context, layers) {
  const renderedFamilies = new Set(topologyTransportLayers(layers).flatMap((layer) => {
    if (layer?.id?.startsWith("god-view-edges-mantle")) return ["mantle"]
    if (layer?.id?.startsWith("god-view-edges-crust")) return ["crust"]
    return []
  }))
  return ["mantle", "crust"].filter((family) => (
    context.state?.layers?.[family] === true || renderedFamilies.has(family)
  ))
}

function renderedRouteStrokeWidth(layers, route) {
  const widths = (layers || [])
    .filter((layer) => layer?.id?.startsWith("god-view-edges-mantle") || layer?.id?.startsWith("god-view-edges-crust"))
    .flatMap((layer) => {
      const props = layer?.props || {}
      const edge = (Array.isArray(props.data) ? props.data : []).find((candidate) => (
        String(candidate?.routeId || "") === String(route?.id || "")
      ))
      if (!edge) return []
      const accessorWidth = typeof props.getWidth === "function" ? props.getWidth(edge) : props.getWidth
      const widthScale = props.widthScale == null ? 1 : Number(props.widthScale)
      if (!Number.isFinite(accessorWidth) || accessorWidth <= 0 || !Number.isFinite(widthScale) || widthScale <= 0) {
        throw new RangeError(
          `acceptance geometry route ${String(route?.sourceId || "")} -> ${String(route?.targetId || "")} must have a finite positive rendered stroke width`,
        )
      }
      const scaledWidth = accessorWidth * widthScale
      const minimum = props.widthMinPixels == null ? 0 : Number(props.widthMinPixels)
      const maximum = props.widthMaxPixels == null ? Number.POSITIVE_INFINITY : Number(props.widthMaxPixels)
      if (!Number.isFinite(minimum) || minimum < 0
        || (props.widthMaxPixels != null && (!Number.isFinite(maximum) || maximum <= 0))) {
        throw new RangeError(
          `acceptance geometry route ${String(route?.sourceId || "")} -> ${String(route?.targetId || "")} must have a finite positive rendered stroke width`,
        )
      }
      return [Math.min(maximum, Math.max(minimum, scaledWidth))]
    })
  const strokeWidth = widths.reduce((maximum, width) => Math.max(maximum, width), 0)
  if (!Number.isFinite(strokeWidth) || strokeWidth <= 0) {
    throw new RangeError(
      `acceptance geometry route ${String(route?.sourceId || "")} -> ${String(route?.targetId || "")} must have a finite positive rendered stroke width`,
    )
  }
  return strokeWidth
}

function acceptanceGeometrySnapshot({context, effective, nodeData, edgeData, layers}) {
  const scene = effective?._topologyScene || {}
  const manifest = scene?.manifest || {}
  const [viewport] = typeof context.state?.deck?.getViewports === "function"
    ? context.state.deck.getViewports()
    : []
  const safeRect = context.state?.topologyLabelSafeRect || {
    left: 0,
    top: 0,
    right: finiteNumber(viewport?.width),
    bottom: finiteNumber(viewport?.height),
  }
  const viewState = context.state?.viewState || {}
  const labels = layerData(layers, "god-view-node-labels")
  const glyphIds = sortedUniqueIds((nodeData || []).map((node) => node?.id))
  const labelIds = sortedUniqueIds(labels.map((node) => node?.id))
  const labelIdSet = new Set(labelIds)
  const scenePhysicalRoutes = scene?.physicalRoutes || scene?.routes || []
  const sceneRouteById = new Map(scenePhysicalRoutes.map((route) => [String(route?.id || ""), route]))
  const renderedRouteRecords = renderedPhysicalRouteRecords(layers)
  const orderedRenderedRouteIds = [
    ...scenePhysicalRoutes
      .map((route) => String(route?.id || ""))
      .filter((routeId) => renderedRouteRecords.has(routeId)),
    ...[...renderedRouteRecords.keys()]
      .filter((routeId) => !sceneRouteById.has(routeId))
      .sort((left, right) => left.localeCompare(right)),
  ]
  const routes = orderedRenderedRouteIds.map((routeId) => {
    const record = renderedRouteRecords.get(routeId)
    const edge = record?.edge || {}
    const sceneRoute = sceneRouteById.get(routeId) || {}
    const points = record?.layerPaths?.[0]?.points || []
    return {
      id: routeId,
      auxiliary: sceneRoute?.auxiliary === true || edge?.auxiliary === true,
      sourceId: String(sceneRoute?.sourceId || edge?.sourceId || ""),
      targetId: String(sceneRoute?.targetId || edge?.targetId || ""),
      sourceContactId: String(sceneRoute?.sourceContactId || sceneRoute?.sourceId || edge?.sourceId || ""),
      targetContactId: String(sceneRoute?.targetContactId || sceneRoute?.targetId || edge?.targetId || ""),
      semanticRouteIds: (sceneRoute?.semanticRouteIds || edge?.semanticRouteIds || []).map(String),
      junctions: (sceneRoute?.junctions || []).map((junction) => ({
        id: String(junction?.id || ""),
        point: {x: finiteNumber(junction?.point?.x), y: finiteNumber(junction?.point?.y)},
        projectedPoint: projectedPoint(viewport, junction?.point),
      })),
      strokeWidth: renderedRouteStrokeWidth(layers, {...sceneRoute, ...edge, id: routeId}),
      scenePoints: plainPath(sceneRoute?.points),
      layerPaths: record?.layerPaths || [],
      points,
      projectedPoints: projectedRoute(viewport, points),
    }
  })

  return deepFreeze({
    sceneKey: String(effective?._layoutCacheKey || scene?.graphKey || ""),
    profileKey: String(scene?.profileKey || ""),
    semanticLevel: topologySemanticLevel(effective),
    glyphIds,
    labelIds,
    unlabeledGlyphIds: glyphIds.filter((nodeId) => !labelIdSet.has(nodeId)),
    counts: {
      semanticNodes: finiteNumber(manifest.nodes),
      semanticEdges: finiteNumber(manifest.semanticEdges),
      attachmentEdges: finiteNumber(manifest.attachmentEdges),
      renderedRoutes: Array.isArray(edgeData)
        ? edgeData.filter((edge) => edge?.auxiliary !== true).length
        : finiteNumber(manifest.renderedRoutes),
      physicalRoutes: Array.isArray(scene?.physicalRoutes)
        ? scene.physicalRoutes.length
        : Array.isArray(scene?.routes) ? scene.routes.length : 0,
      renderedPhysicalRoutes: renderedRouteRecords.size,
      manifolds: Array.isArray(scene?.manifolds) ? scene.manifolds.length : 0,
      renderedGlyphs: Array.isArray(nodeData) ? nodeData.length : finiteNumber(manifest.renderedGlyphs),
      admittedLabels: labels.length,
    },
    safeRect: plainBox(safeRect),
    viewState: {
      target: [
        finiteNumber(viewState?.target?.[0]),
        finiteNumber(viewState?.target?.[1]),
        finiteNumber(viewState?.target?.[2]),
      ],
      zoom: finiteNumber(viewState.zoom),
      minZoom: finiteNumber(viewState.minZoom),
      maxZoom: finiteNumber(viewState.maxZoom),
    },
    nodes: (scene?.nodes || []).map((node) => ({
      id: String(node?.id || ""),
      kind: String(node?.kind || ""),
      groupId: node?.groupId == null ? null : String(node.groupId),
      box: nodeWorldBox(node),
    })),
    groups: (scene?.groups || []).map((group) => ({
      id: String(group?.id || ""),
      parentGroupId: group?.parentGroupId == null ? null : String(group.parentGroupId),
      anchorId: String(group?.anchorId || ""),
      gatewayId: String(group?.gatewayId || ""),
      memberIds: (group?.memberIds || []).map((id) => String(id)),
      box: plainBox(group?.bounds),
      projectedBox: projectedWorldBox(viewport, group?.bounds),
    })),
    scenePhysicalRouteIds: scenePhysicalRoutes.map((route) => String(route?.id || "")),
    enabledTransportRouteFamilies: enabledTransportRouteFamilies(context, layers),
    renderedPhysicalRouteLayers: renderedPhysicalRouteLayers(layers),
    routes,
    glyphs: (nodeData || []).flatMap((node) => {
      if (typeof viewport?.project !== "function") return []
      const projected = viewport.project(node?.position || [0, 0, 0])
      const x = Number(projected?.[0])
      const y = Number(projected?.[1])
      if (!Number.isFinite(x) || !Number.isFinite(y)) return []
      const managedVisualDensity = context.state?.managedTopologyVisualDensity
      const measuredRadius = typeof context.nodeVisibleOuterRadiusPixels === "function"
        ? context.nodeVisibleOuterRadiusPixels(node, {managedVisualDensity})
        : context.nodeHaloRadiusPixels?.(node)
      const radius = Math.max(0, finiteNumber(measuredRadius))
      return [{
        nodeId: String(node?.id || ""),
        left: x - radius,
        top: y - radius,
        right: x + radius,
        bottom: y + radius,
      }]
    }),
    labels: labels.flatMap((node) => {
      const box = node?.labelAdmission?.box
      if (![box?.left, box?.top, box?.right, box?.bottom].every(Number.isFinite)) return []
      return [{nodeId: String(node?.id || ""), box: plainBox(box)}]
    }),
  })
}

export function installGodViewAcceptanceGeometryObserver(context, target = globalThis.window) {
  if (!context?.state || !target) return () => {}
  const observer = (frame) => {
    if (target[ACCEPTANCE_FLAG] !== true) {
      delete target[GEOMETRY_HOOK]
      return
    }
    const snapshot = acceptanceGeometrySnapshot(frame)
    target[GEOMETRY_HOOK] = () => snapshot
  }
  context.state.renderFrameObserver = observer
  return () => {
    if (context.state.renderFrameObserver === observer) delete context.state.renderFrameObserver
    delete target[GEOMETRY_HOOK]
  }
}
