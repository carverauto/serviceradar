import {COORDINATE_SYSTEM} from "@deck.gl/core"
import {TileLayer, _Tileset2D as Tileset2D} from "@deck.gl/geo-layers"
import {LineLayer, ScatterplotLayer, TextLayer} from "@deck.gl/layers"
import PacketFlowLayer from "../deckgl/PacketFlowLayer"
import {GOD_VIEW_ALPHA_BLEND, GOD_VIEW_ADDITIVE_BLEND} from "./gpu_parameters"
import {nodeGlyphLayerData} from "./rendering_node_frame"
import {godViewRenderingStyleEdgeParticleMethods} from "./rendering_style_edge_particle_methods"
import {edgeTopologyClassValue, edgeTopologyVisualStyleValue} from "./rendering_style_edge_topology_methods"
import {WORLD_TILE_SIZE} from "./world_tile_decode"

// Coarsen the complete viewport instead of dropping tiles when a large display
// would exceed the watch/geometry budget. TileLayer keeps parent/child coverage.
class BoundedWorldTileset extends Tileset2D {
  reloadAll() {
    // deck.gl's reloadAll drops unselected cache entries without rebuilding
    // its render list. A visible fallback parent can then survive refinement
    // forever. Retain bounded cached tiles and invalidate their content in
    // place so refinement still owns visibility, including while loading.
    for (const tile of this.tiles) tile.setNeedsReload()
  }

  getTileIndices(options) {
    let maxZoom = options.maxZoom
    let indices = super.getTileIndices(options)
    while (indices.length > 64 && maxZoom > 0) {
      maxZoom = Math.min(maxZoom - 1, indices[0].z - 1)
      indices = super.getTileIndices({...options, maxZoom})
    }
    return indices
  }
}

const geometryFrames = new WeakMap()
const flowFrames = new WeakMap()

function geometryFrame(geometry) {
  let frame = geometryFrames.get(geometry.positions)
  if (frame) return frame
  const position = index => [geometry.positions[index * 2], geometry.positions[index * 2 + 1], 0]
  const nodes = geometry.nodes.filter(node => node.kind !== "boundary").map(node => ({...node, position: position(node.index)}))
  const sources = new Float64Array(geometry.edges.length * 2)
  const targets = new Float64Array(sources.length)
  for (const edge of geometry.edges) {
    sources.set(position(edge.source).slice(0, 2), edge.index * 2)
    targets.set(position(edge.target).slice(0, 2), edge.index * 2)
  }
  frame = {
    nodes,
    glyphs: nodeGlyphLayerData(nodes),
    lines: {length: geometry.edges.length, attributes: {
      getSourcePosition: {value: sources, size: 2},
      getTargetPosition: {value: targets, size: 2},
    }, resolve: index => ({...geometry.edges[index], kind: "bundle"})},
  }
  geometryFrames.set(geometry.positions, frame)
  return frame
}

function edgeSeed(id) {
  let hash = 2166136261
  for (let i = 0; i < id.length; i += 1) hash = Math.imul(hash ^ id.charCodeAt(i), 16777619)
  // Exactly representable by the Float32 seed attribute, stable across tiles.
  return (hash >>> 0) % 1_000_000
}

function measured(direction, field) {
  const rate = direction?.[field]
  return direction?.animate === true && Number.isFinite(rate) && rate > 0 ? rate : 0
}

function packetRate(direction) {
  return measured(direction, "observed_packets_per_second") || measured(direction, "packets_per_second")
}

function flowFrame(geometry, overlay) {
  let frames = flowFrames.get(geometry.positions)
  if (!frames) {
    frames = new WeakMap()
    flowFrames.set(geometry.positions, frames)
  }
  if (frames.has(overlay)) return frames.get(overlay)
  const byId = new Map((overlay.flow?.edges || []).map(edge => [edge.id, edge]))
  const edges = geometry.edges.flatMap(edge => {
    const flow = byId.get(edge.id)
    if (!flow || flow.total_relations !== edge.count || flow.selected_relations !== edge.count) return []
    const ab = packetRate(flow.forward)
    const ba = packetRate(flow.reverse)
    const bpsAb = (measured(flow.forward, "observed_octets_per_second") || measured(flow.forward, "octets_per_second")) * 8
    const bpsBa = (measured(flow.reverse, "observed_octets_per_second") || measured(flow.reverse, "octets_per_second")) * 8
    if (ab + ba + bpsAb + bpsBa === 0) return []
    return [{
      sourcePosition: Array.from(geometry.positions.subarray(edge.source * 2, edge.source * 2 + 2)),
      targetPosition: Array.from(geometry.positions.subarray(edge.target * 2, edge.target * 2 + 2)),
      flowPps: ab + ba, flowPpsAb: ab, flowPpsBa: ba,
      flowBps: bpsAb + bpsBa,
      flowBpsAb: bpsAb, flowBpsBa: bpsBa,
      weight: edge.count, topologyClass: "backbone", telemetryEligible: true,
      phaseStart: edge.start, phaseEnd: edge.end, flowSeed: edgeSeed(edge.id),
      worldUnitsPerPixel: 2 ** -geometry.key.z,
    }]
  })
  const frame = godViewRenderingStyleEdgeParticleMethods.buildPacketFlowEdges(edges)
  frames.set(overlay, frame)
  return frame
}

/** Schema-3 binary sublayers, sharing #4749's glyph packing and packet shader. */
export default class WorldTileLayer extends TileLayer {
  getPickingInfo(params) {
    const info = super.getPickingInfo(params)
    if (info.picked && !info.object) info.object = info.sourceTileSubLayer?.props.data.resolve?.(info.index)
    return info
  }

  renderSubLayers(props) {
    const geometry = props.data
    if (!geometry) return null
    const frame = geometryFrame(geometry)
    const candidate = this.props.overlays?.get(`${geometry.key.z}/${geometry.key.x}/${geometry.key.y}`)
    const overlay = candidate?.layout_version === geometry.key.layout_version &&
      candidate?.generation === geometry.generation && candidate?.revision === geometry.revision ? candidate : null
    const edgeClass = index => edgeTopologyClassValue(geometry.edges[index])
    const edgeStyle = index => edgeTopologyVisualStyleValue({topologyClass: edgeClass(index)})
    const shownEdge = index => edgeClass(index) !== "inferred" || this.props.inferred === true
    const health = new Map((overlay?.health?.glyphs || []).map(glyph => [glyph.id, glyph.counts]))
    const filters = this.props.filters || {}
    const shown = item => {
      const counts = health.get(item.id)
      return counts
        ? ["healthy", "unavailable", "unknown"].some(state => counts[state] > 0 && filters[state] !== false)
        : filters.unknown !== false
    }
    const common = {coordinateSystem: COORDINATE_SYSTEM.CARTESIAN, parameters: GOD_VIEW_ALPHA_BLEND}
    const node = ({index}) => frame.nodes[index]
    const healthColor = item => {
      const counts = health.get(item.id)
      if (!counts || counts.unknown > 0) return [120, 132, 151, 230]
      return counts.unavailable > 0 ? [245, 117, 88, 240] : [65, 195, 156, 240]
    }
    const flow = overlay && this.props.packetFlow !== false ? flowFrame(geometry, overlay) : null
    return [
      frame.lines.length > 0 && new LineLayer(props, common, {
        id: `${props.id}-edge-mantle`, data: frame.lines, pickable: false,
        visible: this.props.links !== false,
        getColor: (_, {index}) => !shownEdge(index) ? [0, 0, 0, 0] : edgeClass(index) === "unknown"
          ? [120, 132, 151, 30]
          : [55, 175, 124, Math.round(70 * edgeStyle(index).mantleAlphaScale)],
        getWidth: (_, {index}) => shownEdge(index) ? 6 * edgeStyle(index).mantleWidthScale : 0,
        widthUnits: "pixels", updateTriggers: {getWidth: this.props.inferred, getColor: this.props.inferred},
      }),
      frame.lines.length > 0 && new LineLayer(props, common, {
        id: `${props.id}-edges`, data: frame.lines, pickable: true,
        visible: this.props.links !== false,
        getColor: (_, {index}) => !shownEdge(index) ? [0, 0, 0, 0] : edgeClass(index) === "unknown"
          ? [120, 132, 151, 100]
          : [55, 175, 124, Math.round(135 * edgeStyle(index).crustAlphaScale)],
        getWidth: (_, {index}) => shownEdge(index) ? 1.5 * edgeStyle(index).crustWidthScale : 0, widthUnits: "pixels",
        updateTriggers: {getWidth: this.props.inferred, getColor: this.props.inferred},
      }),
      flow && flow.length > 0 && new PacketFlowLayer(props, common, {
        id: `${props.id}-packets`, data: flow, animate: true, pickable: false,
        parameters: GOD_VIEW_ADDITIVE_BLEND,
        // Across at most 64 tiles, bound particles globally as well as per edge.
        zoomDensity: 1 / Math.max(1, Math.min(64, this.props.visibleTileCount)),
      }),
      frame.glyphs.length > 0 && new ScatterplotLayer(props, common, {
        id: `${props.id}-node-glow`, data: frame.glyphs, pickable: false,
        radiusUnits: "pixels",
        getRadius: (_, info) => shown(node(info)) ? (node(info).kind === "aggregate" ? 13 : 9) : 0,
        getFillColor: (_, info) => [...healthColor(node(info)).slice(0, 3), 35],
        updateTriggers: {getFillColor: overlay, getRadius: [overlay, filters]},
      }),
      frame.glyphs.length > 0 && new ScatterplotLayer(props, common, {
        id: `${props.id}-nodes`, data: frame.glyphs, pickable: true,
        radiusUnits: "pixels", stroked: true, lineWidthUnits: "pixels", getLineWidth: 1.5,
        getRadius: (_, info) => shown(node(info)) ? (node(info).kind === "aggregate" ? 9 : 4) : 0,
        getFillColor: (_, info) => {
          if (node(info).kind === "device") return [232, 242, 237, 255]
          return healthColor(node(info))
        },
        getLineColor: (_, info) => {
          if (node(info).kind !== "device") return [210, 226, 240, 230]
          return healthColor(node(info))
        },
        updateTriggers: {getFillColor: overlay, getLineColor: overlay, getRadius: [overlay, filters]},
      }),
      frame.nodes.length > 0 && new TextLayer(props, common, {
        id: `${props.id}-labels`, data: frame.nodes, pickable: false,
        getPosition: item => item.position,
        getText: item => shown(item) ? (item.kind === "aggregate" ? item.count.toLocaleString() : item.label) : "",
        getSize: 11, sizeUnits: "pixels", getColor: [220, 232, 242, 240],
        getPixelOffset: [0, 15], fontFamily: "sans-serif", characterSet: "auto",
        updateTriggers: {getText: [overlay, filters]},
      }),
    ]
  }
}

WorldTileLayer.layerName = "WorldTileLayer"
WorldTileLayer.defaultProps = {
  TilesetClass: BoundedWorldTileset,
  tileSize: WORLD_TILE_SIZE,
  extent: [0, 0, WORLD_TILE_SIZE, WORLD_TILE_SIZE],
  minZoom: 0,
  maxCacheSize: 64,
  maxCacheByteSize: 32 * 1024 * 1024,
  maxRequests: 4,
  refinementStrategy: "no-overlap",
  overlays: {type: "object", value: null, compare: false},
  overlayRevision: 0,
  visibleTileCount: 64,
  packetFlow: true,
  links: true,
  inferred: false,
  filters: {type: "object", value: null, compare: false},
}
