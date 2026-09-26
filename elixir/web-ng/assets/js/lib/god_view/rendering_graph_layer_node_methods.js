import {COORDINATE_SYSTEM} from "@deck.gl/core"
import {LineLayer, ScatterplotLayer, TextLayer} from "@deck.gl/layers"
import {admitTopologyLabels} from "./rendering_label_collision"
import {nodeGlyphLayerData} from "./rendering_node_frame"
import {
  managedNodeOuterRadiusCap,
  managedVisualDensityContract,
  normalizeManagedVisualDensity,
} from "./rendering_managed_visual_density"
import {hasExpandedCluster, hasManagedTopologyScene, topologySemanticLevel} from "./topology_layout_mode"

const labelSelections = new WeakMap()

/**
 * Projects world positions to CSS pixels like `viewport.project(position)`, without the
 * three arrays that call allocates. A non-geospatial deck viewport is a plain matrix
 * multiply by `pixelProjectionMatrix`; anything else falls back to `project`.
 */
function screenProjector(viewport) {
  const matrix = viewport?.isGeospatial === false ? viewport.pixelProjectionMatrix : null
  const direct = Boolean(matrix && matrix.length === 16)
  const zScale = Number(viewport?.distanceScales?.unitsPerMeter?.[2] ?? 1)
  const projector = {
    x: NaN,
    y: NaN,
    project(position) {
      const px = Number(position?.[0] ?? 0)
      const py = Number(position?.[1] ?? 0)
      const pz = Number(position?.[2] ?? 0) * zScale
      if (direct) {
        const w = matrix[3] * px + matrix[7] * py + matrix[11] * pz + matrix[15]
        projector.x = (matrix[0] * px + matrix[4] * py + matrix[8] * pz + matrix[12]) / w
        projector.y = (matrix[1] * px + matrix[5] * py + matrix[9] * pz + matrix[13]) / w
      } else {
        const projected = viewport.project(position || [0, 0, 0])
        projector.x = Number(projected?.[0])
        projector.y = Number(projected?.[1])
      }
      return Number.isFinite(projector.x) && Number.isFinite(projector.y)
    },
  }
  return projector
}

// Label priority, most significant first. Each numeric field sorts descending; ties fall
// through to the label text, ascending.
const LABEL_PRIORITY_FIELDS = [
  (ctx, node) => (node?.selected === true || ctx.focusedNodeLabel(node) ? 1 : 0),
  (ctx, node) => (ctx.unplacedNodeLabel(node) ? 1 : 0),
  (ctx, node) => (ctx.backboneLabelCandidate(node) ? 1 : 0),
  (_ctx, node) => (String(node?.details?.cluster_kind || "") === "endpoint-anchor" ? 1 : 0),
  (_ctx, node) => (String(node?.details?.identity_source || "") !== "mapper_topology_sighting" ? 1 : 0),
  (_ctx, node) => Number(node?.clusterCount || 1),
  (_ctx, node) => (Number(node?.state ?? 3) === 0 ? 1 : 0),
  (_ctx, node) => (Number(node?.state ?? 3) === 1 ? 1 : 0),
  (_ctx, node) => Math.round(Number(node?.pps || 0)),
]

export const godViewRenderingGraphLayerNodeMethods = {
  visualClusterCount(node) {
    const clusterKind = String(node?.details?.cluster_kind || "")
    if (clusterKind === "endpoint-summary") {
      const expanded = node?.details?.cluster_expanded === true || node?.details?.cluster_expanded === "true"
      if (expanded) return 1
      return Math.max(1, Number(node?.clusterCount || 1))
    }
    return 1
  },
  nodeHaloRadiusPixels(node, options = {}) {
    const radius = Math.min(8 + (this.visualClusterCount(node) - 1) * 0.45, 26) * 2.5
    if (!options.managedVisualDensity) return radius
    return Math.min(radius, managedNodeOuterRadiusCap(node, options.managedVisualDensity))
  },
  nodeRingRadiusPixels(node, options = {}) {
    const baseRadius = Math.min(12 + (this.visualClusterCount(node) - 1) * 0.45, 32)
    const phase = Number(this.state?.animationPhase)
    const index = Number(node?.index)
    const breathe = Math.sin(
      ((Number.isFinite(phase) ? phase : 0) * 2.0) + (Number.isFinite(index) ? index : 0),
    ) * 2.0
    const radius = baseRadius + breathe
    if (!options.managedVisualDensity) return radius
    const outerCap = managedNodeOuterRadiusCap(node, options.managedVisualDensity)
    const halfLineWidth = node?.selected ? 1 : 0.5
    return Math.min(radius, Math.max(0, outerCap - halfLineWidth))
  },
  nodeCoreRadiusPixels(node, options = {}) {
    const radius = Math.min(4 + (this.visualClusterCount(node) - 1) * 0.2, 14)
    if (!options.managedVisualDensity) return radius
    return Math.min(radius, managedNodeOuterRadiusCap(node, options.managedVisualDensity))
  },
  nodeVisibleOuterRadiusPixels(node, options = {}) {
    const halo = this.nodeHaloRadiusPixels(node, options)
    const ring = this.nodeRingRadiusPixels(node, options) + (node?.selected ? 1 : 0.5)
    return Math.max(halo, ring, this.nodeCoreRadiusPixels(node, options))
  },
  labelBudgetForShape(shape, candidateCount = 0) {
    switch (shape) {
      case "local":
        return Math.min(Math.max(candidateCount, 0), 24)
      case "regional":
        return Math.min(Math.max(candidateCount, 0), 16)
      case "global":
        return Math.min(Math.max(candidateCount, 0), 8)
      default:
        return 0
    }
  },
  endpointSummaryLabelBudgetForShape(shape) {
    switch (shape) {
      case "local":
        return 6
      case "regional":
        return 3
      case "global":
        return 1
      default:
        return 0
    }
  },
  expandedEndpointMemberLabelBudgetForShape(shape) {
    switch (shape) {
      case "local":
        return 48
      case "regional":
        return 12
      default:
        return 0
    }
  },
  nodeLabelPixelOffset(node) {
    const side = String(node?.details?.cluster_panel_side || "").trim()
    if (side === "right") return [14, 0]
    if (side === "left") return [-14, 0]
    if (side === "down") return [0, 16]
    return [0, -16]
  },
  nodeLabelTextAnchor(node) {
    const side = String(node?.details?.cluster_panel_side || "").trim()
    if (side === "right") return "start"
    if (side === "left") return "end"
    return "middle"
  },
  nodeLabelAlignmentBaseline(node) {
    const side = String(node?.details?.cluster_panel_side || "").trim()
    if (side === "right" || side === "left") return "center"
    if (side === "down") return "top"
    return "bottom"
  },
  opaqueIdentityLabel(node) {
    const label = String(node?.label || "")
    const id = String(node?.id || "")
    return label.startsWith("sr:") || (label.trim() === "" && id.startsWith("sr:"))
  },
  endpointSummaryLabel(node) {
    return String(node?.details?.cluster_kind || "") === "endpoint-summary"
  },
  expandedEndpointMemberLabel(node) {
    return String(node?.details?.cluster_kind || "") === "endpoint-member"
      && (node?.details?.cluster_expanded === true || node?.details?.cluster_expanded === "true")
  },
  unplacedNodeLabel(node) {
    return node?.details?.topology_unplaced === true
  },
  backboneLabelCandidate(node) {
    return !this.endpointSummaryLabel(node) && !this.expandedEndpointMemberLabel(node)
  },
  focusedNodeLabel(node) {
    if (node?.focused === true) return true
    const hoveredNodeIndex = this.state?.hoveredNodeIndex
    return hoveredNodeIndex !== null && hoveredNodeIndex !== undefined && hoveredNodeIndex === node?.index
  },
  nodeLabelCandidate(node) {
    if (node?.selected === true || this.focusedNodeLabel(node)) return true
    const details = node?.details || {}
    const clusterKind = String(details?.cluster_kind || "")
    const expandedEndpointMember = this.expandedEndpointMemberLabel(node)
    if (clusterKind === "endpoint-member" && !expandedEndpointMember) return false
    // Topology sightings with a human hostname (switchcff8f2) should stay
    // labeled. Only suppress opaque sr: identities from that source.
    if (
      String(details?.identity_source || "") === "mapper_topology_sighting" &&
      !expandedEndpointMember &&
      this.opaqueIdentityLabel(node)
    ) {
      return false
    }
    return !this.opaqueIdentityLabel(node)
  },
  /**
   * Orders two label candidates by `LABEL_PRIORITY_FIELDS`, field by field, without building
   * a priority tuple per comparison: a label pass sorts every visible node.
   */
  compareNodeLabelPriority(left, right) {
    for (const field of LABEL_PRIORITY_FIELDS) {
      const compare = Number(field(this, right) || 0) - Number(field(this, left) || 0)
      if (compare !== 0) return compare
    }
    return String(left?.label || left?.id || "").localeCompare(String(right?.label || right?.id || ""))
  },
  selectNodeLabels(nodeData, shape, options = {}) {
    if (!Array.isArray(nodeData) || nodeData.length === 0) return []
    if (options.managedVisualDensity) {
      return nodeData
        .filter((node) => String(node?.id || "") !== "")
        .sort((left, right) => this.compareNodeLabelPriority(left, right))
    }
    const attended = nodeData.filter((node) => node?.selected === true || this.focusedNodeLabel(node))
    const candidates = nodeData.filter((node) => this.nodeLabelCandidate(node))
    const ordered = [...candidates].sort((left, right) => this.compareNodeLabelPriority(left, right))
    const labelShape = options.managedVisualDensity
      ? managedVisualDensityContract(options.managedVisualDensity).labelShape
      : shape
    const memberBudget = this.expandedEndpointMemberLabelBudgetForShape(labelShape)
    const expandedEndpointMembers = ordered
      .filter((node) => this.expandedEndpointMemberLabel(node))
      .slice(0, memberBudget)
    const unplacedNodes = ordered.filter((node) => this.unplacedNodeLabel(node))
    const nonExpandedCandidates = ordered.filter((node) => !this.expandedEndpointMemberLabel(node))
    const budget = this.labelBudgetForShape(labelShape, nonExpandedCandidates.length)
    const endpointSummaryBudget = this.endpointSummaryLabelBudgetForShape(labelShape)
    if (budget <= 0 && attended.length === 0 && expandedEndpointMembers.length === 0 && unplacedNodes.length === 0) return []
    const orderedBackbone = ordered.filter((node) => this.backboneLabelCandidate(node))
    const orderedEndpointSummaries = ordered.filter((node) => {
      if (!this.endpointSummaryLabel(node)) return false
      const expanded = node?.details?.cluster_expanded === true || node?.details?.cluster_expanded === "true"
      return !expanded
    })
    const picked = []
    const seen = new Set()
    let endpointSummaryCount = 0

    for (const node of [...attended, ...expandedEndpointMembers, ...unplacedNodes]) {
      const id = String(node?.id || "")
      if (id === "" || seen.has(id)) continue
      seen.add(id)
      picked.push(node)
    }

    for (const node of [...orderedBackbone, ...orderedEndpointSummaries]) {
      const id = String(node?.id || "")
      if (id === "" || seen.has(id)) continue
      if (this.endpointSummaryLabel(node) && node?.selected !== true) {
        if (endpointSummaryCount >= endpointSummaryBudget) continue
        endpointSummaryCount += 1
      }
      seen.add(id)
      picked.push(node)
      if (picked.length >= budget + expandedEndpointMembers.length + attended.length + unplacedNodes.length) break
    }

    return picked
  },
  /**
   * `selectNodeLabels` for a render frame, reused while only the camera moves.
   *
   * The selection sorts every visible node, and it depends on the node list, the shape, the
   * managed density, and the hovered and selected node -- not on the camera. A pan or zoom
   * refreshes layers with the same `nodeData`, so it gets the same selection back.
   */
  cachedNodeLabelSelection(nodeData, shape, options = {}) {
    if (!Array.isArray(nodeData)) return this.selectNodeLabels(nodeData, shape, options)
    const key = [
      shape,
      options.managedVisualDensity || "",
      this.state?.hoveredNodeIndex ?? "",
      this.state?.selectedNodeIndex ?? "",
    ].join("|")
    const cached = labelSelections.get(nodeData)
    if (cached && cached.owner === this && cached.key === key) return cached.value
    const value = this.selectNodeLabels(nodeData, shape, options)
    labelSelections.set(nodeData, {owner: this, key, value})
    return value
  },
  nodeLabelAdmissionPool(_nodeData, selectedCandidates, _options = {}) {
    return selectedCandidates
  },
  activeTopologyLabelViewport() {
    if (typeof this.state?.deck?.getViewports !== "function") return null
    // getViewports() itself throws: deck asserts on its own view state, and an unmeasured
    // container gives it a 0-sized one, so a hard refresh reaches here before layout has
    // settled and the assertion escapes as "deck.gl: assertion failed" -- with the message
    // stripped in a production build, naming nothing. It surfaced as "topology render
    // unavailable" for the whole surface. Having no usable viewport is already an expected
    // state for the caller, which degrades label admission rather than failing, so route the
    // throw into that path instead of letting it take down the render.
    let viewports = null
    try {
      viewports = this.state.deck.getViewports()
    } catch {
      return null
    }
    const [viewport] = viewports || []
    return viewport && typeof viewport.project === "function" ? viewport : null
  },
  topologyLabelSafeRect(viewport, measured = this.state?.topologyLabelSafeRect) {
    if (measured && [measured.left, measured.top, measured.right, measured.bottom].every(Number.isFinite)) {
      return measured
    }

    const canvasRect = this.state?.canvas?.getBoundingClientRect?.()
    const width = Number(canvasRect?.width ?? viewport?.width)
    const height = Number(canvasRect?.height ?? viewport?.height)
    return {
      left: 0,
      top: 0,
      right: Number.isFinite(width) ? Math.max(0, width) : 0,
      bottom: Number.isFinite(height) ? Math.max(0, height) : 0,
    }
  },
  topologyRouteStrokeWidth(route, options = {}) {
    if (options.managedVisualDensity) {
      if (this.state?.layers?.mantle === false && this.state?.layers?.crust === false) return 0
      return managedVisualDensityContract(options.managedVisualDensity).routeMaxWidth
    }
    const metadata = route?.metadata && typeof route.metadata === "object" ? route.metadata : {}
    for (const value of [route?.strokeWidth, route?.width, metadata.strokeWidth, metadata.stroke_width]) {
      const width = Number(value)
      if (Number.isFinite(width) && width > 0) return width
    }
    // Scene routes do not otherwise carry live telemetry widths. Protect the
    // maximum width of the visible routed layer so fallback admission cannot
    // overlap a stroke that expands after telemetry or focus changes.
    if (this.state?.layers?.mantle !== false) return 38
    if (this.state?.layers?.crust !== false) return 12
    return 0
  },
  admitNodeLabelsForViewport(effective, labelCandidates, protectedNodes = labelCandidates, options = {}) {
    const viewport = options.viewport || this.activeTopologyLabelViewport()
    if (!viewport) {
      const missingRequiredLabelIds = (options.requiredLabelIds || (
        options.managedVisualDensity ? (labelCandidates || []).map((node) => node?.id) : []
      ))
        .map((nodeId) => String(nodeId || ""))
        .filter(Boolean)
        .sort()
      return {
        admitted: [],
        detailsFallbackIds: (labelCandidates || [])
          .filter((node) => node?.selected === true || this.focusedNodeLabel(node))
          .map((node) => String(node?.id || ""))
          .filter(Boolean)
          .sort(),
        missingRequiredLabelIds,
      }
    }

    // Every protected glyph is an obstacle, so this loop visits every visible node on each
    // camera move. It projects without allocating, and keeps only glyphs that reach the safe
    // rect: a label must lie inside the safe rect, so a glyph wholly outside it can never
    // block one. A candidate's own glyph is always kept, since its label anchors to it.
    const safeRect = this.topologyLabelSafeRect(viewport, options.safeRect)
    const candidateIds = new Set()
    for (const node of labelCandidates || []) {
      const nodeId = String(node?.id || "")
      if (nodeId !== "") candidateIds.add(nodeId)
    }
    const projectedById = new Map()
    const glyphBoxes = {nodeIds: [], boxes: new Float64Array(4 * (protectedNodes?.length || 0)), count: 0}
    const projector = screenProjector(viewport)
    for (const node of protectedNodes || []) {
      const nodeId = String(node?.id || "")
      if (nodeId === "") continue
      if (!projector.project(node?.position)) continue
      const x = projector.x
      const y = projector.y
      const candidate = candidateIds.has(nodeId)
      if (candidate) projectedById.set(nodeId, [x, y])
      const radius = Math.max(0, Number(this.nodeVisibleOuterRadiusPixels(node, options)) || 0)
      const left = x - radius
      const top = y - radius
      const right = x + radius
      const bottom = y + radius
      if (!candidate && (right < safeRect.left || left > safeRect.right || bottom < safeRect.top || top > safeRect.bottom)) {
        continue
      }
      const offset = glyphBoxes.count * 4
      glyphBoxes.boxes[offset] = left
      glyphBoxes.boxes[offset + 1] = top
      glyphBoxes.boxes[offset + 2] = right
      glyphBoxes.boxes[offset + 3] = bottom
      glyphBoxes.nodeIds.push(nodeId)
      glyphBoxes.count += 1
    }

    const labelShape = options.managedVisualDensity
      ? managedVisualDensityContract(options.managedVisualDensity).labelShape
      : effective?.shape
    const fontSize = labelShape === "local" ? 12 : 10
    const candidateCount = Array.isArray(labelCandidates) ? labelCandidates.length : 0
    const candidates = (labelCandidates || []).flatMap((node, candidateIndex) => {
      const nodeId = String(node?.id || "")
      const point = projectedById.get(nodeId)
      if (!point) return []
      const summary = this.endpointSummaryLabel(node)
      return [{
        nodeId,
        text: String(node?.label || nodeId),
        point,
        selected: node?.selected === true,
        focused: this.focusedNodeLabel(node),
        role: summary ? "summary" : this.backboneLabelCandidate(node) ? "infrastructure" : "member",
        state: node?.state,
        operUp: node?.operUp,
        pps: node?.pps,
        operationalRelevance: options.preserveCandidateOrder
          ? candidateCount - candidateIndex
          : undefined,
        fontSize,
      }]
    })
    const routeCorridors = (
      effective?._topologyScene?.physicalRoutes || effective?._topologyScene?.routes || []
    ).flatMap((route) => {
      const points = (route?.points || []).flatMap((point) => {
        const projected = viewport.project([Number(point?.x), Number(point?.y), 0])
        const x = Number(projected?.[0])
        const y = Number(projected?.[1])
        return Number.isFinite(x) && Number.isFinite(y) ? [[x, y]] : []
      })
      if (points.length < 2) return []
      return [{
        sourceId: String(route?.sourceId || ""),
        targetId: String(route?.targetId || ""),
        points,
        strokeWidth: this.topologyRouteStrokeWidth(route, options),
      }]
    })
    const suppliedMeasureText = options.measureText || this.state?.topologyLabelMeasureText
    const measureText = typeof suppliedMeasureText === "function"
      ? (text, candidate) => suppliedMeasureText(text, candidate)
      : undefined

    return admitTopologyLabels({
      candidates,
      glyphBoxes,
      routeCorridors,
      safeRect,
      maximumCount: options.maximumLabelCount,
      requiredLabelIds: options.requiredLabelIds || (
        options.managedVisualDensity ? candidates.map((candidate) => candidate.nodeId) : undefined
      ),
      measureText,
    })
  },
  buildNodeAndLabelLayers(effective, nodeData, edgeLabelData) {
    const managedTopologyScene = hasManagedTopologyScene(effective)
    const managedVisualDensity = managedTopologyScene
      ? normalizeManagedVisualDensity(this.state.managedTopologyVisualDensity)
      : null
    const densityOptions = managedVisualDensity ? {managedVisualDensity} : {}
    const labelShape = managedVisualDensity
      ? managedVisualDensityContract(managedVisualDensity).labelShape
      : effective.shape
    const selectedLabelCandidates = this.cachedNodeLabelSelection(nodeData, effective.shape, densityOptions)
    const labelCandidates = this.nodeLabelAdmissionPool(nodeData, selectedLabelCandidates, densityOptions)
    const labelAdmission = this.admitNodeLabelsForViewport(effective, labelCandidates, nodeData, {
      ...densityOptions,
      requiredLabelIds: managedTopologyScene
        ? nodeData.map((node) => String(node?.id || "")).filter(Boolean)
        : undefined,
    })
    if (managedTopologyScene && labelAdmission.missingRequiredLabelIds.length > 0) {
      const semanticLevel = topologySemanticLevel(effective)
      // Fail closed only for a bounded, deliberately framed scene, where a label that
      // cannot be placed means the frame itself is wrong.
      //
      // The unbounded case is expansion -- it can add arbitrarily many member nodes to a
      // scene sized for a handful. That property belongs to the expansion, not to the
      // overview mode it was originally attached to: while the semantic level had no
      // writer every scene read as "overview", so gating on the level alone happened to
      // cover expansion. Now that expanding promotes a graph to detail, gating on the
      // level would fail closed on precisely the scene that needs to degrade.
      //
      // The focus path in rendering_scene_view.js is a deliberate frame and still fails
      // closed. Dropped ids stay observable for diagnostics.
      if (semanticLevel === "detail" && !hasExpandedCluster(effective)) {
        throw new RangeError(
          `managed topology ${semanticLevel} is missing required labels: ` +
          labelAdmission.missingRequiredLabelIds.join(", "),
        )
      }
      this.state.topologyDroppedLabelIds = [...labelAdmission.missingRequiredLabelIds]
    } else if (managedTopologyScene) {
      this.state.topologyDroppedLabelIds = []
    }
    const admittedById = new Map()
    for (const admitted of labelAdmission.admitted) admittedById.set(admitted.nodeId, admitted)
    const nodeById = new Map()
    if (admittedById.size > 0) {
      for (const node of nodeData) {
        const id = String(node?.id || "")
        if (admittedById.has(id)) nodeById.set(id, node)
      }
    }
    const labelData = labelAdmission.admitted.flatMap((admitted) => {
      const node = nodeById.get(admitted.nodeId)
      return node ? [{...node, labelAdmission: admitted}] : []
    })
    this.state.topologyLabelDetailsFallbackIds = [...labelAdmission.detailsFallbackIds]

    // Glyph layers take deck.gl binary data: `length` plus the packed `getPosition` column.
    // The remaining accessors read the node by index and write colors into deck's reusable
    // `target`, so rebuilding these attributes allocates nothing per node.
    const glyphData = nodeGlyphLayerData(nodeData)
    const glyphNodes = glyphData.nodes
    const security = this.state.layers.security
    const writeNodeColor = (target, node, alpha) => {
      const color = security ? this.nodeColor(node?.state) : this.nodeNeutralColor(node?.operUp)
      target[0] = color[0]
      target[1] = color[1]
      target[2] = color[2]
      target[3] = alpha === undefined ? (color[3] ?? 255) : alpha
      return target
    }

    return [
      new LineLayer({
        id: "god-view-node-tethers",
        data: nodeData.filter((d) => Number(d.zHeight || 0) > 0),
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        getSourcePosition: (d) => [d.position[0], d.position[1], 0],
        getTargetPosition: (d) => d.position,
        getColor: (d) => {
          const c = this.state.layers.security ? this.nodeColor(d.state) : this.nodeNeutralColor(d.operUp)
          return [c[0], c[1], c[2], 80]
        },
        getWidth: 1,
        widthUnits: "pixels",
        pickable: false,
        parameters: {
          depthTest: false,
          depthWrite: false,
        },
      }),
      new ScatterplotLayer({
        id: "god-view-nodes-halo",
        data: glyphData,
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        getRadius: (_, {index}) => this.nodeHaloRadiusPixels(glyphNodes[index], densityOptions),
        radiusUnits: "pixels",
        filled: true,
        stroked: false,
        pickable: true,
        getFillColor: (_, {index, target}) => writeNodeColor(target, glyphNodes[index], 15),
        parameters: {
          blend: true,
          blendFunc: this.state.visual.particleBlend,
          depthTest: false,
          depthWrite: false,
        },
        updateTriggers: {
          getRadius: managedVisualDensity,
        },
      }),
      new ScatterplotLayer({
        id: "god-view-nodes-ring",
        data: glyphData,
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        getRadius: (_, {index}) => this.nodeRingRadiusPixels(glyphNodes[index], densityOptions),
        radiusUnits: "pixels",
        radiusMinPixels: 5,
        stroked: true,
        filled: false,
        lineWidthUnits: "pixels",
        pickable: false,
        getLineWidth: (_, {index}) => (glyphNodes[index]?.selected ? 2 : 1),
        getLineColor: (_, {index, target}) => writeNodeColor(target, glyphNodes[index]),
        parameters: {
          depthTest: false,
          depthWrite: false,
        },
        updateTriggers: {
          getRadius: [this.state.animationPhase, managedVisualDensity],
        },
      }),
      new ScatterplotLayer({
        id: "god-view-nodes-hitbox",
        data: glyphData,
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        getRadius: (_, {index}) => this.nodeHaloRadiusPixels(glyphNodes[index], densityOptions),
        radiusUnits: "pixels",
        stroked: false,
        filled: true,
        pickable: true,
        opacity: 0,
        getFillColor: [0, 0, 0, 1],
        parameters: {
          depthTest: false,
          depthWrite: false,
        },
        updateTriggers: {
          getRadius: managedVisualDensity,
        },
      }),
      new ScatterplotLayer({
        id: "god-view-nodes",
        data: glyphData,
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        getRadius: (_, {index}) => this.nodeCoreRadiusPixels(glyphNodes[index], densityOptions),
        radiusUnits: "pixels",
        radiusMinPixels: 3,
        stroked: false,
        filled: true,
        pickable: true,
        getFillColor: this.state.visual.nodeFill,
        parameters: {
          depthTest: false,
          depthWrite: false,
        },
        updateTriggers: {
          getRadius: managedVisualDensity,
        },
      }),
      ...(managedTopologyScene || (
        this.state.layers.mantle &&
        (effective.shape === "local" || effective.shape === "regional" || effective.shape === "global")
      )
        ? [
            new TextLayer({
              id: "god-view-node-labels",
              data: labelData,
              coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
              getPosition: (d) => d.position,
              getText: (d) => d.label,
              getSize: labelShape === "local" ? 12 : 10,
              sizeUnits: "pixels",
              sizeMinPixels: labelShape === "local" ? 10 : 8,
              getColor: this.state.visual.label,
              fontFamily: "Inter, system-ui, sans-serif",
              fontWeight: 600,
              getPixelOffset: (d) => d.labelAdmission.pixelOffset,
              getTextAnchor: (d) => d.labelAdmission.textAnchor,
              getAlignmentBaseline: (d) => d.labelAdmission.alignmentBaseline,
              billboard: true,
              pickable: true,
              updateTriggers: {
                getPixelOffset: labelData.map((node) => `${node.id}:${node.labelAdmission.pixelOffset.join(",")}`).join("|"),
                getTextAnchor: labelData.map((node) => `${node.id}:${node.labelAdmission.textAnchor}`).join("|"),
                getAlignmentBaseline: labelData.map((node) => `${node.id}:${node.labelAdmission.alignmentBaseline}`).join("|"),
              },
            }),
          ]
        : []),
      ...(this.state.layers.mantle && !managedTopologyScene && (effective.shape === "local" || effective.shape === "regional")
        ? [
            new TextLayer({
              id: "god-view-edge-labels",
              data: edgeLabelData,
              coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
              getPosition: (d) => d.midpoint,
              getText: (d) => d.connectionLabel,
              getSize: 10,
              sizeUnits: "pixels",
              sizeMinPixels: 8,
              getColor: this.state.visual.edgeLabel,
              fontFamily: "Inter, system-ui, sans-serif",
              fontWeight: 600,
              billboard: true,
              pickable: false,
            }),
          ]
        : []),
    ]
  },
}
