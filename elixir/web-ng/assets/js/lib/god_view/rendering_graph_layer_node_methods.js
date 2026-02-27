import {COORDINATE_SYSTEM} from "@deck.gl/core"
import {LineLayer, ScatterplotLayer, TextLayer} from "@deck.gl/layers"

export const godViewRenderingGraphLayerNodeMethods = {
  buildNodeAndLabelLayers(effective, nodeData, edgeLabelData) {
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
        data: nodeData,
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        getPosition: (d) => d.position,
        getRadius: (d) => Math.min(8 + ((d.clusterCount || 1) - 1) * 0.45, 26) * 2.5,
        radiusUnits: "pixels",
        filled: true,
        stroked: false,
        pickable: false,
        getFillColor: (d) => {
          const baseColor = this.state.layers.security ? this.nodeColor(d.state) : this.nodeNeutralColor(d.operUp)
          return [baseColor[0], baseColor[1], baseColor[2], 15]
        },
        parameters: {
          blend: true,
          blendFunc: [770, 1, 1, 1],
          depthTest: false,
          depthWrite: false,
        },
      }),
      new ScatterplotLayer({
        id: "god-view-nodes-ring",
        data: nodeData,
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        getPosition: (d) => d.position,
        getRadius: (d) => {
          const baseRadius = Math.min(12 + ((d.clusterCount || 1) - 1) * 0.45, 32)
          const breathe = Math.sin((this.state.animationPhase * 2.0) + d.index) * 2.0
          return baseRadius + breathe
        },
        radiusUnits: "pixels",
        radiusMinPixels: 5,
        stroked: true,
        filled: false,
        lineWidthUnits: "pixels",
        pickable: false,
        getLineWidth: (d) => (d.selected ? 2 : 1),
        getLineColor: (d) => (this.state.layers.security ? this.nodeColor(d.state) : this.nodeNeutralColor(d.operUp)),
        parameters: {
          depthTest: false,
          depthWrite: false,
        },
        updateTriggers: {
          getRadius: this.state.animationPhase,
        },
      }),
      new ScatterplotLayer({
        id: "god-view-nodes",
        data: nodeData,
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        getPosition: (d) => d.position,
        getRadius: (d) => Math.min(4 + ((d.clusterCount || 1) - 1) * 0.2, 14),
        radiusUnits: "pixels",
        radiusMinPixels: 3,
        stroked: false,
        filled: true,
        pickable: true,
        getFillColor: [255, 255, 255, 255],
        parameters: {
          depthTest: false,
          depthWrite: false,
        },
      }),
      ...(this.state.layers.mantle && (effective.shape === "local" || effective.shape === "regional" || effective.shape === "global")
        ? [
            new TextLayer({
              id: "god-view-node-labels",
              data: nodeData,
              coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
              getPosition: (d) => d.position,
              getText: (d) => d.label,
              getSize: effective.shape === "local" ? 12 : 10,
              sizeUnits: "pixels",
              sizeMinPixels: effective.shape === "local" ? 10 : 8,
              getColor: this.state.visual.label,
              fontFamily: "Inter, system-ui, sans-serif",
              fontWeight: 600,
              getPixelOffset: [0, -16],
              billboard: true,
              pickable: true,
            }),
          ]
        : []),
      ...(this.state.layers.mantle && (effective.shape === "local" || effective.shape === "regional")
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
