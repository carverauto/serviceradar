import {COORDINATE_SYSTEM} from "@deck.gl/core"
import {LineLayer, ScatterplotLayer, TextLayer} from "@deck.gl/layers"

export const godViewRenderingGraphLayerNodeMethods = {
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
      && node?.details?.cluster_expanded === true
  },
  backboneLabelCandidate(node) {
    return !this.endpointSummaryLabel(node) && !this.expandedEndpointMemberLabel(node)
  },
  nodeLabelPriority(node) {
    const details = node?.details || {}
    const clusterKind = String(details?.cluster_kind || "")
    const identitySource = String(details?.identity_source || "")
    const clusterCount = Number(node?.clusterCount || 1)
    const pps = Number(node?.pps || 0)
    const state = Number(node?.state ?? 3)

    return [
      node?.selected === true ? 1 : 0,
      this.backboneLabelCandidate(node) ? 1 : 0,
      clusterKind === "endpoint-anchor" ? 1 : 0,
      identitySource !== "mapper_topology_sighting" ? 1 : 0,
      clusterCount,
      state === 0 ? 1 : 0,
      state === 1 ? 1 : 0,
      Math.round(pps),
      String(node?.label || node?.id || ""),
    ]
  },
  compareNodeLabelPriority(left, right) {
    const leftPriority = this.nodeLabelPriority(left)
    const rightPriority = this.nodeLabelPriority(right)

    for (let index = 0; index < leftPriority.length; index += 1) {
      if (index === leftPriority.length - 1) {
        const compare = String(leftPriority[index]).localeCompare(String(rightPriority[index]))
        if (compare !== 0) return compare
        continue
      }

      const compare = Number(rightPriority[index] || 0) - Number(leftPriority[index] || 0)
      if (compare !== 0) return compare
    }

    return 0
  },
  selectNodeLabels(nodeData, shape) {
    if (!Array.isArray(nodeData) || nodeData.length === 0) return []
    const selected = nodeData.filter((node) => node?.selected === true)
    const candidates = nodeData.filter((node) => {
      if (node?.selected === true) return true
      const details = node?.details || {}
      const clusterKind = String(details?.cluster_kind || "")
      const expandedEndpointMember = this.expandedEndpointMemberLabel(node)
      if (clusterKind === "endpoint-member" && !expandedEndpointMember) return false
      if (String(details?.identity_source || "") === "mapper_topology_sighting" && !expandedEndpointMember) return false
      if (this.opaqueIdentityLabel(node)) return false
      return true
    })
    const budget = this.labelBudgetForShape(shape, candidates.length)
    const endpointSummaryBudget = this.endpointSummaryLabelBudgetForShape(shape)
    if (budget <= 0) return []

    const ordered = [...candidates].sort((left, right) => this.compareNodeLabelPriority(left, right))
    const orderedBackbone = ordered.filter((node) => this.backboneLabelCandidate(node))
    const orderedExpandedEndpointMembers = ordered.filter((node) => this.expandedEndpointMemberLabel(node))
    const orderedEndpointSummaries = ordered.filter((node) => this.endpointSummaryLabel(node))
    const picked = []
    const seen = new Set()
    let endpointSummaryCount = 0

    for (const node of [...selected, ...orderedBackbone, ...orderedExpandedEndpointMembers, ...orderedEndpointSummaries]) {
      const id = String(node?.id || "")
      if (id === "" || seen.has(id)) continue
      if (this.endpointSummaryLabel(node) && node?.selected !== true) {
        if (endpointSummaryCount >= endpointSummaryBudget) continue
        endpointSummaryCount += 1
      }
      seen.add(id)
      picked.push(node)
      if (picked.length >= budget) break
    }

    return picked
  },
  buildNodeAndLabelLayers(effective, nodeData, edgeLabelData) {
    const labelData = this.selectNodeLabels(nodeData, effective.shape)

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
          blendFunc: this.state.visual.particleBlend,
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
        getFillColor: this.state.visual.nodeFill,
        parameters: {
          depthTest: false,
          depthWrite: false,
        },
      }),
      ...(this.state.layers.mantle && (effective.shape === "local" || effective.shape === "regional" || effective.shape === "global")
        ? [
            new TextLayer({
              id: "god-view-node-labels",
              data: labelData,
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
