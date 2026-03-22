export const godViewLayoutTopologyStateMethods = {
  prepareGraphLayout(graph, revision, _topologyStamp) {
    const {state} = this
    if (!graph || !Array.isArray(graph.nodes) || !Array.isArray(graph.edges)) return graph

    if (graph._layoutRevision && graph._layoutRevision === revision) return graph

    const mode = "server"
    const laidOut = {...graph}
    laidOut._layoutMode = mode
    laidOut._layoutRevision = revision
    state.layoutMode = mode
    state.layoutRevision = revision
    return laidOut
  },
  graphTopologyStamp(graph) {
    if (!graph || !Array.isArray(graph.nodes) || !Array.isArray(graph.edges)) return "0:0"
    const nodeIds = graph.nodes.map((node) => String(node?.id || "")).sort()
    let nodeHash = 0
    for (let i = 0; i < nodeIds.length; i += 1) {
      const id = nodeIds[i]
      for (let j = 0; j < id.length; j += 1) nodeHash = ((nodeHash << 5) - nodeHash + id.charCodeAt(j)) | 0
    }

    const edgeKeys = graph.edges
      .map((edge) => {
        const sourceIndex = Number(edge?.source || 0)
        const targetIndex = Number(edge?.target || 0)
        const sourceId = String(graph.nodes[sourceIndex]?.id || edge?.sourceCluster || sourceIndex)
        const targetId = String(graph.nodes[targetIndex]?.id || edge?.targetCluster || targetIndex)
        return sourceId <= targetId ? `${sourceId}::${targetId}` : `${targetId}::${sourceId}`
      })
      .sort()

    let edgeHash = 0
    for (let i = 0; i < edgeKeys.length; i += 1) {
      const key = edgeKeys[i]
      for (let j = 0; j < key.length; j += 1) edgeHash = ((edgeHash << 5) - edgeHash + key.charCodeAt(j)) | 0
    }
    return `${graph.nodes.length}:${graph.edges.length}:${nodeHash}:${edgeHash}`
  },
  sameTopology(previousGraph, nextGraph, stamp, revision) {
    const {state} = this
    if (!previousGraph || !nextGraph) return false
    if (Number.isFinite(revision) && Number.isFinite(state.lastRevision) && revision === state.lastRevision) {
      return (
        previousGraph.nodes.length === nextGraph.nodes.length &&
        previousGraph.edges.length === nextGraph.edges.length
      )
    }
    return (
      stamp === state.lastTopologyStamp &&
      previousGraph.nodes.length === nextGraph.nodes.length &&
      previousGraph.edges.length === nextGraph.edges.length
    )
  },
  reusePreviousPositions(nextGraph, previousGraph) {
    if (!nextGraph || !previousGraph) return nextGraph
    const byId = new Map((previousGraph.nodes || []).map((n) => [n.id, n]))
    const nodes = (nextGraph.nodes || []).map((n) => {
      const prev = byId.get(n.id)
      if (!prev) return n
      return {...n, x: Number(prev.x || n.x || 0), y: Number(prev.y || n.y || 0)}
    })
    return {...nextGraph, nodes}
  },
  shouldUseProvidedLayout(graph) {
    const nodes = graph?.nodes || []
    if (nodes.length === 0) return false

    let finiteCount = 0
    let nonOriginCount = 0
    let minX = Infinity
    let maxX = -Infinity
    let minY = Infinity
    let maxY = -Infinity

    for (const node of nodes) {
      const x = Number(node?.x)
      const y = Number(node?.y)
      if (!Number.isFinite(x) || !Number.isFinite(y)) continue
      finiteCount += 1
      if (Math.abs(x) > 0 || Math.abs(y) > 0) nonOriginCount += 1
      minX = Math.min(minX, x)
      maxX = Math.max(maxX, x)
      minY = Math.min(minY, y)
      maxY = Math.max(maxY, y)
    }

    if (finiteCount / Math.max(1, nodes.length) < 0.9) return false
    if (nonOriginCount < Math.min(nodes.length, 2)) return false
    return maxX - minX > 1 || maxY - minY > 1
  },
  shouldUseGeoLayout(graph) {
    const nodes = graph?.nodes || []
    if (nodes.length < 6) return false
    let geoCount = 0
    for (const node of nodes) {
      if (Number.isFinite(node?.geoLat) && Number.isFinite(node?.geoLon)) geoCount += 1
    }
    return geoCount / Math.max(1, nodes.length) >= 0.25
  },
}
