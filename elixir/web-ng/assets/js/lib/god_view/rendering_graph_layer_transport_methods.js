import {COORDINATE_SYSTEM} from "@deck.gl/core"
import {ArcLayer, LineLayer, PathLayer, ScatterplotLayer} from "@deck.gl/layers"
import PacketFlowLayer, {packetFlowDensity} from "../deckgl/PacketFlowLayer"
import {hasManagedTopologySceneRoutes} from "./rendering_graph_data_methods"
import {managedVisualDensityContract, normalizeManagedVisualDensity} from "./rendering_managed_visual_density"
import {edgeTopologyVisualStyleValue} from "./rendering_style_edge_topology_methods"
import {GOD_VIEW_ALPHA_BLEND, GOD_VIEW_NO_DEPTH} from "./gpu_parameters"

export const PACKET_FLOW_LAYER_ID = "god-view-atmosphere-particles"
const EMPTY_PACKET_FLOW = Object.freeze({length: 0, attributes: {}})
const mtrPathEdgeCache = new WeakMap()
const auxiliarySplits = new WeakMap()

// Routed scenes draw auxiliary (manifold) edges separately. Split once per edge list, so a
// hover or camera refresh that reuses the list does not scan it again.
function lastKnownEdgeColor(edge, color) {
  if (edge?.stale !== true || !(color?.[3] > 0)) return color
  return [148, 163, 184, Math.max(1, Math.round(color[3] * 0.45))]
}

function splitAuxiliaryEdges(edgeData) {
  const cached = auxiliarySplits.get(edgeData)
  if (cached) return cached
  const hasAuxiliaryEdges = edgeData.some((edge) => edge?.auxiliary === true)
  const split = hasAuxiliaryEdges
    ? {
        auxiliaryEdgeData: edgeData.filter((edge) => edge?.auxiliary === true),
        semanticEdgeData: edgeData.filter((edge) => edge?.auxiliary !== true),
      }
    : {auxiliaryEdgeData: [], semanticEdgeData: edgeData}
  auxiliarySplits.set(edgeData, split)
  return split
}

export const godViewRenderingGraphLayerTransportMethods = {
  /** The layer re-issued for the current animation phase, or the same layer if it is static. */
  animateLayer(layer) {
    const phase = this.state.animationPhase
    switch (layer?.id) {
      case PACKET_FLOW_LAYER_ID:
        return layer.props.time === phase ? layer : layer.clone({time: phase})
      case "god-view-security-pulse": {
        const pulse = (phase * 1.5) % 1.0
        return layer.clone({
          getRadius: 10 + (pulse * 40),
          getLineWidth: Math.max(1, 3 - (pulse * 2)),
          getLineColor: [...this.state.visual.pulse.slice(0, 3), Math.floor(255 * (1.0 - pulse))],
        })
      }
      case "god-view-nodes-ring":
        return layer.clone({
          updateTriggers: {...layer.props.updateTriggers, getRadius: [phase, ...(layer.props.updateTriggers?.getRadius || []).slice(1)]},
        })
      case "god-view-geo-grid":
        return layer.clone({updateTriggers: {getColor: phase * 80.0}})
      case "god-view-mtr-paths":
        return layer.clone({updateTriggers: {getSourceColor: [phase], getTargetColor: [phase]}})
      default:
        return layer
    }
  },
  buildTransportAndEffectLayers(effective, nodeData, edgeData, rootPulseNodesArg = null) {
    const now = typeof performance !== "undefined" ? performance.now() : Date.now()
    const atmosphereReady = now >= Number(this.state.atmosphereSuppressUntil || 0)
    const pulse = (this.state.animationPhase * 1.5) % 1.0
    const pulseRadius = 10 + (pulse * 40)
    const pulseAlpha = Math.floor(255 * (1.0 - pulse))
    const zoom = Number(this.state.viewState?.zoom || 0)
    const zoomScale = Math.max(0.4, Math.min(4.5, Math.pow(1.24, zoom + 1.2)))
    const zoomParticleVisibility = Math.max(0.14, Math.min(1.0, (zoom + 2.2) / 3.6))
    const zoomParticleAlphaScale = Math.max(0.35, zoomParticleVisibility)
    const zoomSpreadScale = Math.max(1.0, Math.min(1.35, 1.0 + ((1.0 - zoomParticleVisibility) * 0.35)))
    const zoomDensity = Math.max(0.55, Math.min(1.25, (zoom + 2.5) / 4.5))
    const hasFocus = this.state.hoveredEdgeKey || this.state.selectedEdgeKey
    const alphaMult = (d) => {
      if (!hasFocus) return 1.0
      return this.edgeIsFocused(d) ? 1.8 : 0.15
    }
    const rootPulseNodes = Array.isArray(rootPulseNodesArg)
      ? rootPulseNodesArg
      : nodeData.filter((d) => d.state === 0)
    const packetFlowData = (this.state.layers.atmosphere && this.state.packetFlowEnabled)
      ? this.buildPacketFlowEdges(edgeData)
      : EMPTY_PACKET_FLOW
    const routedTopologyScene = hasManagedTopologySceneRoutes(effective)
    const managedVisualDensity = routedTopologyScene
      ? normalizeManagedVisualDensity(this.state.managedTopologyVisualDensity)
      : null
    const managedRouteMaxWidth = routedTopologyScene
      ? managedVisualDensityContract(managedVisualDensity).routeMaxWidth
      : null
    const {auxiliaryEdgeData, semanticEdgeData} = routedTopologyScene
      ? splitAuxiliaryEdges(edgeData)
      : {auxiliaryEdgeData: [], semanticEdgeData: edgeData}
    const transportDataSets = auxiliaryEdgeData.length > 0
      ? [
          {suffix: "-auxiliary", data: auxiliaryEdgeData, pickable: false},
          {suffix: "", data: semanticEdgeData, pickable: true},
        ]
      : [{suffix: "", data: semanticEdgeData, pickable: true}]

    const mantleLayers = this.state.layers.mantle
      ? transportDataSets.map((dataSet) => (
          new (routedTopologyScene ? PathLayer : LineLayer)({
            id: `god-view-edges-mantle${dataSet.suffix}`,
            data: dataSet.data,
            coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
            ...(routedTopologyScene
              ? {getPath: (d) => d.path, jointRounded: true}
              : {
                  getSourcePosition: (d) => d.sourcePosition,
                  getTargetPosition: (d) => d.targetPosition,
                }),
            getColor: (d) => {
              const base = this.state.visual.mantleEdgeBase
              const alphaBase = this.state.visual.mantleEdgeAlphaBase ?? 128
              const alphaBoost = this.state.visual.mantleEdgeAlphaBoost ?? 32
              const style = edgeTopologyVisualStyleValue(d)
              const edgeAlpha =
                Math.round((alphaBase + (alphaBoost * zoomParticleVisibility)) * alphaMult(d) * style.mantleAlphaScale)
              return lastKnownEdgeColor(d, [base[0], base[1], base[2], Math.max(style.mantleAlphaFloor, Math.min(255, edgeAlpha))])
            },
            getWidth: (d) => {
              const style = edgeTopologyVisualStyleValue(d)
              const tube = (this.edgeWidthPixels(d.capacityBps, d.flowPps, d.flowBps) * zoomScale * 1.35 * style.mantleWidthScale) + 2.0
              return Math.min(managedRouteMaxWidth ?? 38, tube + (this.edgeIsFocused(d) ? 2.0 : 0))
            },
            getPolygonOffset: (d) => (this.edgeIsFocused(d) ? [0, -1000] : [0, 0]),
            widthUnits: "pixels",
            widthMinPixels: 6,
            pickable: dataSet.pickable,
            parameters: GOD_VIEW_ALPHA_BLEND,
            updateTriggers: {
              getColor: [hasFocus, this.state.hoveredEdgeKey, this.state.selectedEdgeKey, this.state.visual.mantleEdgeBase, this.state.visual.mantleEdgeAlphaBase],
              getWidth: [zoomScale, hasFocus, this.state.hoveredEdgeKey, this.state.selectedEdgeKey, managedVisualDensity],
              getPolygonOffset: [hasFocus, this.state.hoveredEdgeKey, this.state.selectedEdgeKey],
            },
          })
        ))
      : []

    const crustLayers =
      this.state.layers.crust
        ? transportDataSets.map((dataSet) => (
            new (routedTopologyScene ? PathLayer : ArcLayer)({
              id: `god-view-edges-crust${dataSet.suffix}`,
              data: dataSet.data,
              coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
              ...(routedTopologyScene
                ? {
                    getPath: (d) => d.path,
                    jointRounded: true,
                    getColor: (d) => {
                      const color = typeof this.edgeTelemetryColor === "function"
                        ? this.edgeTelemetryColor(d.flowBps, d.capacityBps, d.flowPps, true)
                        : this.edgeTelemetryArcColors(d.flowBps, d.capacityBps, d.flowPps).source
                      const style = edgeTopologyVisualStyleValue(d)
                      const edgeAlpha = Math.min(255, color[3] * alphaMult(d) * style.crustAlphaScale)
                      return lastKnownEdgeColor(d, [color[0], color[1], color[2], Math.max(style.crustAlphaFloor, edgeAlpha)])
                    },
                  }
                : {
                    getSourcePosition: (d) => d.sourcePosition,
                    getTargetPosition: (d) => d.targetPosition,
                    getSourceColor: (d) => {
                      const source = this.edgeTelemetryArcColors(d.flowBps, d.capacityBps, d.flowPps).source
                      const style = edgeTopologyVisualStyleValue(d)
                      const edgeAlpha = Math.min(255, source[3] * alphaMult(d) * style.crustAlphaScale)
                      return lastKnownEdgeColor(d, [source[0], source[1], source[2], Math.max(style.crustAlphaFloor, edgeAlpha)])
                    },
                    getTargetColor: (d) => {
                      const target = this.edgeTelemetryArcColors(d.flowBps, d.capacityBps, d.flowPps).target
                      const style = edgeTopologyVisualStyleValue(d)
                      const edgeAlpha = Math.min(255, target[3] * alphaMult(d) * style.crustAlphaScale)
                      return lastKnownEdgeColor(d, [target[0], target[1], target[2], Math.max(style.crustAlphaFloor, edgeAlpha)])
                    },
                  }),
              getWidth: (d) => {
                const style = edgeTopologyVisualStyleValue(d)
                const base = Math.max(
                  3.0,
                  Math.min((this.edgeWidthPixels(d.capacityBps, d.flowPps, d.flowBps) * 0.98 * zoomScale * style.crustWidthScale) + 0.6, 11.5),
                )
                const maximum = managedRouteMaxWidth ?? 12.0
                return this.edgeIsFocused(d) ? Math.min(maximum, base + 2.0) : Math.min(maximum, base)
              },
              getPolygonOffset: (d) => (this.edgeIsFocused(d) ? [0, -1000] : [0, 0]),
              widthUnits: "pixels",
              ...(routedTopologyScene ? {} : {greatCircle: false}),
              pickable: dataSet.pickable,
              parameters: GOD_VIEW_ALPHA_BLEND,
              updateTriggers: {
                ...(routedTopologyScene
                  ? {getColor: [hasFocus, this.state.hoveredEdgeKey, this.state.selectedEdgeKey]}
                  : {
                      getSourceColor: [hasFocus, this.state.hoveredEdgeKey, this.state.selectedEdgeKey],
                      getTargetColor: [hasFocus, this.state.hoveredEdgeKey, this.state.selectedEdgeKey],
                    }),
                getWidth: [zoomScale, hasFocus, this.state.hoveredEdgeKey, this.state.selectedEdgeKey, managedVisualDensity],
                getPolygonOffset: [hasFocus, this.state.hoveredEdgeKey, this.state.selectedEdgeKey],
              },
            })
          ))
        : []

    const atmosphereLayers = this.state.layers.atmosphere && atmosphereReady && packetFlowData.length > 0
      ? [
          new PacketFlowLayer({
            id: PACKET_FLOW_LAYER_ID,
            data: packetFlowData,
            coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
            pickable: false,
            time: this.state.animationPhase,
            zoomDensity: packetFlowDensity(zoomDensity, packetFlowData.particleBaseSum),
            spreadScale: zoomSpreadScale,
            alphaScale: zoomParticleAlphaScale,
            cyan: this.state.visual.particleCyan,
            magenta: this.state.visual.particleMagenta,
            parameters: this.state.visual.particleBlend,
          }),
        ]
      : []

    const securityLayers = this.state.layers.security
      ? [
          new ScatterplotLayer({
            id: "god-view-security-pulse",
            data: rootPulseNodes,
            coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
            getPosition: (d) => d.position,
            getRadius: pulseRadius,
            radiusUnits: "pixels",
            radiusMinPixels: 8,
            filled: false,
            stroked: true,
            lineWidthUnits: "pixels",
            getLineWidth: Math.max(1, 3 - (pulse * 2)),
            getLineColor: [
              this.state.visual.pulse[0],
              this.state.visual.pulse[1],
              this.state.visual.pulse[2],
              pulseAlpha,
            ],
            pickable: false,
            parameters: GOD_VIEW_NO_DEPTH,
          }),
        ]
      : []

    const baseGeoLines = this.deps.geoGridData()
    const sweepTime = this.state.animationPhase * 80.0
    const baseLayers = baseGeoLines.length > 0
      ? [
          new LineLayer({
            id: "god-view-geo-grid",
            data: baseGeoLines,
            coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
            getSourcePosition: (d) => d.sourcePosition,
            getTargetPosition: (d) => d.targetPosition,
            getColor: (d) => {
              const g = this.state.visual.geoGrid
              const dx = Number(d.sourcePosition?.[0] || 0) - 320
              const dy = Number(d.sourcePosition?.[1] || 0) - 160
              const dist = Math.sqrt((dx * dx) + (dy * dy))
              const wave = (sweepTime - dist) % 400.0
              const alpha = wave > 0 && wave < 60 ? 110 - (wave * 1.5) : 15
              return [g[0], g[1], g[2], Math.max(12, alpha)]
            },
            getWidth: 1,
            widthUnits: "pixels",
            pickable: false,
            parameters: GOD_VIEW_NO_DEPTH,
            updateTriggers: {
              getColor: sweepTime,
            },
          }),
        ]
      : []

    const topologyLayers = this.state.topologyLayers || {}

    const mtrPathEdgeData = topologyLayers.mtr_paths
      ? this.buildMtrPathEdgeData(nodeData)
      : []

    const mtrPathLayers = topologyLayers.mtr_paths && mtrPathEdgeData.length > 0
      ? [
          new ArcLayer({
            id: "god-view-mtr-paths",
            data: mtrPathEdgeData,
            coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
            getSourcePosition: (d) => d.sourcePosition,
            getTargetPosition: (d) => d.targetPosition,
            getSourceColor: (d) => this.mtrLatencyColor(d.avgUs, 0.9),
            getTargetColor: (d) => this.mtrLatencyColor(d.avgUs, 0.6),
            getWidth: (d) => this.mtrLossWidth(d.lossPct),
            getHeight: 0.6,
            widthUnits: "pixels",
            greatCircle: false,
            pickable: true,
            parameters: GOD_VIEW_ALPHA_BLEND,
            updateTriggers: {
              getSourceColor: [this.state.animationPhase],
              getTargetColor: [this.state.animationPhase],
            },
          }),
        ]
      : []

    return {
      baseLayers,
      mantleLayers,
      crustLayers,
      atmosphereLayers,
      securityLayers,
      mtrPathLayers,
    }
  },

  buildMtrPathEdgeData(nodeData) {
    const paths = this.state.mtrPathData
    if (!paths || paths.length === 0) return []
    // Same nodes and paths as the last layer pass (a hover, a selection, a camera move): reuse.
    const cached = mtrPathEdgeCache.get(nodeData)
    if (cached && cached.paths === paths && cached.owner === this) return cached.value
    const value = this.buildMtrPathEdgeDataUncached(nodeData, paths)
    if (nodeData && typeof nodeData === "object") mtrPathEdgeCache.set(nodeData, {owner: this, paths, value})
    return value
  },
  buildMtrPathEdgeDataUncached(nodeData, paths) {

    const nodeById = new Map()
    for (const node of nodeData) {
      if (node.id) nodeById.set(node.id, node)
    }

    return paths
      .map((path) => {
        const src = nodeById.get(path.source)
        const dst = nodeById.get(path.target)
        if (!src || !dst) return null
        if (!Array.isArray(src.position) || src.position.length < 2) return null
        if (!Array.isArray(dst.position) || dst.position.length < 2) return null

        const avgUs = Number(path.avg_us)
        const lossPct = Number(path.loss_pct)
        const jitterUs = Number(path.jitter_us)
        const fromHop = Number(path.from_hop)
        const toHop = Number(path.to_hop)

        return {
          sourcePosition: [src.position[0], src.position[1], 0],
          targetPosition: [dst.position[0], dst.position[1], 0],
          avgUs: Number.isFinite(avgUs) ? avgUs : 0,
          lossPct: Number.isFinite(lossPct) ? lossPct : 0,
          jitterUs: Number.isFinite(jitterUs) ? jitterUs : 0,
          fromHop: Number.isFinite(fromHop) ? fromHop : 0,
          toHop: Number.isFinite(toHop) ? toHop : 0,
          agentId: String(path.agent_id || ""),
          sourceAddr: String(path.source_addr || ""),
          targetAddr: String(path.target_addr || ""),
          sourceId: path.source,
          targetId: path.target,
          interactionKey: [
            "mtr",
            String(path.source ?? ""),
            String(path.target ?? ""),
            String(path.agent_id ?? ""),
            String(Number.isFinite(fromHop) ? fromHop : ""),
            String(Number.isFinite(toHop) ? toHop : ""),
          ]
            .map((segment) => encodeURIComponent(segment))
            .join(":"),
        }
      })
      .filter(Boolean)
  },

  mtrLatencyColor(avgUs, alphaScale) {
    const ms = avgUs / 1000
    const pulse = (Math.sin(this.state.animationPhase * Math.PI * 2) + 1) * 0.5
    const alphaBoost = 0.85 + (pulse * 0.15)
    const rawScale = Number(alphaScale ?? 1.0)
    const scale = Number.isFinite(rawScale) ? Math.max(0, Math.min(1, rawScale)) : 1.0
    const alpha = Math.max(0, Math.min(255, Math.round(200 * scale * alphaBoost)))

    if (ms <= 5) return [76, 175, 80, alpha]
    if (ms <= 20) {
      const t = (ms - 5) / 15
      return [
        Math.round(76 + (179 * t)),
        Math.round(175 - (32 * t)),
        Math.round(80 - (73 * t)),
        alpha,
      ]
    }
    if (ms <= 100) {
      const t = Math.min(1, (ms - 20) / 80)
      return [
        Math.round(255 - (11 * t)),
        Math.round(143 - (76 * t)),
        Math.round(7 + (47 * t)),
        alpha,
      ]
    }
    return [244, 67, 54, alpha]
  },

  mtrLossWidth(lossPct) {
    const raw = Number(lossPct)
    const loss = Number.isFinite(raw) ? Math.max(0, Math.min(100, raw)) : 0
    return 2.5 + (loss / 100) * 9.5
  },

  formatMtrLatency(avgUs) {
    const ms = avgUs / 1000
    if (ms < 1) return `${Math.round(avgUs)}us`
    if (ms < 100) return `${ms.toFixed(1)}ms`
    return `${Math.round(ms)}ms`
  },
}
