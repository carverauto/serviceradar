import {COORDINATE_SYSTEM} from "@deck.gl/core"
import {ArcLayer, LineLayer, ScatterplotLayer} from "@deck.gl/layers"

import PacketFlowLayer from "../deckgl/PacketFlowLayer"

export const godViewRenderingGraphLayerTransportMethods = {
  buildTransportAndEffectLayers(effective, nodeData, edgeData) {
    const pulse = (Math.sin(this.animationPhase * 3.5) + 1) / 2
    const pulseRadius = 14 + pulse * 20
    const pulseAlpha = Math.floor(80 + pulse * 130)
    const rootPulseNodes = nodeData.filter((d) => d.state === 0)
    const packetFlowData = this.buildPacketFlowInstances(edgeData)

    const mantleLayers = this.layers.mantle
      ? [
          new LineLayer({
            id: "god-view-edges-mantle",
            data: edgeData,
            coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
            getSourcePosition: (d) => d.sourcePosition,
            getTargetPosition: (d) => d.targetPosition,
            getColor: (d) => this.edgeTelemetryColor(d.flowBps, d.capacityBps, d.flowPps, false),
            getWidth: (d) => this.edgeWidthPixels(d.capacityBps, d.flowPps, d.flowBps) + (this.edgeIsFocused(d) ? 1.25 : 0),
            widthUnits: "pixels",
            widthMinPixels: 1,
            pickable: true,
            parameters: {
              blend: true,
              blendFunc: [770, 1, 1, 1],
              depthTest: false,
            },
          }),
        ]
      : []

    const crustLayers =
      this.layers.crust
        ? [
            new ArcLayer({
              id: "god-view-edges-crust",
              data: edgeData,
              coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
              getSourcePosition: (d) => [d.sourcePosition[0], d.sourcePosition[1], 8],
              getTargetPosition: (d) => [d.targetPosition[0], d.targetPosition[1], 8],
              getSourceColor: (d) => this.edgeTelemetryArcColors(d.flowBps, d.capacityBps, d.flowPps).source,
              getTargetColor: (d) => this.edgeTelemetryArcColors(d.flowBps, d.capacityBps, d.flowPps).target,
              getWidth: (d) => {
                const base = Math.max(1.1, Math.min(this.edgeWidthPixels(d.capacityBps, d.flowPps, d.flowBps) * 0.85, 4.8))
                return this.edgeIsFocused(d) ? Math.min(5.8, base + 0.9) : base
              },
              widthUnits: "pixels",
              greatCircle: false,
              getTilt: effective.shape === "local" ? 16 : 24,
              pickable: true,
              parameters: {
                blend: true,
                blendFunc: [770, 1, 1, 1],
              },
            }),
          ]
        : []

    const atmosphereLayers = this.layers.atmosphere
      ? [
          new PacketFlowLayer({
            id: "god-view-atmosphere-particles",
            data: packetFlowData,
            coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
            pickable: false,
            time: this.animationPhase,
            parameters: {
              blend: true,
              blendFunc: [770, 1, 1, 1],
              depthTest: false,
            },
          }),
        ]
      : []

    const securityLayers = this.layers.security
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
            getLineWidth: 2,
            getLineColor: [
              this.visual.pulse[0],
              this.visual.pulse[1],
              this.visual.pulse[2],
              pulseAlpha,
            ],
            pickable: false,
          }),
        ]
      : []

    const baseGeoLines = this.geoGridData()
    const baseLayers = baseGeoLines.length > 0
      ? [
          new LineLayer({
            id: "god-view-geo-grid",
            data: baseGeoLines,
            coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
            getSourcePosition: (d) => d.sourcePosition,
            getTargetPosition: (d) => d.targetPosition,
            getColor: [32, 62, 88, 65],
            getWidth: 1,
            widthUnits: "pixels",
            pickable: false,
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
