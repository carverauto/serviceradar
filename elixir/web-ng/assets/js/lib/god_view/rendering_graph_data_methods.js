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

    const rawEdgeData = effective.edges
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
          edgeCount: Number(edge.weight || 1),
          interactionKey: `${effective.shape}:${rawEdgeId}`,
        }
      })
      .filter(Boolean)

    const edgeData = this.aggregateVisibleEdges(rawEdgeData)
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
  aggregateVisibleEdges(edgeData) {
    if (!Array.isArray(edgeData) || edgeData.length === 0) return []

    const acc = new Map()

    const emptyClassCounts = () => ({
      backbone: 0,
      logical: 0,
      hosted: 0,
      inferred: 0,
      observed: 0,
      endpoints: 0,
      unknown: 0,
    })

    const classBucketForEdge = (edge) => {
      const classCounts = edge?.topologyClassCounts
      if (classCounts && typeof classCounts === "object") {
        const buckets = ["backbone", "logical", "hosted", "inferred", "observed", "endpoints", "unknown"]
        let bestBucket = "unknown"
        let bestCount = 0

        for (const bucket of buckets) {
          const count = Number(classCounts[bucket] || 0)
          if (count > bestCount) {
            bestBucket = bucket
            bestCount = count
          }
        }

        if (bestCount > 0) return bestBucket
      }

      const topologyClass = String(edge?.topologyClass || "").trim().toLowerCase()
      if (topologyClass === "backbone") return "backbone"
      if (topologyClass === "logical") return "logical"
      if (topologyClass === "hosted") return "hosted"
      if (topologyClass === "inferred") return "inferred"
      if (topologyClass === "observed") return "observed"
      if (topologyClass === "endpoint" || topologyClass === "endpoints") return "endpoints"
      return "unknown"
    }

    const canonicalPair = (edge) => {
      const sourceId = String(edge?.sourceId || "")
      const targetId = String(edge?.targetId || "")
      return sourceId.localeCompare(targetId) <= 0
        ? {left: sourceId, right: targetId, forward: true}
        : {left: targetId, right: sourceId, forward: false}
    }

    const edgeSignature = (edge) => {
      const pair = canonicalPair(edge)
      const topologyClass = classBucketForEdge(edge)
      return `${pair.left}|${pair.right}|${topologyClass}`
    }

    for (const edge of edgeData) {
      const pair = canonicalPair(edge)
      const key = `${pair.left}|${pair.right}`
      const classBucket = classBucketForEdge(edge)
      const current = acc.get(key) || {
        sourceId: pair.left,
        targetId: pair.right,
        sourcePosition: pair.forward ? edge.sourcePosition : edge.targetPosition,
        targetPosition: pair.forward ? edge.targetPosition : edge.sourcePosition,
        weight: 0,
        flowPps: 0,
        flowPpsAb: 0,
        flowPpsBa: 0,
        flowBps: 0,
        flowBpsAb: 0,
        flowBpsBa: 0,
        capacityBps: 0,
        midpoint: pair.forward ? edge.midpoint : edge.midpoint,
        label: edge.label,
        connectionLabel: edge.connectionLabel,
        telemetryEligible: false,
        topologyClass: "",
        topologyClassCounts: emptyClassCounts(),
        protocol: String(edge.protocol || ""),
        evidenceClass: String(edge.evidenceClass || ""),
        edgeCount: 0,
        interactionKey: `${edge.interactionKey.split(":")[0]}:pair:${pair.left}:${pair.right}`,
        signatures: new Set(),
        labels: new Set(),
        protocols: new Set(),
        evidenceClasses: new Set(),
      }

      const edgeWeight = Math.max(1, Number(edge.weight || edge.edgeCount || 1))
      const flowPpsAb = Number(edge.flowPpsAb || 0)
      const flowPpsBa = Number(edge.flowPpsBa || 0)
      const flowBpsAb = Number(edge.flowBpsAb || 0)
      const flowBpsBa = Number(edge.flowBpsBa || 0)

      current.weight += edgeWeight
      current.flowPps += Number(edge.flowPps || 0)
      current.flowPpsAb += pair.forward ? flowPpsAb : flowPpsBa
      current.flowPpsBa += pair.forward ? flowPpsBa : flowPpsAb
      current.flowBps += Number(edge.flowBps || 0)
      current.flowBpsAb += pair.forward ? flowBpsAb : flowBpsBa
      current.flowBpsBa += pair.forward ? flowBpsBa : flowBpsAb
      current.capacityBps = Math.max(current.capacityBps, Number(edge.capacityBps || 0))
      current.telemetryEligible = current.telemetryEligible || edge.telemetryEligible !== false
      current.edgeCount += Math.max(1, Number(edge.edgeCount || 1))
      current.topologyClassCounts[classBucket] = Number(current.topologyClassCounts[classBucket] || 0) + 1
      current.signatures.add(edgeSignature(edge))
      if (edge.label) current.labels.add(String(edge.label))
      if (edge.protocol) current.protocols.add(String(edge.protocol))
      if (edge.evidenceClass) current.evidenceClasses.add(String(edge.evidenceClass))
      acc.set(key, current)
    }

    const aggregated = Array.from(acc.values()).map((edge) => {
      const labels = Array.from(edge.labels)
      const protocols = Array.from(edge.protocols).sort()
      const evidenceClasses = Array.from(edge.evidenceClasses).sort()
      const classBuckets = Object.entries(edge.topologyClassCounts || {})
        .filter(([, count]) => Number(count || 0) > 0)
        .sort((left, right) => Number(right[1] || 0) - Number(left[1] || 0))
      const dominantClass = classBuckets.length === 1 ? classBuckets[0][0] : ""
      const {signatures: _signatures, labels: _labels, protocols: _protocols, evidenceClasses: _evidenceClasses, ...plainEdge} = edge

      return {
        ...plainEdge,
        label: labels[0] || edge.label,
        topologyClass: dominantClass,
        protocol: protocols.length === 1 ? protocols[0] : "",
        evidenceClass: evidenceClasses.length === 1 ? evidenceClasses[0] : "",
        labels,
        protocols,
        evidenceClasses,
        edgeCount: Math.max(edge.edgeCount, edge.signatures.size),
      }
    })

    aggregated.sort((left, right) => {
      const leftWeight = Number(left.edgeCount || 0)
      const rightWeight = Number(right.edgeCount || 0)
      return rightWeight - leftWeight || left.sourceId.localeCompare(right.sourceId) || left.targetId.localeCompare(right.targetId)
    })

    return aggregated
  },
}
