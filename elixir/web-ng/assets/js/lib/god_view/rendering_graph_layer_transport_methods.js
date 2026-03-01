import {COORDINATE_SYSTEM} from "@deck.gl/core"
import {ArcLayer, LineLayer, ScatterplotLayer} from "@deck.gl/layers"
import PacketFlowLayer from "../deckgl/PacketFlowLayer"

export const godViewRenderingGraphLayerTransportMethods = {
  buildTransportAndEffectLayers(effective, nodeData, edgeData, rootPulseNodesArg = null) {
    const now = typeof performance !== "undefined" ? performance.now() : Date.now()
    const atmosphereReady = now >= Number(this.state.atmosphereSuppressUntil || 0)
    const pulse = (this.state.animationPhase * 1.5) % 1.0
    const pulseRadius = 10 + (pulse * 40)
    const pulseAlpha = Math.floor(255 * (1.0 - pulse))
    const zoom = Number(this.state.viewState?.zoom || 0)
    const zoomScale = Math.max(0.4, Math.min(4.5, Math.pow(1.24, zoom + 1.2)))
    const particleRenderScale = 1.0
    const zoomParticleVisibility = Math.max(0.14, Math.min(1.0, (zoom + 2.2) / 3.6))
    const zoomParticleAlphaScale = Math.max(0.35, zoomParticleVisibility)
    const minParticleSizePx = 1.0
    const zoomSpreadScale = Math.max(1.0, Math.min(1.35, 1.0 + ((1.0 - zoomParticleVisibility) * 0.35)))
    const hasFocus = this.state.hoveredEdgeKey || this.state.selectedEdgeKey
    const alphaMult = (d) => {
      if (!hasFocus) return 1.0
      return this.edgeIsFocused(d) ? 1.8 : 0.15
    }
    const rootPulseNodes = Array.isArray(rootPulseNodesArg)
      ? rootPulseNodesArg
      : nodeData.filter((d) => d.state === 0)
    const packetFlowData = (this.state.layers.atmosphere && this.state.packetFlowEnabled)
      ? this.buildPacketFlowInstances(edgeData)
      : []

    const mantleLayers = this.state.layers.mantle
      ? [
          new LineLayer({
            id: "god-view-edges-mantle",
            data: edgeData,
            coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
            getSourcePosition: (d) => d.sourcePosition,
            getTargetPosition: (d) => d.targetPosition,
            getColor: (d) => {
              const edgeAlpha = Math.round((128 + (32 * zoomParticleVisibility)) * alphaMult(d))
              return [10, 40, 80, Math.max(24, Math.min(255, edgeAlpha))]
            },
            getWidth: (d) => {
              const tube = (this.edgeWidthPixels(d.capacityBps, d.flowPps, d.flowBps) * zoomScale * 1.35) + 2.0
              return Math.min(38, tube + (this.edgeIsFocused(d) ? 2.0 : 0))
            },
            getPolygonOffset: (d) => (this.edgeIsFocused(d) ? [0, -1000] : [0, 0]),
            widthUnits: "pixels",
            widthMinPixels: 6,
            pickable: true,
            parameters: {
              blend: true,
              blendFunc: [770, 771],
              depthTest: false,
            },
            updateTriggers: {
              getColor: [hasFocus, this.state.hoveredEdgeKey, this.state.selectedEdgeKey],
              getWidth: [zoomScale, hasFocus, this.state.hoveredEdgeKey, this.state.selectedEdgeKey],
              getPolygonOffset: [hasFocus, this.state.hoveredEdgeKey, this.state.selectedEdgeKey],
            },
          }),
        ]
      : []

    const crustLayers =
      this.state.layers.crust
        ? [
            new ArcLayer({
              id: "god-view-edges-crust",
              data: edgeData,
              coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
              getSourcePosition: (d) => d.sourcePosition,
              getTargetPosition: (d) => d.targetPosition,
              getSourceColor: (d) => {
                const source = this.edgeTelemetryArcColors(d.flowBps, d.capacityBps, d.flowPps).source
                return [source[0], source[1], source[2], Math.min(255, source[3] * alphaMult(d))]
              },
              getTargetColor: (d) => {
                const target = this.edgeTelemetryArcColors(d.flowBps, d.capacityBps, d.flowPps).target
                return [target[0], target[1], target[2], Math.min(255, target[3] * alphaMult(d))]
              },
              getWidth: (d) => {
                const base = Math.max(3.4, Math.min((this.edgeWidthPixels(d.capacityBps, d.flowPps, d.flowBps) * 0.98 * zoomScale) + 0.6, 11.5))
                return this.edgeIsFocused(d) ? Math.min(12.0, base + 2.0) : base
              },
              getPolygonOffset: (d) => (this.edgeIsFocused(d) ? [0, -1000] : [0, 0]),
              widthUnits: "pixels",
              greatCircle: false,
              pickable: true,
              parameters: {
                blend: true,
                blendFunc: [770, 771],
                depthTest: false,
                depthWrite: false,
              },
              updateTriggers: {
                getSourceColor: [hasFocus, this.state.hoveredEdgeKey, this.state.selectedEdgeKey],
                getTargetColor: [hasFocus, this.state.hoveredEdgeKey, this.state.selectedEdgeKey],
                getWidth: [zoomScale, hasFocus, this.state.hoveredEdgeKey, this.state.selectedEdgeKey],
                getPolygonOffset: [hasFocus, this.state.hoveredEdgeKey, this.state.selectedEdgeKey],
              },
            }),
          ]
        : []

    const atmosphereLayers = this.state.layers.atmosphere && packetFlowData.length > 0
      ? (() => {
          if (atmosphereReady && this.state.packetFlowShaderEnabled === true) {
            return [
              new PacketFlowLayer({
                id: "god-view-atmosphere-particles",
                data: packetFlowData,
                coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
                getSourcePosition: (d) => d.sourcePosition,
                getTargetPosition: (d) => d.targetPosition,
                getFrom: (d) => d.from,
                getTo: (d) => d.to,
                getColor: (d) => {
                  const color = d.color || [56, 189, 248, 120]
                  return [color[0], color[1], color[2], Math.round((color[3] || 0) * zoomParticleAlphaScale)]
                },
                getSize: (d) => Math.max(minParticleSizePx, Number(d.size || 0) * particleRenderScale),
                getSpeed: (d) => d.speed,
                getSeed: (d) => d.seed,
                getJitter: (d) => Number(d.jitter || 0) * zoomSpreadScale,
                getLaneOffset: (d) => d.laneOffset,
                pickable: false,
                time: this.state.animationPhase,
                parameters: {
                  blend: true,
                  blendFunc: [770, 1, 1, 1],
                  depthTest: false,
                  depthWrite: false,
                },
              }),
            ]
          }

          const fallbackParticleData = packetFlowData.map((particle) => {
            const from = particle.from || [0, 0]
            const to = particle.to || [0, 0]
            const dx = Number(to[0] || 0) - Number(from[0] || 0)
            const dy = Number(to[1] || 0) - Number(from[1] || 0)
            const len = Math.max(0.0001, Math.sqrt((dx * dx) + (dy * dy)))
            const t = (Number(particle.seed || 0) + (this.state.animationPhase * Number(particle.speed || 0))) % 1
            const x = Number(from[0] || 0) + (dx * t)
            const y = Number(from[1] || 0) + (dy * t)
            const nx = -dy / len
            const ny = dx / len
            const laneBucket = ((Math.floor(Number(particle.seed || 0) * 1009) % 5) - 2)
            const laneSpread = laneBucket * Math.max(0.2, (Number(particle.jitter || 0) * 0.04 * zoomSpreadScale))
            const laneOffset = Number(particle.laneOffset || 0)
            const bob = Math.sin((this.state.animationPhase * 9.0) + (Number(particle.seed || 0) * 23.0)) * 0.35
            const color = particle.color || [56, 189, 248, 120]
            const alphaFade = Math.max(0, Math.sin(t * Math.PI))
            return {
              position: [x + (nx * (laneOffset + laneSpread + bob)), y + (ny * (laneOffset + laneSpread + bob)), 0],
              radius: Math.max(1.0, Number(particle.size || 2.4) * 0.16 * particleRenderScale),
              color: [color[0], color[1], color[2], Math.round(Math.max(6, Number(color[3] || 90) * alphaFade * zoomParticleAlphaScale))],
            }
          })

          return [
            new ScatterplotLayer({
              id: "god-view-atmosphere-particles-fallback",
              data: fallbackParticleData,
              coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
              getPosition: (d) => d.position,
              getRadius: (d) => d.radius,
              radiusUnits: "pixels",
              radiusMinPixels: 1,
              filled: true,
              stroked: false,
              pickable: false,
              getFillColor: (d) => d.color,
              parameters: {
                blend: true,
                blendFunc: [770, 1, 1, 1],
                depthTest: false,
                depthWrite: false,
              },
              updateTriggers: {
                getPosition: this.state.animationPhase,
                getFillColor: this.state.animationPhase,
              },
            }),
          ]
        })()
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
            parameters: {
              depthTest: false,
              depthWrite: false,
            },
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
              const dx = Number(d.sourcePosition?.[0] || 0) - 320
              const dy = Number(d.sourcePosition?.[1] || 0) - 160
              const dist = Math.sqrt((dx * dx) + (dy * dy))
              const wave = (sweepTime - dist) % 400.0
              const alpha = wave > 0 && wave < 60 ? 110 - (wave * 1.5) : 15
              return [32, 62, 88, Math.max(12, alpha)]
            },
            getWidth: 1,
            widthUnits: "pixels",
            pickable: false,
            parameters: {
              depthTest: false,
              depthWrite: false,
            },
            updateTriggers: {
              getColor: sweepTime,
            },
          }),
        ]
      : []

    const mtrPathEdgeData = this.state.topologyLayers.mtr_paths
      ? this.buildMtrPathEdgeData(nodeData)
      : []

    const mtrPathLayers = this.state.topologyLayers.mtr_paths && mtrPathEdgeData.length > 0
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
            parameters: {
              blend: true,
              blendFunc: [770, 771],
              depthTest: false,
              depthWrite: false,
            },
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

    const nodeById = new Map()
    for (const node of nodeData) {
      if (node.id) nodeById.set(node.id, node)
    }

    return paths
      .map((path, idx) => {
        const src = nodeById.get(path.source)
        const dst = nodeById.get(path.target)
        if (!src || !dst) return null
        return {
          sourcePosition: [src.position[0], src.position[1], 0],
          targetPosition: [dst.position[0], dst.position[1], 0],
          avgUs: Number(path.avg_us || 0),
          lossPct: Number(path.loss_pct || 0),
          jitterUs: Number(path.jitter_us || 0),
          fromHop: Number(path.from_hop || 0),
          toHop: Number(path.to_hop || 0),
          agentId: String(path.agent_id || ""),
          sourceAddr: String(path.source_addr || ""),
          targetAddr: String(path.target_addr || ""),
          sourceId: path.source,
          targetId: path.target,
          interactionKey: `mtr:${path.source}:${path.target}:${idx}`,
        }
      })
      .filter(Boolean)
  },

  mtrLatencyColor(avgUs, alphaScale) {
    const ms = avgUs / 1000
    const pulse = (Math.sin(this.state.animationPhase * Math.PI * 2) + 1) * 0.5
    const alphaBoost = 0.85 + (pulse * 0.15)
    const alpha = Math.round(200 * (alphaScale || 1.0) * alphaBoost)

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
    const loss = Math.max(0, Math.min(100, Number(lossPct || 0)))
    return 2.5 + (loss / 100) * 9.5
  },

  formatMtrLatency(avgUs) {
    const ms = avgUs / 1000
    if (ms < 1) return `${Math.round(avgUs)}us`
    if (ms < 100) return `${ms.toFixed(1)}ms`
    return `${Math.round(ms)}ms`
  },
}
