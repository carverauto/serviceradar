export const godViewLayoutClusterMethods = {
  resolveZoomTier(zoom) {
    if (zoom < -0.3) return "global"
    if (zoom < 1.1) return "regional"
    return "local"
  },
  setZoomTier(nextTier, forceRender) {
    const {state, deps} = this
    if (!nextTier) return
    if (!forceRender && state.zoomTier === nextTier) return
    state.zoomTier = nextTier
    if (nextTier !== "local") state.selectedNodeIndex = null
    if (state.lastGraph) deps.renderGraph(state.lastGraph)
  },
  reshapeGraph(graph) {
    const {state} = this
    const tier = state.zoomMode === "auto" ? state.zoomTier : state.zoomMode
    if (tier === "local") return {shape: "local", ...graph}
    if (tier === "global") return this.reclusterByState(graph)
    return this.reclusterByGrid(graph)
  },
  reclusterByState(graph) {
    const {deps} = this
    const clusters = new Map()
    const clusterByNode = new Array(graph.nodes.length)

    graph.nodes.forEach((node, index) => {
      const key = `state:${node.state}`
      const existing = clusters.get(key) || {
        id: key,
        sumX: 0,
        sumY: 0,
        count: 0,
        sumPps: 0,
        upCount: 0,
        downCount: 0,
        stateHistogram: {0: 0, 1: 0, 2: 0, 3: 0},
        sampleNode: null,
      }
      existing.sumX += node.x
      existing.sumY += node.y
      existing.count += 1
      existing.sumPps += Number(node.pps || 0)
      if (Number(node.operUp) === 1) existing.upCount += 1
      if (Number(node.operUp) === 2) existing.downCount += 1
      existing.stateHistogram[node.state] = (existing.stateHistogram[node.state] || 0) + 1
      if (!existing.sampleNode && node.details) existing.sampleNode = node
      clusters.set(key, existing)
      clusterByNode[index] = key
    })

    const nodes = Array.from(clusters.values()).map((cluster) => ({
      id: cluster.id,
      x: cluster.sumX / cluster.count,
      y: cluster.sumY / cluster.count,
      state: Number(cluster.id.split(":")[1]),
      clusterCount: cluster.count,
      pps: cluster.sumPps,
      operUp: cluster.upCount > 0 ? 1 : (cluster.downCount > 0 ? 2 : 0),
      label: `${deps.stateDisplayName(Number(cluster.id.split(":")[1]))} Cluster`,
      details: this.clusterDetails(cluster, "global"),
    }))

    const edges = this.clusterEdges(graph.edges, clusterByNode)
    return {shape: "global", nodes, edges}
  },
  reclusterByGrid(graph) {
    const cell = 180
    const clusters = new Map()
    const clusterByNode = new Array(graph.nodes.length)

    graph.nodes.forEach((node, index) => {
      const gx = Math.floor(node.x / cell)
      const gy = Math.floor(node.y / cell)
      const key = `grid:${gx}:${gy}`
      const existing = clusters.get(key) || {
        id: key,
        sumX: 0,
        sumY: 0,
        count: 0,
        sumPps: 0,
        upCount: 0,
        downCount: 0,
        stateHistogram: {0: 0, 1: 0, 2: 0, 3: 0},
        sampleNode: null,
      }
      existing.sumX += node.x
      existing.sumY += node.y
      existing.count += 1
      existing.sumPps += Number(node.pps || 0)
      if (Number(node.operUp) === 1) existing.upCount += 1
      if (Number(node.operUp) === 2) existing.downCount += 1
      existing.stateHistogram[node.state] = (existing.stateHistogram[node.state] || 0) + 1
      if (!existing.sampleNode && node.details) existing.sampleNode = node
      clusters.set(key, existing)
      clusterByNode[index] = key
    })

    const nodes = Array.from(clusters.values()).map((cluster) => {
      const dominantState = [0, 1, 2, 3].sort(
        (a, b) => (cluster.stateHistogram[b] || 0) - (cluster.stateHistogram[a] || 0),
      )[0]
      const keyParts = String(cluster.id).split(":")
      const gridX = keyParts.length >= 3 ? keyParts[1] : "0"
      const gridY = keyParts.length >= 3 ? keyParts[2] : "0"
      return {
        id: cluster.id,
        x: cluster.sumX / cluster.count,
        y: cluster.sumY / cluster.count,
        state: dominantState,
        clusterCount: cluster.count,
        pps: cluster.sumPps,
        operUp: cluster.upCount > 0 ? 1 : (cluster.downCount > 0 ? 2 : 0),
        label: `Regional Cluster ${gridX},${gridY}`,
        details: this.clusterDetails(cluster, "regional"),
      }
    })

    const edges = this.clusterEdges(graph.edges, clusterByNode)
    return {shape: "regional", nodes, edges}
  },
  clusterDetails(cluster, scope) {
    const sample = cluster.sampleNode?.details || {}
    const sampleLabel = cluster.sampleNode?.label || null
    const sampleIp = sample.ip || null
    const sampleType = sample.type || null
    const bucketType = scope === "global" ? "State Cluster" : "Regional Cluster"
    return {
      id: cluster.id,
      ip: sampleIp || "cluster",
      type: sampleType || bucketType,
      model: sample.model || null,
      vendor: sample.vendor || null,
      asn: sample.asn || null,
      geo_city: sample.geo_city || null,
      geo_country: sample.geo_country || null,
      last_seen: sample.last_seen || null,
      cluster_scope: scope,
      cluster_count: cluster.count,
      sample_label: sampleLabel,
    }
  },
  clusterEdges(edges, clusterByNode) {
    const {deps} = this
    const acc = new Map()
    edges.forEach((edge) => {
      const a = clusterByNode[edge.source]
      const b = clusterByNode[edge.target]
      if (!a || !b || a === b) return
      const key = a < b ? `${a}|${b}` : `${b}|${a}`
      const current = acc.get(key) || {
        sourceCluster: a < b ? a : b,
        targetCluster: a < b ? b : a,
        weight: 0,
        flowPps: 0,
        flowPpsAb: 0,
        flowPpsBa: 0,
        flowBps: 0,
        flowBpsAb: 0,
        flowBpsBa: 0,
        capacityBps: 0,
        topologyClassCounts: {backbone: 0, logical: 0, hosted: 0, inferred: 0, observed: 0, endpoints: 0, unknown: 0},
      }
      const topologyClass = deps.edgeTopologyClass(edge)
      const classBucket =
        topologyClass === "backbone" ||
        topologyClass === "logical" ||
        topologyClass === "hosted" ||
        topologyClass === "inferred" ||
        topologyClass === "observed" ||
        topologyClass === "endpoints"
          ? topologyClass
          : "unknown"
      const canonicalForward = a < b
      const edgePpsAb = Number(edge.flowPpsAb || 0)
      const edgePpsBa = Number(edge.flowPpsBa || 0)
      const edgeBpsAb = Number(edge.flowBpsAb || 0)
      const edgeBpsBa = Number(edge.flowBpsBa || 0)
      current.weight += 1
      current.flowPps += Number(edge.flowPps || 0)
      current.flowPpsAb += canonicalForward ? edgePpsAb : edgePpsBa
      current.flowPpsBa += canonicalForward ? edgePpsBa : edgePpsAb
      current.flowBps += Number(edge.flowBps || 0)
      current.flowBpsAb += canonicalForward ? edgeBpsAb : edgeBpsBa
      current.flowBpsBa += canonicalForward ? edgeBpsBa : edgeBpsAb
      current.capacityBps += Number(edge.capacityBps || 0)
      current.topologyClassCounts[classBucket] = Number(current.topologyClassCounts[classBucket] || 0) + 1
      acc.set(key, current)
    })
    return Array.from(acc.values())
  },
}
