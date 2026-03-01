export const godViewLayoutTopologyStateMethods = {
  prepareGraphLayout(graph, revision, topologyStamp) {
    const {state} = this
    if (!graph || !Array.isArray(graph.nodes) || !Array.isArray(graph.edges)) return graph
    const stamp =
      typeof topologyStamp === "string" && topologyStamp.length > 0
        ? topologyStamp
        : this.graphTopologyStamp(graph)

    if (state.lastGraph && stamp === state.lastTopologyStamp) {
      const reused = this.reusePreviousPositions(graph, state.lastGraph)
      reused._layoutMode = state.layoutMode || "auto"
      reused._layoutRevision = revision
      return reused
    }

    if (state.lastGraph && Number.isFinite(revision) && state.layoutRevision === revision) {
      const reused = this.reusePreviousPositions(graph, state.lastGraph)
      reused._layoutMode = state.layoutMode || "auto"
      reused._layoutRevision = revision
      return reused
    }

    if (graph._layoutRevision && graph._layoutRevision === revision) return graph

    const mode = this.shouldUseGeoLayout(graph) ? "geo" : "force"
    const laidOut = mode === "geo" ? this.projectGeoLayout(graph) : this.forceDirectedLayout(graph)
    laidOut._layoutMode = mode
    laidOut._layoutRevision = revision
    state.layoutMode = mode
    state.layoutRevision = revision
    return laidOut
  },
  graphTopologyStamp(graph) {
    if (!graph || !Array.isArray(graph.nodes) || !Array.isArray(graph.edges)) return "0:0"
    let nodeHash = 0
    for (let i = 0; i < graph.nodes.length; i += 1) {
      const id = String(graph.nodes[i]?.id || "")
      for (let j = 0; j < id.length; j += 1) nodeHash = ((nodeHash << 5) - nodeHash + id.charCodeAt(j)) | 0
    }
    let edgeHash = 0
    for (let i = 0; i < graph.edges.length; i += 1) {
      const s = Number(graph.edges[i]?.source || 0)
      const t = Number(graph.edges[i]?.target || 0)
      edgeHash = (((edgeHash << 5) - edgeHash + s * 31 + t * 131) | 0)
    }
    return `${graph.nodes.length}:${graph.edges.length}:${nodeHash}:${edgeHash}`
  },
  sameTopology(previousGraph, nextGraph, stamp, revision) {
    const {state} = this
    if (!previousGraph || !nextGraph) return false
    if (!Number.isFinite(revision) || !Number.isFinite(state.lastRevision)) return false
    return (
      revision === state.lastRevision &&
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
