import * as d3 from "d3"

export const godViewLayoutTopologyMethods = {
  prepareGraphLayout(graph, revision, topologyStamp) {
    if (!graph || !Array.isArray(graph.nodes) || !Array.isArray(graph.edges)) return graph
    const stamp =
      typeof topologyStamp === "string" && topologyStamp.length > 0
        ? topologyStamp
        : this.graphTopologyStamp(graph)

    if (this.lastGraph && stamp === this.lastTopologyStamp) {
      const reused = this.reusePreviousPositions(graph, this.lastGraph)
      reused._layoutMode = this.layoutMode || "auto"
      reused._layoutRevision = revision
      return reused
    }

    if (this.lastGraph && Number.isFinite(revision) && this.layoutRevision === revision) {
      const reused = this.reusePreviousPositions(graph, this.lastGraph)
      reused._layoutMode = this.layoutMode || "auto"
      reused._layoutRevision = revision
      return reused
    }

    if (graph._layoutRevision && graph._layoutRevision === revision) return graph

    const mode = this.shouldUseGeoLayout(graph) ? "geo" : "force"
    const laidOut = mode === "geo" ? this.projectGeoLayout(graph) : this.forceDirectedLayout(graph)
    laidOut._layoutMode = mode
    laidOut._layoutRevision = revision
    this.layoutMode = mode
    this.layoutRevision = revision
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
    if (!previousGraph || !nextGraph) return false
    if (!Number.isFinite(revision) || !Number.isFinite(this.lastRevision)) return false
    return (
      revision === this.lastRevision &&
      stamp === this.lastTopologyStamp &&
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
  projectGeoLayout(graph) {
    const width = 640
    const height = 320
    const pad = 20
    const nodes = graph.nodes.map((node) => ({...node}))
    let fallbackIdx = 0
    for (const node of nodes) {
      const lat = Number(node?.geoLat)
      const lon = Number(node?.geoLon)
      if (Number.isFinite(lat) && Number.isFinite(lon)) {
        const clampedLat = Math.max(-85, Math.min(85, lat))
        const x = ((lon + 180) / 360) * (width - pad * 2) + pad
        const rad = clampedLat * (Math.PI / 180)
        const mercY = (1 - Math.log(Math.tan(Math.PI / 4 + rad / 2)) / Math.PI) / 2
        const y = mercY * (height - pad * 2) + pad
        node.x = x
        node.y = y
      } else {
        const angle = fallbackIdx * 0.72
        const ring = 22 + (fallbackIdx % 14) * 7
        node.x = width / 2 + Math.cos(angle) * ring
        node.y = height / 2 + Math.sin(angle) * ring
        fallbackIdx += 1
      }
    }
    return {...graph, nodes}
  },
  forceDirectedLayout(graph) {
    const width = 640
    const height = 320
    const pad = 20
    const nodes = graph.nodes.map((node) => ({...node}))
    if (nodes.length <= 2) return {...graph, nodes}

    const links = graph.edges
      .filter((edge) => Number.isInteger(edge?.source) && Number.isInteger(edge?.target))
      .map((edge) => ({source: edge.source, target: edge.target, weight: Number(edge.weight || 1)}))

    const simulation = d3.forceSimulation(nodes)
      .alphaMin(0.02)
      .force("charge", d3.forceManyBody().strength(nodes.length > 500 ? -20 : -45))
      .force("link", d3.forceLink(links).id((_d, i) => i).distance((l) => {
        const w = Number(l?.weight || 1)
        return Math.max(22, Math.min(90, 52 - Math.log2(Math.max(1, w)) * 8))
      }).strength(0.34))
      .force("collide", d3.forceCollide().radius(7).strength(0.8))
      .force("center", d3.forceCenter(width / 2, height / 2))
      .stop()

    const iterations = Math.min(220, Math.max(70, Math.round(30 + nodes.length * 0.32)))
    for (let i = 0; i < iterations; i += 1) simulation.tick()

    const xs = nodes.map((n) => Number(n.x || 0))
    const ys = nodes.map((n) => Number(n.y || 0))
    const minX = Math.min(...xs)
    const maxX = Math.max(...xs)
    const minY = Math.min(...ys)
    const maxY = Math.max(...ys)
    const dx = Math.max(1, maxX - minX)
    const dy = Math.max(1, maxY - minY)
    for (const n of nodes) {
      n.x = pad + ((Number(n.x || 0) - minX) / dx) * (width - pad * 2)
      n.y = pad + ((Number(n.y || 0) - minY) / dy) * (height - pad * 2)
    }

    return {...graph, nodes}
  },
  geoGridData() {
    if (this.layoutMode !== "geo") return []
    const width = 640
    const height = 320
    const pad = 20
    const project = (lat, lon) => {
      const clampedLat = Math.max(-85, Math.min(85, lat))
      const x = ((lon + 180) / 360) * (width - pad * 2) + pad
      const rad = clampedLat * (Math.PI / 180)
      const mercY = (1 - Math.log(Math.tan(Math.PI / 4 + rad / 2)) / Math.PI) / 2
      const y = mercY * (height - pad * 2) + pad
      return [x, y, -2]
    }

    const lines = []
    for (let lon = -150; lon <= 150; lon += 30) {
      for (let lat = -80; lat < 80; lat += 10) {
        lines.push({sourcePosition: project(lat, lon), targetPosition: project(lat + 10, lon)})
      }
    }
    for (let lat = -60; lat <= 60; lat += 20) {
      for (let lon = -180; lon < 180; lon += 15) {
        lines.push({sourcePosition: project(lat, lon), targetPosition: project(lat, lon + 15)})
      }
    }
    return lines
  },
}
