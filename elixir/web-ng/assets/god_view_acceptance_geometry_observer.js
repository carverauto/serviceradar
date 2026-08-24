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

function projectedRoute(viewport, route) {
  if (typeof viewport?.project !== "function") return []
  return (route?.points || []).flatMap((point) => {
    const projected = viewport.project([finiteNumber(point?.x), finiteNumber(point?.y), 0])
    const x = Number(projected?.[0])
    const y = Number(projected?.[1])
    return Number.isFinite(x) && Number.isFinite(y) ? [{x, y}] : []
  })
}

function layerData(layers, id) {
  const layer = (layers || []).find((candidate) => candidate?.id === id)
  return Array.isArray(layer?.props?.data) ? layer.props.data : []
}

function renderedRouteStrokeWidth(layers, route) {
  const interactionKey = `local:${String(route?.id || "")}`
  const widths = (layers || [])
    .filter((layer) => layer?.id === "god-view-edges-mantle" || layer?.id === "god-view-edges-crust")
    .flatMap((layer) => {
      const props = layer?.props || {}
      const edge = (Array.isArray(props.data) ? props.data : []).find((candidate) =>
        candidate?.interactionKey === interactionKey
        || (candidate?.sourceId === route?.sourceId && candidate?.targetId === route?.targetId))
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

  return deepFreeze({
    sceneKey: String(effective?._layoutCacheKey || scene?.graphKey || ""),
    profileKey: String(scene?.profileKey || ""),
    counts: {
      semanticNodes: finiteNumber(manifest.nodes),
      semanticEdges: finiteNumber(manifest.semanticEdges),
      attachmentEdges: finiteNumber(manifest.attachmentEdges),
      renderedRoutes: Array.isArray(edgeData) ? edgeData.length : finiteNumber(manifest.renderedRoutes),
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
      anchorId: String(group?.anchorId || ""),
      gatewayId: String(group?.gatewayId || ""),
      memberIds: (group?.memberIds || []).map((id) => String(id)),
      box: plainBox(group?.bounds),
    })),
    routes: (scene?.routes || []).map((route) => ({
      sourceId: String(route?.sourceId || ""),
      targetId: String(route?.targetId || ""),
      strokeWidth: renderedRouteStrokeWidth(layers, route),
      points: (route?.points || []).map((point) => ({
        x: finiteNumber(point?.x),
        y: finiteNumber(point?.y),
      })),
      projectedPoints: projectedRoute(viewport, route),
    })),
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
