import {COORDINATE_SYSTEM} from "@deck.gl/core"
import {ArcLayer, LineLayer, ScatterplotLayer, TextLayer} from "@deck.gl/layers"

import PacketFlowLayer from "../deckgl/PacketFlowLayer"

export const godViewRenderingGraphCoreMethods = {
  renderGraph(graph) {
    this.ensureDeck()
    this.autoFitViewState(graph)
    const effective = this.reshapeGraph(graph)

    const states = Uint8Array.from(effective.nodes.map((node) => node.state))
    const stateMask = this.visibilityMask(states)
    const traversalMask = effective.shape === "local" ? this.computeTraversalMask(effective) : null
    const mask = new Uint8Array(effective.nodes.length)

    for (let i = 0; i < effective.nodes.length; i += 1) {
      const stateVisible = stateMask[i] === 1
      const traversalVisible = !traversalMask || traversalMask[i] === 1
      mask[i] = stateVisible && traversalVisible ? 1 : 0
    }

    const visibleNodes = effective.nodes.map((node, index) => ({
      ...node,
      index,
      selected: this.selectedNodeIndex === index,
      visible: mask[index] === 1,
    }))
    const visibleById = new Map(visibleNodes.map((node) => [node.id, node]))

    const edgeData = effective.edges
      .filter((edge) => this.edgeEnabledByTopologyLayer(edge))
      .map((edge, edgeIndex) => {
        const src =
          effective.shape === "local"
            ? visibleNodes[edge.source]
            : visibleById.get(edge.sourceCluster)
        const dst =
          effective.shape === "local"
            ? visibleNodes[edge.target]
            : visibleById.get(edge.targetCluster)
        if (!src || !dst || !src.visible || !dst.visible) return null
        const label =
          effective.shape === "local"
            ? String(edge.label || `${src.label || src.id || "node"} -> ${dst.label || dst.id || "node"}`)
            : `${this.formatPps(edge.flowPps || 0)} / ${this.formatCapacity(edge.capacityBps || 0)}`
        const connectionLabel = this.connectionKindFromLabel(label)
        const sourceId = effective.shape === "local" ? src.id : src.id || edge.sourceCluster || "src"
        const targetId = effective.shape === "local" ? dst.id : dst.id || edge.targetCluster || "dst"
        const rawEdgeId = edge.id || edge.edge_id || edge.label || edge.type || `${sourceId}:${targetId}:${edgeIndex}`
        return {
          sourceId,
          targetId,
          sourcePosition: [src.x, src.y, 0],
          targetPosition: [dst.x, dst.y, 0],
          weight: edge.weight || 1,
          flowPps: Number(edge.flowPps || 0),
          flowBps: Number(edge.flowBps || 0),
          capacityBps: Number(edge.capacityBps || 0),
          midpoint: [(src.x + dst.x) / 2, (src.y + dst.y) / 2, 0],
          label: label.length > 56 ? `${label.slice(0, 56)}...` : label,
          connectionLabel,
          interactionKey: `${effective.shape}:${rawEdgeId}`,
        }
      })
      .filter(Boolean)
    const edgeKeys = new Set(edgeData.map((edge) => edge.interactionKey))
    if (this.hoveredEdgeKey && !edgeKeys.has(this.hoveredEdgeKey)) this.hoveredEdgeKey = null
    if (this.selectedEdgeKey && !edgeKeys.has(this.selectedEdgeKey)) this.selectedEdgeKey = null
    const edgeLabelData = this.selectEdgeLabels(edgeData, effective.shape)

    const nodeData = visibleNodes
      .filter((node) => node.visible)
      .map((node) => ({
        id: node.id,
        position: [node.x, node.y, 0],
        index: node.index,
        state: node.state,
        selected: node.selected,
        clusterCount: node.clusterCount || 1,
        pps: Number(node.pps || 0),
        operUp: Number(node.operUp || 0),
        details: node.details || {},
        label:
          this.normalizeDisplayLabel(node.label, node.id || `node-${node.index + 1}`),
        metricText: this.nodeMetricText(node, effective.shape),
        statusIcon: this.nodeStatusIcon(node.operUp),
        stateReason: this.stateReasonForNode(node, edgeData, visibleNodes),
      }))
    this.lastVisibleNodeCount = nodeData.length
    this.lastVisibleEdgeCount = edgeData.length
    const pulse = (Math.sin(this.animationPhase * 3.5) + 1) / 2
    const pulseRadius = 14 + pulse * 20
    const pulseAlpha = Math.floor(80 + pulse * 130)
    const rootPulseNodes = nodeData.filter((d) => d.state === 0)
    const packetFlowData = this.buildPacketFlowInstances(edgeData)
    const securityEnabled = this.layers.security
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

    const selectedVisibleNode =
      effective.shape !== "local" || this.selectedNodeIndex === null
        ? null
        : nodeData.find((node) => node.index === this.selectedNodeIndex)
    this.renderSelectionDetails(selectedVisibleNode)

    this.deck.setProps({
      layers: [
        ...baseLayers,
        ...mantleLayers,
        ...crustLayers,
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
          getFillColor: (d) => (securityEnabled ? this.nodeColor(d.state) : this.nodeNeutralColor(d.operUp)),
        }),
        ...securityLayers,
        ...atmosphereLayers,
        ...(this.layers.mantle && (effective.shape === "local" || effective.shape === "regional" || effective.shape === "global")
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
                getColor: this.visual.label,
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
        ...(this.layers.mantle && (effective.shape === "local" || effective.shape === "regional")
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
                getColor: this.visual.edgeLabel,
                billboard: true,
                pickable: false,
              }),
            ]
          : []),
      ],
    })
  },
}
