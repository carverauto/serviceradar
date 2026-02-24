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
    const zoomScale = Math.max(0.9, Math.min(4.5, Math.pow(1.28, zoom + 1.5)))
    const particleSizeScale = Math.max(0.95, Math.min(4.2, Math.pow(1.34, zoom + 1.1)))
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
              const edgeAlpha = Math.round(160 * alphaMult(d))
              return [10, 40, 80, Math.max(24, Math.min(255, edgeAlpha))]
            },
            getWidth: (d) => {
              const tube = (this.edgeWidthPixels(d.capacityBps, d.flowPps, d.flowBps) * zoomScale * 1.65) + 6.0
              return Math.min(42, tube + (this.edgeIsFocused(d) ? 2.0 : 0))
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
                getColor: (d) => d.color,
                getSize: (d) => Number(d.size || 0) * particleSizeScale,
                getSpeed: (d) => d.speed,
                getSeed: (d) => d.seed,
                getJitter: (d) => d.jitter,
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
            const laneSpread = laneBucket * Math.max(0.2, (Number(particle.jitter || 0) * 0.04))
            const laneOffset = Number(particle.laneOffset || 0)
            const bob = Math.sin((this.state.animationPhase * 9.0) + (Number(particle.seed || 0) * 23.0)) * 0.35
            const color = particle.color || [56, 189, 248, 120]
            const alphaFade = Math.max(0, Math.sin(t * Math.PI))
            return {
              position: [x + (nx * (laneOffset + laneSpread + bob)), y + (ny * (laneOffset + laneSpread + bob)), 0],
              radius: Math.max(0.9, Number(particle.size || 2.4) * 0.16 * particleSizeScale),
              color: [color[0], color[1], color[2], Math.round(Math.max(18, Number(color[3] || 90) * alphaFade))],
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

    return {
      baseLayers,
      mantleLayers,
      crustLayers,
      atmosphereLayers,
      securityLayers,
    }
  },
}
