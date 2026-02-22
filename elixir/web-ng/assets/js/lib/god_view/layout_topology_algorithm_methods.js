import * as d3 from "d3"

const LAYOUT_WIDTH = 640
const LAYOUT_HEIGHT = 320
const LAYOUT_PAD = 20

function projectMercator(lat, lon) {
  const clampedLat = Math.max(-85, Math.min(85, lat))
  const x = ((lon + 180) / 360) * (LAYOUT_WIDTH - LAYOUT_PAD * 2) + LAYOUT_PAD
  const rad = clampedLat * (Math.PI / 180)
  const mercY = (1 - Math.log(Math.tan(Math.PI / 4 + rad / 2)) / Math.PI) / 2
  const y = mercY * (LAYOUT_HEIGHT - LAYOUT_PAD * 2) + LAYOUT_PAD
  return [x, y]
}

export const godViewLayoutTopologyAlgorithmMethods = {
  projectGeoLayout(graph) {
    const nodes = graph.nodes.map((node) => ({...node}))
    let fallbackIdx = 0
    for (const node of nodes) {
      const lat = Number(node?.geoLat)
      const lon = Number(node?.geoLon)
      if (Number.isFinite(lat) && Number.isFinite(lon)) {
        const [x, y] = projectMercator(lat, lon)
        node.x = x
        node.y = y
      } else {
        const angle = fallbackIdx * 0.72
        const ring = 22 + (fallbackIdx % 14) * 7
        node.x = LAYOUT_WIDTH / 2 + Math.cos(angle) * ring
        node.y = LAYOUT_HEIGHT / 2 + Math.sin(angle) * ring
        fallbackIdx += 1
      }
    }
    return {...graph, nodes}
  },
  forceDirectedLayout(graph) {
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
      .force("center", d3.forceCenter(LAYOUT_WIDTH / 2, LAYOUT_HEIGHT / 2))
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
      n.x = LAYOUT_PAD + ((Number(n.x || 0) - minX) / dx) * (LAYOUT_WIDTH - LAYOUT_PAD * 2)
      n.y = LAYOUT_PAD + ((Number(n.y || 0) - minY) / dy) * (LAYOUT_HEIGHT - LAYOUT_PAD * 2)
    }

    return {...graph, nodes}
  },
  geoGridData() {
    if (this.layoutMode !== "geo") return []
    const lines = []
    for (let lon = -150; lon <= 150; lon += 30) {
      for (let lat = -80; lat < 80; lat += 10) {
        const [sx, sy] = projectMercator(lat, lon)
        const [tx, ty] = projectMercator(lat + 10, lon)
        lines.push({sourcePosition: [sx, sy, -2], targetPosition: [tx, ty, -2]})
      }
    }
    for (let lat = -60; lat <= 60; lat += 20) {
      for (let lon = -180; lon < 180; lon += 15) {
        const [sx, sy] = projectMercator(lat, lon)
        const [tx, ty] = projectMercator(lat, lon + 15)
        lines.push({sourcePosition: [sx, sy, -2], targetPosition: [tx, ty, -2]})
      }
    }
    return lines
  },
}
