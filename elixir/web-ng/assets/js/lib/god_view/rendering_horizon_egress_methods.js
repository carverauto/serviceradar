import {COORDINATE_SYSTEM} from "@deck.gl/core"
import {LineLayer, ScatterplotLayer, TextLayer} from "@deck.gl/layers"
import {GOD_VIEW_ALPHA_BLEND, GOD_VIEW_NO_DEPTH} from "./gpu_parameters"
import {
  buildHorizonEgressGraphLayout,
  horizonEdgeColor,
  horizonSeverityColor,
  normalizeHorizonEgressData,
  selectVisibleHorizonLabels,
} from "./horizon_egress_shared"

const EMPTY_RENDER_DATA = Object.freeze({
  nodes: [],
  edges: [],
  pulseNodes: [],
  deviceLookup: new Map(),
})

const horizonEgressRenderCache = new WeakMap()

export const godViewRenderingHorizonEgressMethods = {
  horizonEgressLayerId(layerId) {
    return typeof layerId === "string" && layerId.startsWith("god-view-horizon-egress-")
  },
  toggleHorizonEgressCluster(clusterKey) {
    if (typeof clusterKey !== "string" || !clusterKey) return false
    if (!(this.state.expandedHorizonClusters instanceof Set)) {
      this.state.expandedHorizonClusters = new Set()
    }
    if (this.state.expandedHorizonClusters.has(clusterKey)) {
      this.state.expandedHorizonClusters.delete(clusterKey)
    } else {
      this.state.expandedHorizonClusters.add(clusterKey)
    }
    this.state.expandedHorizonClustersRevision = (this.state.expandedHorizonClustersRevision || 0) + 1
    return this.state.expandedHorizonClusters.has(clusterKey)
  },
  horizonEgressZoomTier() {
    const raw = this.state.zoomMode === "auto" ? this.state.zoomTier : this.state.zoomMode
    return raw === "global" || raw === "regional" || raw === "local" ? raw : "local"
  },
  buildHorizonEgressRenderData(nodeData) {
    const enabled = this.state.topologyLayers?.horizon_egress === true
    const rawData = this.state.horizonEgressData
    if (!enabled || !rawData || !Array.isArray(nodeData) || nodeData.length === 0) {
      return EMPTY_RENDER_DATA
    }

    const zoomTier = this.horizonEgressZoomTier()
    const clusterRev = this.state.expandedHorizonClustersRevision || 0
    const cached = horizonEgressRenderCache.get(nodeData)
    if (
      cached &&
      cached.owner === this &&
      cached.rawData === rawData &&
      cached.zoomTier === zoomTier &&
      cached.clusterRev === clusterRev
    ) {
      return cached.value
    }

    const value = buildHorizonEgressGraphLayout(rawData, nodeData, {
      mode: "cartesian",
      zoomTier,
      zoom: Number(this.state.viewState?.zoom ?? 0),
      expandedClusters: this.state.expandedHorizonClusters,
      maxNodesPerTier: 6,
    })
    horizonEgressRenderCache.set(nodeData, {owner: this, rawData, zoomTier, clusterRev, value})
    return value
  },
  horizonEgressForDevice(node) {
    if (this.state.topologyLayers?.horizon_egress !== true || !this.state.horizonEgressData || !node) {
      return null
    }
    const candidateIds = [node.id, node.details?.device_uid, node.details?.id]
      .filter((val) => typeof val === "string" && val.trim() !== "")
      .map((val) => val.trim())
    if (candidateIds.length === 0) return null

    const nodeData = this.state.lastGraphLayerFrame?.nodeData
    if (Array.isArray(nodeData) && nodeData.length > 0) {
      const lookup = this.buildHorizonEgressRenderData(nodeData).deviceLookup
      for (const id of candidateIds) {
        if (lookup.has(id)) return lookup.get(id)
      }
    }

    const data = normalizeHorizonEgressData(this.state.horizonEgressData)
    const device = data.egress_devices.find((entry) => candidateIds.includes(String(entry?.id || "").trim()))
    if (!device) return null

    const devId = String(device.id).trim()
    const extById = new Map(data.external_nodes.map((ext) => [String(ext?.id || "").trim(), ext]))
    const edges = data.edges.filter(
      (edge) => String(edge?.src_id || "").trim() === devId || String(edge?.dst_id || "").trim() === devId,
    )
    const connectedNodes = edges
      .map((edge) => {
        const otherId = String(edge.src_id).trim() === devId ? String(edge.dst_id).trim() : String(edge.src_id).trim()
        return extById.get(otherId) || null
      })
      .filter(Boolean)

    return {device, edges, connectedNodes}
  },
  buildHorizonEgressLayers(nodeData) {
    if (this.state.topologyLayers?.horizon_egress !== true) return []
    const renderData = this.buildHorizonEgressRenderData(nodeData)
    if (renderData.nodes.length === 0 && renderData.edges.length === 0) return []

    const selectedKey = this.state.selectedHorizonEntity?.interactionKey || null
    const hoveredKey = this.state.hoveredHorizonKey || null
    const visual = this.state.visual
    const phase = Number(this.state.animationPhase || 0)
    const pulse = (phase * 1.5) % 1.0
    const pulseRadius = 12 + (pulse * 36)
    const pulseAlpha = Math.floor(240 * (1.0 - pulse))
    const pulseColor = visual?.pulse || [255, 42, 122]

    const layers = []

    if (renderData.edges.length > 0) {
      layers.push(
        new LineLayer({
          id: "god-view-horizon-egress-edges",
          data: renderData.edges,
          coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
          getSourcePosition: (d) => d.sourcePosition,
          getTargetPosition: (d) => d.targetPosition,
          getColor: (d) =>
            horizonEdgeColor(
              d,
              visual,
              d.interactionKey === selectedKey || d.interactionKey === hoveredKey,
            ),
          getWidth: (d) => {
            const base = String(d?.egress_source || "").toLowerCase() === "manual" ? 3.5 : 2.2
            return d.interactionKey === selectedKey || d.interactionKey === hoveredKey ? base + 1.8 : base
          },
          widthUnits: "pixels",
          pickable: true,
          parameters: GOD_VIEW_ALPHA_BLEND,
          updateTriggers: {
            getColor: [selectedKey, hoveredKey, visual],
            getWidth: [selectedKey, hoveredKey],
          },
        }),
      )
    }

    if (renderData.pulseNodes.length > 0) {
      layers.push(
        new ScatterplotLayer({
          id: "god-view-horizon-egress-pulse",
          data: renderData.pulseNodes,
          coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
          getPosition: (d) => d.position,
          getRadius: pulseRadius,
          radiusUnits: "pixels",
          filled: false,
          stroked: true,
          lineWidthUnits: "pixels",
          getLineWidth: Math.max(1, 3 - (pulse * 2)),
          getLineColor: [pulseColor[0], pulseColor[1], pulseColor[2], pulseAlpha],
          pickable: false,
          parameters: GOD_VIEW_NO_DEPTH,
        }),
      )
    }

    if (renderData.nodes.length > 0) {
      const zoomTier = this.horizonEgressZoomTier()
      const visibleLabels = selectVisibleHorizonLabels(renderData.nodes, {
        mode: "cartesian",
        zoomTier,
        zoom: Number(this.state.viewState?.zoom ?? 0),
        selectedKey,
        hoveredKey,
      })
      layers.push(
        new ScatterplotLayer({
          id: "god-view-horizon-egress-nodes-halo",
          data: renderData.nodes,
          coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
          getPosition: (d) => d.position,
          getRadius: (d) => (d.isCluster ? 28 : d.interactionKey === selectedKey ? 24 : 20),
          radiusUnits: "pixels",
          filled: true,
          stroked: false,
          pickable: true,
          getFillColor: (d) =>
            horizonSeverityColor(d.severity, visual, d.interactionKey === selectedKey ? 65 : 35),
          parameters: GOD_VIEW_ALPHA_BLEND,
          updateTriggers: {
            getRadius: [selectedKey],
            getFillColor: [selectedKey, visual],
          },
        }),
        new ScatterplotLayer({
          id: "god-view-horizon-egress-nodes-ring",
          data: renderData.nodes,
          coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
          getPosition: (d) => d.position,
          getRadius: (d) => (d.isCluster ? 16 : 11),
          radiusUnits: "pixels",
          filled: false,
          stroked: true,
          lineWidthUnits: "pixels",
          pickable: false,
          getLineWidth: (d) =>
            d.interactionKey === selectedKey || d.interactionKey === hoveredKey ? 2.5 : 1.5,
          getLineColor: (d) => horizonSeverityColor(d.severity, visual, 240),
          parameters: GOD_VIEW_NO_DEPTH,
          updateTriggers: {
            getLineWidth: [selectedKey, hoveredKey],
            getLineColor: [visual],
          },
        }),
        new ScatterplotLayer({
          id: "god-view-horizon-egress-nodes",
          data: renderData.nodes,
          coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
          getPosition: (d) => d.position,
          getRadius: (d) => (d.isCluster ? 11 : 6),
          radiusUnits: "pixels",
          filled: true,
          stroked: false,
          pickable: true,
          getFillColor: (d) => horizonSeverityColor(d.severity, visual, 245),
          parameters: GOD_VIEW_NO_DEPTH,
          updateTriggers: {
            getFillColor: [visual],
          },
        }),
        new TextLayer({
          id: "god-view-horizon-egress-labels",
          data: visibleLabels,
          coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
          getPosition: (d) => d.position,
          getText: (d) => d.labelText,
          getSize: (d) => (d.isCluster ? 12 : 11),
          sizeUnits: "pixels",
          sizeMinPixels: 9,
          getColor: visual?.label || [237, 245, 241, 240],
          fontFamily: "Inter, system-ui, sans-serif",
          fontWeight: 600,
          getPixelOffset: (d) => [0, d.isCluster ? -18 : -14],
          getTextAnchor: "middle",
          getAlignmentBaseline: "bottom",
          billboard: true,
          pickable: true,
          characterSet: "auto",
          updateTriggers: {
            data: [renderData.nodes, selectedKey, hoveredKey],
          },
        }),
      )
    }

    return layers
  },
}
