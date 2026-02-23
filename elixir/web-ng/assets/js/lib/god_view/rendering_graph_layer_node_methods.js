import {COORDINATE_SYSTEM} from "@deck.gl/core"
import {ScatterplotLayer, TextLayer} from "@deck.gl/layers"

export const godViewRenderingGraphLayerNodeMethods = {
  buildNodeAndLabelLayers(effective, nodeData, edgeLabelData) {
    return [
      new ScatterplotLayer({
        id: "god-view-nodes",
        data: nodeData,
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        getPosition: (d) => d.position,
        getRadius: (d) => Math.min(8 + ((d.clusterCount || 1) - 1) * 0.45, 26),
        radiusUnits: "pixels",
        radiusMinPixels: 4,
        stroked: true,
        filled: true,
        lineWidthUnits: "pixels",
        pickable: true,
        getLineWidth: (d) => (d.selected ? 3 : 1),
        getLineColor: [15, 23, 42, 255],
        getFillColor: (d) => (this.state.layers.security ? this.nodeColor(d.state) : this.nodeNeutralColor(d.operUp)),
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
              getPixelOffset: [0, -16],
              billboard: true,
              pickable: false,
            }),
            new TextLayer({
              id: "god-view-node-metrics",
              data: nodeData,
              coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
              getPosition: (d) => d.position,
              getText: (d) => d.metricText,
              getSize: effective.shape === "local" ? 10 : 9,
              sizeUnits: "pixels",
              sizeMinPixels: 8,
              getColor: [148, 163, 184, 220],
              getPixelOffset: [0, -3],
              billboard: true,
              pickable: false,
            }),
            new TextLayer({
              id: "god-view-node-status-icon",
              data: nodeData,
              coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
              getPosition: (d) => d.position,
              getText: (d) => d.statusIcon,
              getSize: effective.shape === "local" ? 12 : 11,
              sizeUnits: "pixels",
              sizeMinPixels: 9,
              getColor: (d) => this.nodeStatusColor(d.operUp),
              getPixelOffset: [-18, -16],
              billboard: true,
              pickable: false,
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
              billboard: true,
              pickable: false,
            }),
          ]
        : []),
    ]
  },
}
