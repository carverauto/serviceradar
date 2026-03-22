export const godViewRenderingGraphDataMethods = {
  buildVisibleGraphData(effective) {
    const states = Uint8Array.from(effective.nodes.map((node) => node.state))
    const stateMask = this.visibilityMask(states)
    const traversalMask = effective.shape === "local" ? this.computeTraversalMask(effective) : null
    const mask = new Uint8Array(effective.nodes.length)
    const topologyLayers = this.state.topologyLayers || {}
    const endpointIncidentFlags =
      effective.shape === "local"
        ? effective.nodes.map(() => ({endpoint: false, nonEndpoint: false}))
        : null

    const edgeTopologyClass = (edge) => {
      if (typeof this.edgeTopologyClass === "function") {
        return this.edgeTopologyClass(edge)
      }

      const normalized = String(edge?.topologyClass || "").trim().toLowerCase()
      if (normalized === "endpoint") return "endpoints"
      return normalized || "unknown"
    }

    if (endpointIncidentFlags) {
      for (const edge of effective.edges) {
        const topologyClass = edgeTopologyClass(edge)
        const endpointOnly = topologyClass === "endpoints"
        const source = Number(edge?.source)
        const target = Number(edge?.target)

        for (const index of [source, target]) {
          if (!Number.isInteger(index) || index < 0 || index >= endpointIncidentFlags.length) continue

          if (endpointOnly) {
            endpointIncidentFlags[index].endpoint = true
          } else {
            endpointIncidentFlags[index].nonEndpoint = true
          }
        }
      }
    }

    for (let i = 0; i < effective.nodes.length; i += 1) {
      const stateVisible = stateMask[i] === 1
      const traversalVisible = !traversalMask || traversalMask[i] === 1
      const endpointLayerVisible =
        !endpointIncidentFlags ||
        topologyLayers.endpoints !== false ||
        endpointIncidentFlags[i].nonEndpoint ||
        !endpointIncidentFlags[i].endpoint

      mask[i] = stateVisible && traversalVisible && endpointLayerVisible ? 1 : 0
    }

    const visibleNodes = effective.nodes.map((node, index) => ({
      ...node,
      index,
      selected: this.state.selectedNodeIndex === index,
      visible: mask[index] === 1,
      zHeight: 0,
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
        const telemetryEligible = edge.telemetryEligible === false || edge.telemetry_eligible === false
          ? false
          : true
        const topologyClass = edgeTopologyClass(edge)
        return {
          sourceId,
          targetId,
          sourcePosition: [src.x, src.y, 0],
          targetPosition: [dst.x, dst.y, 0],
          weight: edge.weight || 1,
          flowPps: Number(edge.flowPps || 0),
          flowPpsAb: Number(edge.flowPpsAb || 0),
          flowPpsBa: Number(edge.flowPpsBa || 0),
          flowBps: Number(edge.flowBps || 0),
          flowBpsAb: Number(edge.flowBpsAb || 0),
          flowBpsBa: Number(edge.flowBpsBa || 0),
          capacityBps: Number(edge.capacityBps || 0),
          midpoint: [(src.x + dst.x) / 2, (src.y + dst.y) / 2, 0],
          label: label.length > 56 ? `${label.slice(0, 56)}...` : label,
          connectionLabel,
          telemetryEligible,
          topologyClass,
          topologyClassCounts: edge.topologyClassCounts || null,
          protocol: String(edge.protocol || ""),
          evidenceClass: String(edge.evidenceClass || ""),
          interactionKey: `${effective.shape}:${rawEdgeId}`,
        }
      })
      .filter(Boolean)
    const edgeKeys = new Set(edgeData.map((edge) => edge.interactionKey))
    if (this.state.hoveredEdgeKey && !edgeKeys.has(this.state.hoveredEdgeKey)) this.state.hoveredEdgeKey = null
    if (this.state.selectedEdgeKey && !edgeKeys.has(this.state.selectedEdgeKey)) this.state.selectedEdgeKey = null
    const edgeLabelData = this.selectEdgeLabels(edgeData, effective.shape)

    const nodeData = visibleNodes
      .filter((node) => node.visible)
      .map((node) => ({
        id: node.id,
        position: [node.x, node.y, 0],
        zHeight: 0,
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
    const rootPulseNodes = nodeData.filter((node) => node.state === 0)

    this.state.lastVisibleNodeCount = nodeData.length
    this.state.lastVisibleEdgeCount = edgeData.length

    const selectedVisibleNode =
      effective.shape !== "local" || this.state.selectedNodeIndex === null
        ? null
        : nodeData.find((node) => node.index === this.state.selectedNodeIndex)

    return {edgeData, edgeLabelData, nodeData, rootPulseNodes, selectedVisibleNode}
  },
}
